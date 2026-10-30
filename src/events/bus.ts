/**
 * EventBus: consumes the helper outbox (subscribe → items → ack), validates and deduplicates events
 * by eventId, logs them, and hands events and task results to the engine — strictly in order.
 */

import { execFile } from 'node:child_process'
import type { HelperClient } from '../helper/client.js'
import { toReflexEvent, toTaskResult, type OutboxItem, type ReflexEvent } from '../helper/protocol.js'
import { errorMessage } from '../util/fs.js'
import { SerialQueue, type JsonValue, type Logger } from '../util/misc.js'
import type { SeenEvents } from './dedupe.js'
import type { EventLog } from './log.js'
import type { Decision, Engine } from '../dispatch/engine.js'

export class EventBus {
  private readonly queue: SerialQueue
  private client: HelperClient | undefined
  private backlog = 0
  private processedSinceSubscribe = 0
  private caughtUpListeners: (() => void)[] = []
  private caughtUp = false
  received = 0
  lastError: string | undefined

  constructor(
    private readonly engine: Engine,
    private readonly seen: SeenEvents,
    private readonly log: EventLog,
    private readonly logger: Logger,
  ) {
    this.queue = new SerialQueue((error) => {
      this.lastError = errorMessage(error)
      this.logger.error(`reflex: event processing failed: ${this.lastError}`)
    })
  }

  /** Attach to a freshly connected helper: subscribe and replay the backlog. */
  async attach(client: HelperClient): Promise<void> {
    this.client = client
    this.caughtUp = false
    this.processedSinceSubscribe = 0
    client.on('notification', (method, params) => {
      if (method === 'outbox.item') this.enqueue(client, params as unknown as OutboxItem)
    })
    const r = (await client.request('outbox.subscribe', { after: 0, takeover: true })) as { pending?: number }
    this.backlog = r.pending ?? 0
    // Items may have been processed before the response was handled.
    if (this.processedSinceSubscribe >= this.backlog) this.markCaughtUp()
  }

  /** Resolves once the backlog present at subscribe time has been processed. */
  whenCaughtUp(): Promise<void> {
    if (this.caughtUp) return Promise.resolve()
    return new Promise((resolve) => this.caughtUpListeners.push(resolve))
  }

  private markCaughtUp(): void {
    if (this.caughtUp) return
    this.caughtUp = true
    const listeners = this.caughtUpListeners
    this.caughtUpListeners = []
    for (const l of listeners) l()
  }

  private enqueue(client: HelperClient, item: OutboxItem): void {
    void this.queue.push(async () => {
      try {
        await this.process(item)
      } finally {
        // Always acknowledge: a poison item must not block the queue forever (errors are logged).
        if (!client.isClosed) await client.request('outbox.ack', { upTo: item.seq }).catch(() => undefined)
        this.processedSinceSubscribe += 1
        if (this.processedSinceSubscribe >= this.backlog) this.markCaughtUp()
      }
    })
  }

  private async process(item: OutboxItem): Promise<void> {
    this.received += 1
    if (item.kind === 'task.result') {
      await this.engine.onTaskResult(toTaskResult(item.data))
      return
    }
    if (item.kind !== 'event') return
    let event: ReflexEvent
    try {
      event = toReflexEvent(item.data)
    } catch (error) {
      this.logger.warn(`reflex: dropping malformed event ${item.id}: ${errorMessage(error)}`)
      return
    }
    await this.dispatch(event)
  }

  /** Also used for simulated events injected through the control socket. */
  async dispatch(event: ReflexEvent): Promise<Decision> {
    if (this.seen.has(event.eventId)) return { decision: 'duplicate-delivery', runIds: [] }
    const decision = await this.engine.handleEvent(event)
    await this.seen.add(event.eventId)
    await this.log.record(event, decision.decision, decision.runIds)
    // Notify only for a freshly observed, actually dispatched Teams capture; replay and simulation stay silent.
    if (event.eventType === 'teams.meeting.started' && event.app.program === 'teams' && decision.runIds.length > 0 && Math.abs(Date.now() - Date.parse(event.observedAt)) < 30_000) {
      const title = String(event.payload?.['title'] ?? 'Teams 会议').slice(0, 120)
      execFile('/usr/bin/osascript', ['-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title "Reflex" subtitle "已开始记录会议字幕"', '-e', 'end run', title], () => {})
    }
    return decision
  }

  /** Run a simulated event through the same serial queue. */
  inject(event: ReflexEvent): Promise<Decision> {
    let result: Decision = { decision: 'not-processed', runIds: [] }
    return this.queue.push(async () => {
      result = await this.dispatch(event)
    }).then(() => result)
  }

  detach(): void {
    this.client = undefined
  }

  get connected(): boolean {
    return this.client !== undefined && !this.client.isClosed
  }
}

export type { JsonValue }
