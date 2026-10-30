import { describe, expect, it } from 'vitest'
import { HostDshBridge, type DshDelivery } from '../src/dispatch/dsh-bridge.js'
import { silentLogger, sleep } from '../src/util/misc.js'

type Listener = (payload: any) => void

/** Minimal stand-in for a DSH Agent: inbox claim → assistant reply → idle. */
class FakeAgent {
  status: 'idle' | 'running' = 'idle'
  readonly events: { type: string; data: any }[] = []
  private readonly listeners = new Map<string, Set<Listener>>()
  private queue: any[] = []
  private idleWaiters: (() => void)[] = []
  followups: any[] = []
  autoRun = true

  readonly session: { id: string; readonly seq: number; snapshotEvents(from?: number): { type: string; data: any }[] }

  constructor(readonly id: string) {
    const events = this.events
    this.session = {
      id,
      get seq() {
        return events.length
      },
      snapshotEvents: (from = 0) => events.slice(Number(from)),
    }
  }

  readonly ctx = {
    on: (name: string, fn: Listener) => {
      const set = this.listeners.get(name) ?? new Set()
      set.add(fn)
      this.listeners.set(name, set)
      return () => set.delete(fn)
    },
  }

  emit(name: string, payload: any): void {
    for (const fn of this.listeners.get(name) ?? []) fn({ agent: this, ...payload })
  }

  followup(message: any): void {
    this.followups.push(message)
    this.queue.push(message)
    if (this.status === 'idle' && this.autoRun) void this.runTurn()
  }

  /** Process queued messages: claim, reply, go idle. */
  async runTurn(): Promise<void> {
    this.setStatus('running')
    while (this.queue.length > 0) {
      const m = this.queue.shift()
      await sleep(5)
      this.events.push({ type: 'user/message', data: { message: m } })
      this.emit('agent/inbox/claimed', { message: m, turn: 1 })
      await sleep(5)
      this.events.push({ type: 'assistant/message', data: { message: { content: [{ type: 'text', text: `reply to ${m.id}` }] } } })
    }
    this.setStatus('idle')
  }

  setStatus(s: 'idle' | 'running'): void {
    this.status = s
    this.emit('agent/status', { status: s })
    if (s === 'idle') for (const w of this.idleWaiters.splice(0)) w()
  }

  whenIdle(): Promise<void> {
    if (this.status === 'idle') return Promise.resolve()
    return new Promise((resolve) => this.idleWaiters.push(resolve))
  }
}

function fakeCtx(existing: Map<string, FakeAgent>) {
  const created: FakeAgent[] = []
  const createOptions: any[] = []
  const ctx: any = {
    agents: {
      withoutInitiator: (fn: () => any) => fn(),
      create: async (opts: any) => {
        createOptions.push(opts)
        const a = new FakeAgent(opts.sessionId)
        existing.set(opts.sessionId, a)
        created.push(a)
        return { agent: a, dispose: async () => undefined }
      },
    },
    sessionController: {
      resolveAgent: async (id: string) => (existing.has(id) ? { agent: existing.get(id) } : { error: { code: 'not-found', message: 'no session' } }),
    },
    sessions: { flush: async () => true },
    permissionPresets: { resolve: () => ({}), set: () => undefined },
    agentPresets: {
      resolve: async (id?: string) => ({ id: id ?? 'standard' }),
      acquireScope: async () => ({ key: 'k', [Symbol.asyncDispose]: async () => undefined }),
      mount: async () => undefined,
    },
    workspaceRegistry: { create: async (path: string) => ({ path, attachSession: async () => undefined, detachSession: async () => undefined }) },
    agentDefaultModel: { currentSelection: () => ({ provider: 'p', model: 'm' }) },
    sessionTitle: { rename: () => undefined },
  }
  return { ctx, created, createOptions }
}

function delivery(over: Partial<DshDelivery> = {}): DshDelivery {
  return {
    runId: 'R1', ruleId: 'rule', eventId: 'E1', stepId: 'summarize', target: { kind: 'new' }, onBusy: 'queue',
    agentPreset: 'reflex-summarizer', permissionPreset: 'read-only', title: 't', prompt: 'summarize please',
    workspacePath: '/tmp', timeoutMs: 5000, signal: new AbortController().signal, ...over,
  }
}

describe('HostDshBridge', () => {
  it('uses the setup model even after the host default changes, including reasoning selection', async () => {
    const { ctx, createOptions } = fakeCtx(new Map())
    ctx.agentDefaultModel.currentSelection = () => ({ provider: 'new-default', model: 'other' })
    const bridge = new HostDshBridge(ctx, silentLogger)
    await bridge.deliver(delivery({ model: { provider: 'configured', model: 'chosen' } }), async () => undefined)
    expect(createOptions[0].agentOptions).toEqual({ provider: 'configured', model: 'chosen' })
    await bridge.deliver(delivery(), async () => undefined)
    expect(createOptions[1].agentOptions).toEqual({ provider: 'new-default', model: 'other' })
  })

  it('new session: waits for claim of this message and idle, returns the reply', async () => {
    const agents = new Map<string, FakeAgent>()
    const { ctx, created } = fakeCtx(agents)
    const bridge = new HostDshBridge(ctx, silentLogger)
    const progress: any[] = []
    const r = await bridge.deliver(delivery(), async (p) => {
      progress.push(p)
    })
    expect(created).toHaveLength(1)
    expect(r.status).toBe('ok')
    expect(r.reply).toBe(`reply to ${progress[0].messageId}`)
    const msg = created[0]!.followups[0]
    expect(msg.source).toMatchObject({ kind: 'dsh-reflex', form: 'notice', ruleId: 'rule', runId: 'R1', eventId: 'E1' })
  })

  it('busy session + queue: follow-up waits for its own claim (not the current turn) — never steer', async () => {
    const agents = new Map<string, FakeAgent>()
    const busy = new FakeAgent('s1')
    busy.autoRun = false
    busy.status = 'running'
    agents.set('s1', busy)
    const { ctx } = fakeCtx(agents)
    const bridge = new HostDshBridge(ctx, silentLogger)
    let settled = false
    const p = bridge.deliver(delivery({ target: { kind: 'session', sessionId: 's1', fallbackToNew: false } }), async () => undefined).then((r) => {
      settled = true
      return r
    })
    await sleep(30)
    // The current turn ends without claiming our message: not done yet.
    busy.setStatus('idle')
    await sleep(20)
    expect(settled).toBe(false)
    expect(busy.followups).toHaveLength(1)
    await busy.runTurn()
    const r = await p
    expect(r.status).toBe('ok')
    expect(r.reply).toContain('reply to')
  })

  it('busy session + skip / new-session', async () => {
    const agents = new Map<string, FakeAgent>()
    const busy = new FakeAgent('s1')
    busy.status = 'running'
    agents.set('s1', busy)
    const { ctx, created } = fakeCtx(agents)
    const bridge = new HostDshBridge(ctx, silentLogger)
    const skipped = await bridge.deliver(delivery({ onBusy: 'skip', target: { kind: 'session', sessionId: 's1', fallbackToNew: false } }), async () => undefined)
    expect(skipped.status).toBe('skipped')
    expect(busy.followups).toHaveLength(0)
    const fresh = await bridge.deliver(delivery({ onBusy: 'new-session', target: { kind: 'session', sessionId: 's1', fallbackToNew: false } }), async () => undefined)
    expect(fresh.status).toBe('ok')
    expect(created).toHaveLength(1)
  })

  it('timeout marks the step timed out without cancelling the turn', async () => {
    const agents = new Map<string, FakeAgent>()
    const stuck = new FakeAgent('s1')
    stuck.autoRun = false
    agents.set('s1', stuck)
    const { ctx } = fakeCtx(agents)
    const bridge = new HostDshBridge(ctx, silentLogger)
    const r = await bridge.deliver(delivery({ timeoutMs: 50, target: { kind: 'session', sessionId: 's1', fallbackToNew: false } }), async () => undefined)
    expect(r.status).toBe('timed_out')
    expect(stuck.followups).toHaveLength(1)
  })

  it('missing fixed session: error, or a new one when falling back (per-correlation)', async () => {
    const { ctx, created } = fakeCtx(new Map())
    const bridge = new HostDshBridge(ctx, silentLogger)
    const err = await bridge.deliver(delivery({ target: { kind: 'session', sessionId: 'gone', fallbackToNew: false } }), async () => undefined)
    expect(err.status).toBe('error')
    const ok = await bridge.deliver(delivery({ target: { kind: 'session', sessionId: 'gone', fallbackToNew: true } }), async () => undefined)
    expect(ok.status).toBe('ok')
    expect(created).toHaveLength(1)
  })
})
