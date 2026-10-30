/** Local control socket for the CLI (leader only). NDJSON: {id, token, method, params} → {id, result|error}. */

import { randomBytes } from 'node:crypto'
import { chmod, unlink } from 'node:fs/promises'
import { createServer, type Server, type Socket } from 'node:net'
import { dirname } from 'node:path'
import { ensurePrivateDir, errorMessage, removePath, writeFileAtomic } from '../util/fs.js'
import type { JsonValue, Logger } from '../util/misc.js'

export type ControlHandler = (method: string, params: JsonValue) => Promise<JsonValue>

export class ControlServer {
  private server: Server | undefined
  private readonly token = randomBytes(24).toString('hex')
  private readonly sockets = new Set<Socket>()

  constructor(private readonly path: string, private readonly handler: ControlHandler, private readonly logger: Logger) {}

  async start(): Promise<void> {
    await ensurePrivateDir(dirname(this.path))
    await unlink(this.path).catch(() => undefined)
    const server = createServer((socket) => this.accept(socket))
    server.on('error', (error) => this.logger.warn(`reflex: control socket error: ${errorMessage(error)}`))
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(this.path, () => {
        server.off('error', reject)
        resolve()
      })
    })
    await chmod(this.path, 0o600).catch(() => undefined)
    await writeFileAtomic(`${this.path}.token`, `${this.token}\n`)
    this.server = server
  }

  private accept(socket: Socket): void {
    this.sockets.add(socket)
    socket.setEncoding('utf8')
    let buffer = ''
    socket.on('error', () => undefined)
    socket.on('close', () => this.sockets.delete(socket))
    socket.on('data', (chunk: string) => {
      buffer += chunk
      if (buffer.length > 1_000_000) {
        socket.destroy()
        return
      }
      let nl: number
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl)
        buffer = buffer.slice(nl + 1)
        void this.handle(socket, line)
      }
    })
  }

  private async handle(socket: Socket, line: string): Promise<void> {
    let id: JsonValue = null
    try {
      const msg = JSON.parse(line) as { id?: JsonValue; token?: string; method?: string; params?: JsonValue }
      id = msg.id ?? null
      if (msg.token !== this.token) throw new Error('bad control token')
      if (typeof msg.method !== 'string') throw new Error('missing method')
      const result = await this.handler(msg.method, msg.params ?? {})
      socket.write(`${JSON.stringify({ id, result })}\n`)
    } catch (error) {
      if (!socket.destroyed) socket.write(`${JSON.stringify({ id, error: { message: errorMessage(error) } })}\n`)
    }
  }

  async stop(): Promise<void> {
    for (const s of this.sockets) s.destroy()
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()))
    this.server = undefined
    await unlink(this.path).catch(() => undefined)
    await removePath(`${this.path}.token`)
  }
}
