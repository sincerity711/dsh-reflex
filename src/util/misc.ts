/** Ids, hashes, durations, and small async helpers. */

import { createHash, randomBytes } from 'node:crypto'

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

/** ULID: 48-bit ms timestamp + 80 random bits, Crockford base32. Sortable by creation time. */
export function ulid(now = Date.now()): string {
  let time = ''
  let t = now
  for (let i = 0; i < 10; i++) {
    time = CROCKFORD[t % 32] + time
    t = Math.floor(t / 32)
  }
  const bytes = randomBytes(10)
  let rand = ''
  let acc = 0
  let bits = 0
  for (const b of bytes) {
    acc = (acc << 8) | b
    bits += 8
    while (bits >= 5) {
      rand += CROCKFORD[(acc >> (bits - 5)) & 31]
      bits -= 5
    }
  }
  return time + rand.slice(0, 16)
}

export function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex')
}

export function shortHash(text: string, length = 12): string {
  return sha256(text).slice(0, length)
}

/** Parse "1500ms", "30s", "5m", "8h", "2d", or a number of milliseconds. */
export function parseDuration(value: string | number | undefined, fallbackMs?: number): number {
  if (value === undefined || value === '') {
    if (fallbackMs === undefined) throw new Error('missing duration')
    return fallbackMs
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || value < 0) throw new Error(`invalid duration ${value}`)
    return value
  }
  const m = /^\s*(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)?\s*$/.exec(value)
  if (m === null) throw new Error(`invalid duration "${value}" (use 500ms, 30s, 5m, 8h, 2d)`)
  const n = Number(m[1])
  const unit = m[2] ?? 'ms'
  const factor = unit === 'ms' ? 1 : unit === 's' ? 1000 : unit === 'm' ? 60_000 : unit === 'h' ? 3_600_000 : 86_400_000
  return Math.round(n * factor)
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`
  const s = Math.round(ms / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m${s % 60 ? `${s % 60}s` : ''}`
  const h = Math.floor(m / 60)
  return `${h}h${m % 60 ? `${m % 60}m` : ''}`
}

export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason ?? new Error('aborted'))
      return
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    const onAbort = (): void => {
      clearTimeout(timer)
      reject(signal?.reason ?? new Error('aborted'))
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

/** A promise with external resolve/reject. */
export interface Deferred<T> {
  readonly promise: Promise<T>
  resolve(value: T): void
  reject(error: unknown): void
  readonly settled: boolean
}

export function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  let settled = false
  const promise = new Promise<T>((res, rej) => {
    resolve = (v) => {
      if (settled) return
      settled = true
      res(v)
    }
    reject = (e) => {
      if (settled) return
      settled = true
      rej(e)
    }
  })
  // Avoid unhandled rejections for deferreds nobody awaits.
  promise.catch(() => undefined)
  return {
    promise,
    resolve,
    reject,
    get settled() {
      return settled
    },
  }
}

/** Serialize async work (one at a time, in order). Errors are passed to `onError` and do not break the chain. */
export class SerialQueue {
  private tail: Promise<void> = Promise.resolve()

  constructor(private readonly onError: (error: unknown) => void) {}

  push(work: () => Promise<void>): Promise<void> {
    const run = this.tail.then(work).catch(this.onError)
    this.tail = run
    return run
  }

  idle(): Promise<void> {
    return this.tail
  }
}

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }
export type JsonObject = { [key: string]: JsonValue }

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Read a dotted path ("a.b.0.c") from a JSON-ish value. */
export function getPath(root: unknown, path: string): unknown {
  let cur: unknown = root
  for (const part of path.split('.')) {
    if (part === '') continue
    if (Array.isArray(cur)) {
      const idx = Number(part)
      if (!Number.isInteger(idx)) return undefined
      cur = cur[idx]
    } else if (isRecord(cur)) {
      cur = cur[part]
    } else {
      return undefined
    }
  }
  return cur
}

/** Minimal logger interface (cordis Logger compatible subset). */
export interface Logger {
  debug(message: string, ...args: unknown[]): void
  info(message: string, ...args: unknown[]): void
  warn(message: string, ...args: unknown[]): void
  error(message: string, ...args: unknown[]): void
}

export const consoleLogger: Logger = {
  debug: () => undefined,
  info: (m, ...a) => console.error(`[reflex] ${m}`, ...a),
  warn: (m, ...a) => console.error(`[reflex] WARN ${m}`, ...a),
  error: (m, ...a) => console.error(`[reflex] ERROR ${m}`, ...a),
}

export const silentLogger: Logger = { debug: () => undefined, info: () => undefined, warn: () => undefined, error: () => undefined }
