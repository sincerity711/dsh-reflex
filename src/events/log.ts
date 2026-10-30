/** Event log: daily JSONL files with UI text replaced by length + hash (content stays in run/task dirs). */

import { join } from 'node:path'
import type { ReflexEvent } from '../helper/protocol.js'
import { appendLine, errorMessage, listDir, removePath } from '../util/fs.js'
import { isRecord, shortHash, type JsonValue, type Logger } from '../util/misc.js'

export interface EventLogEntry {
  readonly at: string
  readonly eventId: string
  readonly eventType: string
  readonly decision: string
  readonly runIds?: readonly string[]
}

/** Replace every string leaf by `{len, sha}` so logs reveal shape, not content. */
export function redactPayload(value: JsonValue): JsonValue {
  if (typeof value === 'string') return { len: value.length, sha: shortHash(value, 10) }
  if (Array.isArray(value)) return value.map(redactPayload)
  if (isRecord(value)) {
    const out: Record<string, JsonValue> = {}
    for (const [k, v] of Object.entries(value)) out[k] = redactPayload(v as JsonValue)
    return out
  }
  return value
}

export class EventLog {
  private readonly recent: EventLogEntry[] = []

  constructor(private readonly dir: string, private readonly logger: Logger, private readonly retentionDays: number) {}

  async record(event: ReflexEvent, decision: string, runIds: readonly string[] = []): Promise<void> {
    const at = new Date().toISOString()
    const entry: EventLogEntry = { at, eventId: event.eventId, eventType: event.eventType, decision, ...(runIds.length ? { runIds } : {}) }
    this.recent.unshift(entry)
    if (this.recent.length > 50) this.recent.length = 50
    const line = {
      ...entry,
      observedAt: event.observedAt,
      program: event.app.program,
      origin: event.origin,
      identity: event.identity,
      resource: shortHash(event.resourceId, 12),
      correlation: event.correlationId === undefined ? undefined : shortHash(event.correlationId, 12),
      dedupe: shortHash(event.dedupeKey, 12),
      payload: redactPayload(event.payload),
    }
    try {
      await appendLine(join(this.dir, `events-${at.slice(0, 10)}.jsonl`), JSON.stringify(line))
    } catch (error) {
      this.logger.warn(`event log write failed: ${errorMessage(error)}`)
    }
  }

  recentEntries(): readonly EventLogEntry[] {
    return this.recent
  }

  /** Delete daily files older than the retention period. */
  async prune(now = Date.now()): Promise<void> {
    const cutoff = new Date(now - this.retentionDays * 86_400_000).toISOString().slice(0, 10)
    for (const f of await listDir(this.dir)) {
      const m = /^events-(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(f)
      if (m !== null && m[1]! < cutoff) await removePath(join(this.dir, f))
    }
  }
}
