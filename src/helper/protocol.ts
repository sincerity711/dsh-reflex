/** Wire types shared with the Swift helper (see docs/PROTOCOL.md). */

import type { JsonObject, JsonValue } from '../util/misc.js'

export const HELPER_PROTOCOL = 1

/** A business event, as delivered from the helper outbox. UI-derived text lives only in `payload`. */
export interface ReflexEvent {
  /** ULID assigned by the helper; the plugin deduplicates by it. */
  readonly eventId: string
  readonly eventType: string
  /** When the helper received it (ISO). */
  readonly timestamp: string
  /** When the program observed it (ISO). */
  readonly observedAt: string
  readonly app: { readonly bundleId: string; readonly program: string; readonly pid?: number | null }
  readonly resourceId: string
  readonly correlationId?: string
  readonly origin?: 'ax' | 'poll' | 'simulated'
  readonly identity: 'stable' | 'heuristic'
  readonly dedupeKey: string
  /** Untrusted data from the UI. */
  readonly payload: JsonObject
}

export interface TaskResultData {
  readonly taskId: string
  readonly program: string
  readonly task: string
  readonly status: string
  readonly output: JsonObject
  readonly files: string[]
  readonly error?: string
  readonly stopReason?: string
  readonly startedAt?: string
  readonly endedAt?: string
}

export interface OutboxItem {
  readonly seq: number
  readonly id: string
  readonly kind: 'event' | 'task.result'
  readonly at: string
  readonly data: JsonValue
}

export interface ProgramManifest {
  readonly id: string
  readonly version: string
  readonly description: string
  readonly apps: string[]
  readonly capabilities: string[]
  readonly actions: { id: string; description: string }[]
  readonly emits: string[]
  readonly tasks: string[]
  readonly config: JsonObject
  readonly protocolVersion: number
  readonly stallTimeoutSec: number
  readonly lingerSec: number
  readonly binarySize?: number
  readonly dir?: string
}

export interface ProgramDesired {
  readonly id: string
  readonly enabled: boolean
  readonly required: boolean
  readonly config: JsonObject
  readonly grantedActions: string[]
}

export interface HelperInfo {
  readonly version: string
  readonly protocol: number
  readonly pid: number
  readonly startedAt: string
  readonly bundlePath: string
  readonly axTrusted: boolean
  readonly devMode: boolean
  readonly signing: { identity: string | null; adhoc: boolean } | null
}

export type StopReason = 'stopOn' | 'cancel' | 'timeout' | 'shutdown'

/** Normalize an outbox event payload into a ReflexEvent (fills dedupeKey). Throws on malformed data. */
export function toReflexEvent(data: JsonValue): ReflexEvent {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('event data must be an object')
  const d = data as Record<string, JsonValue>
  const str = (k: string, required = true): string | undefined => {
    const v = d[k]
    if (typeof v === 'string' && v !== '') return v
    if (required) throw new Error(`event ${k} must be a non-empty string`)
    return undefined
  }
  const eventType = str('eventType')!
  if (!/^[a-z][a-z0-9_-]*(\.[a-z0-9_-]+)+$/.test(eventType)) throw new Error(`invalid event type ${eventType}`)
  const app = d['app']
  const appObj = app !== null && typeof app === 'object' && !Array.isArray(app) ? (app as Record<string, JsonValue>) : {}
  const payload = d['payload']
  const correlationId = str('correlationId', false)
  const resourceId = str('resourceId', false) ?? 'unknown'
  const pid = appObj['pid']
  return {
    eventId: str('eventId')!,
    eventType,
    timestamp: str('timestamp', false) ?? new Date().toISOString(),
    observedAt: str('observedAt', false) ?? str('timestamp', false) ?? new Date().toISOString(),
    app: {
      bundleId: typeof appObj['bundleId'] === 'string' ? appObj['bundleId'] : '',
      program: typeof appObj['program'] === 'string' ? appObj['program'] : '',
      ...(typeof pid === 'number' ? { pid } : {}),
    },
    resourceId,
    ...(correlationId === undefined ? {} : { correlationId }),
    origin: d['origin'] === 'poll' || d['origin'] === 'simulated' ? d['origin'] : 'ax',
    identity: d['identity'] === 'heuristic' ? 'heuristic' : 'stable',
    dedupeKey: str('dedupeKey', false) ?? `${eventType}:${correlationId ?? resourceId}`,
    payload: payload !== null && typeof payload === 'object' && !Array.isArray(payload) ? (payload as JsonObject) : {},
  }
}

export function toTaskResult(data: JsonValue): TaskResultData {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('task result must be an object')
  const d = data as Record<string, JsonValue>
  const output = d['output']
  return {
    taskId: String(d['taskId'] ?? ''),
    program: String(d['program'] ?? ''),
    task: String(d['task'] ?? ''),
    status: typeof d['status'] === 'string' ? d['status'] : 'error',
    output: output !== null && typeof output === 'object' && !Array.isArray(output) ? (output as JsonObject) : {},
    files: Array.isArray(d['files']) ? d['files'].filter((f): f is string => typeof f === 'string') : [],
    ...(typeof d['error'] === 'string' ? { error: d['error'] } : {}),
    ...(typeof d['stopReason'] === 'string' ? { stopReason: d['stopReason'] } : {}),
    ...(typeof d['startedAt'] === 'string' ? { startedAt: d['startedAt'] } : {}),
    ...(typeof d['endedAt'] === 'string' ? { endedAt: d['endedAt'] } : {}),
  }
}
