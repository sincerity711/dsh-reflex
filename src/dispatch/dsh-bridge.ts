/**
 * DshBridge: deliver one reflex message to a DSH session (new or existing), wait until DSH has
 * claimed exactly that message and gone idle again, and return the final assistant reply.
 * Busy sessions get a follow-up (queued for the next turn) — never `steer`.
 */

import { randomUUID } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent, ModelSelection } from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-default-model'
import type {} from '@deepseek-ai/dsh-agent-preset-registry'
import type {} from '@deepseek-ai/dsh-api-session-controller'
import { boundContextSummary, createUserMessage, type ContextFormed } from '@deepseek-ai/dsh-llm'
import type {} from '@deepseek-ai/dsh-permission-presets'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-session-title'
import type {} from '@deepseek-ai/dsh-workspace'
import { errorMessage } from '../util/fs.js'
import { deferred, type Logger } from '../util/misc.js'

declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    'dsh-reflex': { kind: 'dsh-reflex'; ruleId: string; runId: string; eventId: string } & ContextFormed
  }
}

export type BridgeTarget = { readonly kind: 'new' } | { readonly kind: 'session'; readonly sessionId: string; readonly fallbackToNew: boolean }

export interface DshDelivery {
  readonly runId: string
  readonly ruleId: string
  readonly eventId: string
  readonly stepId: string
  readonly target: BridgeTarget
  readonly onBusy: 'queue' | 'skip' | 'new-session'
  readonly agentPreset?: string
  readonly permissionPreset?: string
  readonly title: string
  readonly prompt: string
  readonly workspacePath: string
  readonly model?: ModelSelection
  readonly timeoutMs: number
  readonly signal: AbortSignal
  /** Re-attach to a message delivered before a restart instead of sending a new one. */
  readonly resume?: { readonly sessionId: string; readonly messageId: string; readonly seqBefore: number }
}

export interface DeliveryProgress {
  readonly sessionId: string
  readonly messageId: string
  readonly seqBefore: number
}

export interface DshOutcome {
  /** ok | skipped | timed_out | cancelled | error */
  readonly status: string
  readonly sessionId?: string
  readonly messageId?: string
  readonly reply?: string
  readonly error?: string
}

export interface DshBridgeLike {
  deliver(delivery: DshDelivery, progress: (p: DeliveryProgress) => Promise<void>): Promise<DshOutcome>
  readonly available: boolean
  modelCatalog?(): Promise<{ current: ModelSelection; models: { provider: string; model: string; name: string }[]; unavailableProviders: string[] }>
}

/** Maximum reflex messages waiting (not yet claimed) per session. */
const MAX_PENDING_PER_SESSION = 3

export class HostDshBridge implements DshBridgeLike {
  private readonly pending = new Map<string, number>()

  constructor(private readonly ctx: Context, private readonly logger: Logger) {}

  get available(): boolean {
    return true
  }

  async modelCatalog() {
    const providers = this.ctx.llm.listProviders()
    const results = await Promise.allSettled(providers.map(async p => {
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        return await Promise.race([
          this.ctx.llm.listModels(p.id),
          new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('model catalog timed out')), 8000) }),
        ])
      } finally { if (timer) clearTimeout(timer) }
    }))
    const models: { provider: string; model: string; name: string }[] = []
    const unavailableProviders: string[] = []
    results.forEach((result, i) => {
      if (result.status === 'fulfilled') models.push(...result.value.map(m => ({ provider: m.provider, model: m.id, name: m.name })))
      else unavailableProviders.push(providers[i]!.id)
    })
    return { current: this.ctx.agentDefaultModel.currentSelection(), models, unavailableProviders }
  }

  async deliver(d: DshDelivery, progress: (p: DeliveryProgress) => Promise<void>): Promise<DshOutcome> {
    return this.ctx.agents.withoutInitiator(() => this.deliverInner(d, progress))
  }

  private async deliverInner(d: DshDelivery, progress: (p: DeliveryProgress) => Promise<void>): Promise<DshOutcome> {
    if (d.resume !== undefined) {
      const resolved = await this.ctx.sessionController.resolveAgent(d.resume.sessionId as SessionId)
      if ('error' in resolved) return { status: 'error', sessionId: d.resume.sessionId, error: `session unavailable after restart: ${describe(resolved.error)}` }
      return this.awaitCompletion(resolved.agent, d.resume.messageId, d.resume.seqBefore, d, false)
    }

    let agent: Agent | undefined
    let created = false
    if (d.target.kind === 'session') {
      const resolved = await this.ctx.sessionController.resolveAgent(d.target.sessionId as SessionId)
      if ('error' in resolved) {
        if (!d.target.fallbackToNew) return { status: 'error', sessionId: d.target.sessionId, error: `session ${d.target.sessionId} unavailable: ${describe(resolved.error)}` }
        this.logger.info(`reflex: session ${d.target.sessionId} unavailable; creating a new one`)
      } else {
        agent = resolved.agent
      }
    }
    if (agent !== undefined) {
      const busy = agent.status !== 'idle'
      const backlog = this.pending.get(agent.session.id) ?? 0
      if (busy || backlog >= MAX_PENDING_PER_SESSION) {
        if (d.onBusy === 'skip' || backlog >= MAX_PENDING_PER_SESSION) {
          return { status: 'skipped', sessionId: agent.session.id, error: backlog >= MAX_PENDING_PER_SESSION ? 'too many pending reflex messages for this session' : 'session busy' }
        }
        if (d.onBusy === 'new-session') agent = undefined
      }
    }
    if (agent === undefined) {
      agent = await this.createSession(d)
      created = true
    }
    const message = createUserMessage({
      content: [{ type: 'text', text: d.prompt }],
      source: {
        kind: 'dsh-reflex',
        ruleId: d.ruleId,
        runId: d.runId,
        eventId: d.eventId,
        form: 'notice',
        summary: boundContextSummary(`dsh-reflex · ${d.ruleId} · ${d.stepId}`),
      },
    })
    const seqBefore = Number(agent.session.seq)
    const sessionId = String(agent.session.id)
    // Persist where the message went before waiting, so a restart can re-attach.
    await progress({ sessionId, messageId: String(message.id), seqBefore })
    const completion = this.awaitCompletion(agent, String(message.id), seqBefore, d, true)
    agent.followup(message)
    const flushed = await this.ctx.sessions.flush(agent.session).catch(() => false)
    if (!flushed) this.logger.warn(`reflex: session ${sessionId} did not acknowledge the flush (message stays queued in memory)`)
    if (created) this.logger.info(`reflex: created session ${sessionId} for ${d.ruleId}/${d.stepId}`)
    return completion
  }

  private async createSession(d: DshDelivery): Promise<Agent> {
    const ctx = this.ctx
    const permissionPreset = d.permissionPreset ?? 'read-only'
    ctx.permissionPresets.resolve(permissionPreset)
    const preset = await ctx.agentPresets.resolve(d.agentPreset)
    await using scope = await ctx.agentPresets.acquireScope(preset.id)
    void scope
    d.signal.throwIfAborted()
    const workspace = await ctx.workspaceRegistry.create(d.workspacePath)
    const selection = d.model ?? ctx.agentDefaultModel.currentSelection()
    const sessionId = `reflex-${randomUUID()}` as SessionId
    const handle = await ctx.agents.create({
      sessionId,
      signal: d.signal,
      meta: { cwd: workspace.path, agentPreset: preset.id },
      agentOptions: { provider: selection.provider, model: selection.model, ...(selection.reasoningEffort === undefined ? {} : { reasoningEffort: selection.reasoningEffort }) },
      setup: async (agentCtx) => {
        await ctx.agentPresets.mount(agentCtx, preset.id)
      },
    })
    let attached = false
    try {
      await workspace.attachSession(sessionId)
      attached = true
      ctx.permissionPresets.set(handle.agent.session, permissionPreset)
      ctx.sessionTitle.rename(handle.agent.session, d.title)
      return handle.agent
    } catch (error) {
      if (attached) await workspace.detachSession(sessionId).catch(() => undefined)
      await handle.dispose().catch(() => undefined)
      throw error
    }
  }

  /**
   * Done = DSH claimed this exact message (agent/inbox/claimed) and the agent is idle again.
   * A timeout marks the step timed out but never cancels the session's turn.
   */
  private awaitCompletion(agent: Agent, messageId: string, seqBefore: number, d: DshDelivery, fresh: boolean): Promise<DshOutcome> {
    const sessionId = String(agent.session.id)
    const done = deferred<DshOutcome>()
    let claimed = !fresh && this.alreadyClaimed(agent, messageId, seqBefore)
    const disposers: (() => void)[] = []
    if (fresh) this.pending.set(sessionId, (this.pending.get(sessionId) ?? 0) + 1)
    let counted = fresh
    const uncount = (): void => {
      if (!counted) return
      counted = false
      const n = (this.pending.get(sessionId) ?? 1) - 1
      if (n <= 0) this.pending.delete(sessionId)
      else this.pending.set(sessionId, n)
    }
    const finish = (outcome: DshOutcome): void => {
      if (done.settled) return
      uncount()
      for (const dispose of disposers) {
        try {
          dispose()
        } catch {
          // ignore
        }
      }
      done.resolve(outcome)
    }
    const checkIdle = (): void => {
      if (!claimed || done.settled) return
      void agent.whenIdle().then(
        () => {
          if (agent.status !== 'idle') return
          finish({ status: 'ok', sessionId, messageId, reply: this.replyAfter(agent, seqBefore) })
        },
        (error: unknown) => finish({ status: 'error', sessionId, messageId, error: errorMessage(error) }),
      )
    }
    try {
      disposers.push(agent.ctx.on('agent/inbox/claimed', ({ agent: a, message }) => {
        if (a !== agent || String(message.id) !== messageId) return
        claimed = true
        uncount()
        checkIdle()
      }))
      disposers.push(agent.ctx.on('agent/inbox/discarded', ({ agent: a, message }) => {
        if (a !== agent || String(message.id) !== messageId) return
        finish({ status: 'error', sessionId, messageId, error: 'DSH discarded the message (session cancelled or cleared)' })
      }))
      disposers.push(agent.ctx.on('agent/status', ({ agent: a, status }) => {
        if (a === agent && status === 'idle') checkIdle()
      }))
      disposers.push(agent.ctx.on('agent/disposed', ({ agent: a }) => {
        if (a !== agent) return
        if (claimed) finish({ status: 'ok', sessionId, messageId, reply: this.replyAfter(agent, seqBefore) })
        else finish({ status: 'error', sessionId, messageId, error: 'session closed before handling the message' })
      }))
    } catch (error) {
      finish({ status: 'error', sessionId, messageId, error: `cannot observe session: ${errorMessage(error)}` })
    }
    const timer = setTimeout(() => finish({ status: 'timed_out', sessionId, messageId, error: `no completion within ${d.timeoutMs}ms (the DSH turn keeps running)` }), d.timeoutMs)
    disposers.push(() => clearTimeout(timer))
    const onAbort = (): void => finish({ status: 'cancelled', sessionId, messageId, error: 'cancelled (the DSH turn keeps running)' })
    d.signal.addEventListener('abort', onAbort, { once: true })
    disposers.push(() => d.signal.removeEventListener('abort', onAbort))
    if (claimed) checkIdle()
    return done.promise
  }

  /** After a restart: was the message already handled (a user/message event with its id after seqBefore)? */
  private alreadyClaimed(agent: Agent, messageId: string, seqBefore: number): boolean {
    try {
      for (const event of agent.session.snapshotEvents(seqBefore as never)) {
        const data = (event as { type?: string; data?: { message?: { id?: unknown } } })
        if (data.type === 'user/message' && String(data.data?.message?.id) === messageId) return true
      }
    } catch {
      // older log windows: treat as not yet claimed
    }
    return false
  }

  /** Text of the last assistant message after `seqBefore`. */
  private replyAfter(agent: Agent, seqBefore: number): string {
    let reply = ''
    try {
      for (const event of agent.session.snapshotEvents(seqBefore as never)) {
        const e = event as { type?: string; data?: { message?: { content?: unknown } } }
        if (e.type !== 'assistant/message') continue
        const content = e.data?.message?.content
        if (!Array.isArray(content)) continue
        const text = content
          .filter((b): b is { type: 'text'; text: string } => typeof b === 'object' && b !== null && (b as { type?: unknown }).type === 'text' && typeof (b as { text?: unknown }).text === 'string')
          .map((b) => b.text)
          .join('\n')
          .trim()
        if (text !== '') reply = text
      }
    } catch (error) {
      this.logger.warn(`reflex: cannot read the reply: ${errorMessage(error)}`)
    }
    return reply
  }
}

function describe(error: unknown): string {
  if (typeof error === 'object' && error !== null) {
    const e = error as { code?: unknown; message?: unknown }
    return [e.code, e.message].filter((x) => typeof x === 'string').join(': ') || JSON.stringify(error)
  }
  return String(error)
}
