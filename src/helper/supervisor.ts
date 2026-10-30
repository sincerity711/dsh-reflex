/** Keeps one authenticated connection to the helper: launch on demand, reconnect, circuit breaker. */

import { execFile } from 'node:child_process'
import { EventEmitter } from 'node:events'
import type { ReflexPaths } from '../paths.js'
import { errorMessage, exists, pidAlive, readJson, readText } from '../util/fs.js'
import { sleep, type Logger } from '../util/misc.js'
import { HelperClient, RpcError } from './client.js'

export type SupervisorState = 'idle' | 'connecting' | 'launching' | 'connected' | 'backoff' | 'notInstalled' | 'broken' | 'stopped'

export interface SupervisorOptions {
  readonly paths: ReflexPaths
  readonly clientName: string
  readonly clientVersion: string
  readonly logger: Logger
  /** Launch the helper app when it is not running. */
  readonly autoLaunch: boolean
  /** Idle-exit seconds passed to a newly launched helper. */
  readonly helperIdleExitSec?: number
  readonly maxLaunches?: number
  readonly launchWindowMs?: number
}

interface HelperInfoFile {
  pid?: number
  socket?: string
  version?: string
  protocol?: number
}

export interface SupervisorEvents {
  connected: [client: HelperClient]
  disconnected: [reason: string]
  state: [state: SupervisorState]
}

export class HelperSupervisor extends EventEmitter<SupervisorEvents> {
  private _client: HelperClient | undefined
  private _state: SupervisorState = 'idle'
  private stopped = false
  private launches: number[] = []
  private attempt = 0
  private loop: Promise<void> | undefined
  private wake: (() => void) | undefined
  lastError: string | undefined

  constructor(private readonly options: SupervisorOptions) {
    super()
  }

  get client(): HelperClient | undefined {
    return this._client !== undefined && !this._client.isClosed ? this._client : undefined
  }

  get state(): SupervisorState {
    return this._state
  }

  private setState(state: SupervisorState): void {
    if (this._state === state) return
    this._state = state
    try {
      this.emit('state', state)
    } catch {
      // ignore
    }
  }

  start(): void {
    if (this.loop !== undefined) return
    this.stopped = false
    this.loop = this.run().catch((error: unknown) => {
      this.lastError = errorMessage(error)
      this.options.logger.error(`helper supervisor stopped: ${this.lastError}`)
    })
  }

  async stop(): Promise<void> {
    this.stopped = true
    this.setState('stopped')
    this.wake?.()
    this._client?.close()
    await this.loop
    this.loop = undefined
  }

  /** Clear the circuit breaker and reconnect now. */
  reset(): void {
    this.launches = []
    this.attempt = 0
    this.lastError = undefined
    if (this._state === 'broken' || this._state === 'backoff' || this._state === 'notInstalled') this.setState('idle')
    this.wake?.()
    if (this.loop === undefined) this.start()
  }

  private async run(): Promise<void> {
    while (!this.stopped) {
      if (this._state === 'broken') {
        await this.waitForWake(60_000)
        continue
      }
      try {
        const client = await this.connectOrLaunch()
        if (client === undefined) continue
        this._client = client
        this.attempt = 0
        this.lastError = undefined
        this.setState('connected')
        const closed = new Promise<string>((resolve) => client.once('close', (e) => resolve(e?.message ?? 'closed')))
        this.emit('connected', client)
        const reason = await Promise.race([closed, this.stoppedPromise()])
        this._client = undefined
        if (this.stopped) {
          client.close()
          return
        }
        this.options.logger.warn(`helper connection lost: ${reason}`)
        this.emit('disconnected', reason)
      } catch (error) {
        this.lastError = errorMessage(error)
        this.options.logger.debug(`helper connect failed: ${this.lastError}`)
      }
      if (this.stopped) return
      this.attempt += 1
      const delay = Math.min(30_000, 500 * 2 ** Math.min(this.attempt, 6))
      const current: SupervisorState = this.state
      this.setState(current === 'notInstalled' || current === 'broken' ? current : 'backoff')
      await this.waitForWake(current === 'notInstalled' ? 60_000 : delay)
    }
  }

  private stoppedPromise(): Promise<string> {
    return new Promise((resolve) => {
      const check = (): void => {
        if (this.stopped) resolve('stopped')
      }
      this.once('state', check)
    })
  }

  private waitForWake(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.wake = undefined
        resolve()
      }, ms)
      this.wake = () => {
        clearTimeout(timer)
        this.wake = undefined
        resolve()
      }
    })
  }

  private async tryConnect(): Promise<HelperClient> {
    const info = await readJson<HelperInfoFile>(this.options.paths.helperInfo)
    const socket = info?.socket ?? this.options.paths.helperSocket
    const token = (await readText(this.options.paths.helperToken))?.trim()
    if (token === undefined || token === '') throw new Error('helper token missing (helper not running)')
    return HelperClient.connect(socket, token, { name: this.options.clientName, version: this.options.clientVersion })
  }

  private async connectOrLaunch(): Promise<HelperClient | undefined> {
    this.setState('connecting')
    try {
      return await this.tryConnect()
    } catch (error) {
      if (error instanceof RpcError && error.code === -32002) {
        // Protocol mismatch: stop the old instance so the installed (newer) app replaces it.
        this.options.logger.warn(`helper protocol mismatch (${error.message}); restarting helper`)
        await this.killRunningHelper()
      } else if (error instanceof RpcError) {
        throw error
      }
    }
    if (!this.options.autoLaunch) throw new Error('helper is not running')
    const info = await readJson<HelperInfoFile>(this.options.paths.helperInfo)
    if (info?.pid !== undefined && pidAlive(info.pid)) {
      // Running but not reachable yet (starting up): wait a little before relaunching.
      await sleep(1000)
      return this.tryConnect()
    }
    if (!(await exists(this.options.paths.helperApp))) {
      this.setState('notInstalled')
      this.lastError = `helper app not installed at ${this.options.paths.helperApp} (run: dsh-reflex helper install)`
      return undefined
    }
    const now = Date.now()
    const window = this.options.launchWindowMs ?? 600_000
    this.launches = this.launches.filter((t) => now - t < window)
    if (this.launches.length >= (this.options.maxLaunches ?? 5)) {
      this.setState('broken')
      this.lastError = `helper crashed ${this.launches.length} times in ${Math.round(window / 60000)} min; circuit open (use /reflex helper restart)`
      this.options.logger.error(this.lastError)
      return undefined
    }
    this.launches.push(now)
    this.setState('launching')
    await launchHelper(this.options.paths, this.options.helperIdleExitSec)
    const deadline = Date.now() + 15_000
    while (Date.now() < deadline && !this.stopped) {
      await sleep(300)
      try {
        return await this.tryConnect()
      } catch {
        // keep waiting
      }
    }
    throw new Error('helper did not come up within 15s')
  }

  private async killRunningHelper(): Promise<void> {
    const info = await readJson<HelperInfoFile>(this.options.paths.helperInfo)
    if (info?.pid === undefined || !pidAlive(info.pid)) return
    try {
      process.kill(info.pid, 'SIGTERM')
    } catch {
      return
    }
    for (let i = 0; i < 50 && pidAlive(info.pid); i++) await sleep(100)
  }
}

/** Start the helper through LaunchServices (so TCC attributes the grant to the helper app itself). */
export function launchHelper(paths: ReflexPaths, idleExitSec?: number): Promise<void> {
  const args = ['-g', '-j', paths.helperApp, '--args', '--home', paths.dshHome]
  if (idleExitSec !== undefined) args.push('--idle-exit', String(idleExitSec))
  return new Promise((resolve, reject) => {
    execFile('/usr/bin/open', args, (error) => (error ? reject(error) : resolve()))
  })
}
