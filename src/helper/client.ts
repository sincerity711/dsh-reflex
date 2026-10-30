/** JSON-RPC 2.0 over NDJSON on the helper's unix socket. */

import { EventEmitter } from 'node:events'
import { connect, type Socket } from 'node:net'
import { HELPER_PROTOCOL, type HelperInfo } from './protocol.js'
import type { JsonValue } from '../util/misc.js'

export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: JsonValue,
  ) {
    super(message)
    this.name = 'RpcError'
  }
}

interface Pending {
  resolve(value: JsonValue): void
  reject(error: unknown): void
  timer: NodeJS.Timeout | undefined
  method: string
}

export interface HelperClientEvents {
  notification: [method: string, params: JsonValue]
  close: [error?: Error]
}

/** One connection to the helper. Emits `notification` and `close`; never throws asynchronously. */
export class HelperClient extends EventEmitter<HelperClientEvents> {
  private socket: Socket | undefined
  private buffer = ''
  private nextId = 1
  private readonly pending = new Map<number, Pending>()
  private closed = false
  info: HelperInfo | undefined

  /** Connect and authenticate. Rejects on connection failure, bad token, or protocol mismatch. */
  static async connect(
    socketPath: string,
    token: string,
    client: { name: string; version: string; pid?: number },
    timeoutMs = 5000,
  ): Promise<HelperClient> {
    const c = new HelperClient()
    await c.open(socketPath, timeoutMs)
    try {
      const info = await c.request('hello', { protocol: HELPER_PROTOCOL, token, client: { pid: process.pid, ...client } }, timeoutMs)
      c.info = info as unknown as HelperInfo
      return c
    } catch (error) {
      c.close()
      throw error
    }
  }

  private open(socketPath: string, timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = connect(socketPath)
      const timer = setTimeout(() => {
        socket.destroy()
        reject(new Error(`connect ${socketPath} timed out`))
      }, timeoutMs)
      socket.once('connect', () => {
        clearTimeout(timer)
        this.socket = socket
        socket.setEncoding('utf8')
        socket.on('data', (chunk: string) => this.onData(chunk))
        socket.on('close', () => this.onClose())
        socket.on('error', (error) => this.onClose(error))
        resolve()
      })
      socket.once('error', (error) => {
        clearTimeout(timer)
        reject(error)
      })
    })
  }

  get isClosed(): boolean {
    return this.closed
  }

  request(method: string, params: JsonValue = {}, timeoutMs = 15000): Promise<JsonValue> {
    if (this.closed || this.socket === undefined) return Promise.reject(new Error('helper connection closed'))
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
          this.pending.delete(id)
          reject(new Error(`helper request ${method} timed out after ${timeoutMs}ms`))
        }, timeoutMs)
        : undefined
      this.pending.set(id, { resolve, reject, timer, method })
      this.write({ jsonrpc: '2.0', id, method, params })
    })
  }

  notify(method: string, params: JsonValue = {}): void {
    this.write({ jsonrpc: '2.0', method, params })
  }

  close(): void {
    if (this.closed) return
    this.socket?.end()
    this.socket?.destroy()
    this.onClose()
  }

  private write(message: JsonValue): void {
    try {
      this.socket?.write(`${JSON.stringify(message)}\n`)
    } catch (error) {
      this.onClose(error instanceof Error ? error : new Error(String(error)))
    }
  }

  private onData(chunk: string): void {
    this.buffer += chunk
    let nl: number
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl)
      this.buffer = this.buffer.slice(nl + 1)
      if (line.trim() === '') continue
      let msg: Record<string, JsonValue>
      try {
        msg = JSON.parse(line) as Record<string, JsonValue>
      } catch {
        continue
      }
      if (typeof msg['method'] === 'string' && msg['id'] === undefined) {
        try {
          this.emit('notification', msg['method'], msg['params'] ?? null)
        } catch {
          // listeners must not break the connection
        }
        continue
      }
      const id = msg['id']
      if (typeof id !== 'number') continue
      const p = this.pending.get(id)
      if (p === undefined) continue
      this.pending.delete(id)
      if (p.timer !== undefined) clearTimeout(p.timer)
      const err = msg['error']
      if (err !== undefined && err !== null && typeof err === 'object' && !Array.isArray(err)) {
        const e = err as Record<string, JsonValue>
        p.reject(new RpcError(Number(e['code'] ?? -32000), String(e['message'] ?? 'helper error'), e['data']))
      } else {
        p.resolve(msg['result'] ?? null)
      }
    }
  }

  private onClose(error?: Error): void {
    if (this.closed) return
    this.closed = true
    for (const p of this.pending.values()) {
      if (p.timer !== undefined) clearTimeout(p.timer)
      p.reject(new Error(`helper connection closed during ${p.method}`))
    }
    this.pending.clear()
    try {
      this.emit('close', error)
    } catch {
      // ignore listener failures
    }
  }
}
