/**
 * Leader lock: Desktop and `dsh web` may both mount the plugin; only one host connects to the
 * helper and runs rules. The lock file holds {pid, host, token, heartbeatAt}; a dead pid or a stale
 * heartbeat can be taken over.
 */

import { randomBytes } from 'node:crypto'
import { open } from 'node:fs/promises'
import { errorMessage, pidAlive, readJson, removePath, writeJsonAtomic } from '../util/fs.js'
import { sleep, type Logger } from '../util/misc.js'

export interface LeaderInfo {
  readonly pid: number
  readonly host: string
  readonly token: string
  readonly startedAt: string
  readonly heartbeatAt: string
}

export type LeaderState = { readonly state: 'leader' } | { readonly state: 'passive'; readonly holder?: LeaderInfo; readonly reason: string } | { readonly state: 'stopped' }

export class LeaderLock {
  private readonly token = randomBytes(12).toString('hex')
  private readonly startedAt = new Date().toISOString()
  private timer: NodeJS.Timeout | undefined
  private stopped = false
  private _state: LeaderState = { state: 'passive', reason: 'starting' }

  constructor(
    private readonly file: string,
    private readonly host: string,
    private readonly logger: Logger,
    private readonly hooks: { onLeader(): void; onPassive(reason: string): void },
    private readonly staleMs = 30_000,
    private readonly heartbeatMs = 10_000,
  ) {}

  get state(): LeaderState {
    return this._state
  }

  private info(): LeaderInfo {
    return { pid: process.pid, host: this.host, token: this.token, startedAt: this.startedAt, heartbeatAt: new Date().toISOString() }
  }

  /** One acquisition attempt. */
  async tryAcquire(): Promise<boolean> {
    const current = await readJson<LeaderInfo>(this.file).catch(() => undefined)
    if (current?.token === this.token) {
      await writeJsonAtomic(this.file, this.info())
      return true
    }
    if (current !== undefined) {
      const fresh = Date.now() - Date.parse(current.heartbeatAt) < this.staleMs
      if (pidAlive(current.pid) && fresh && current.pid !== process.pid) {
        this.setPassive(`leader is ${current.host} (pid ${current.pid})`, current)
        return false
      }
      // Dead or stale holder: take over (verified below against concurrent takers).
      await writeJsonAtomic(this.file, this.info())
    } else {
      try {
        const handle = await open(this.file, 'wx', 0o600)
        await handle.writeFile(JSON.stringify(this.info()))
        await handle.close()
      } catch (error) {
        if ((error as { code?: string }).code === 'EEXIST') return false
        throw error
      }
    }
    await sleep(150)
    const after = await readJson<LeaderInfo>(this.file).catch(() => undefined)
    if (after?.token !== this.token) {
      this.setPassive('lost the race for the leader lock', after)
      return false
    }
    return true
  }

  private setPassive(reason: string, holder?: LeaderInfo): void {
    const was = this._state.state
    this._state = { state: 'passive', reason, ...(holder ? { holder } : {}) }
    if (was === 'leader') this.hooks.onPassive(reason)
  }

  start(): void {
    const loop = async (): Promise<void> => {
      if (this.stopped) return
      try {
        const leader = await this.tryAcquire()
        if (leader && this._state.state !== 'leader') {
          this._state = { state: 'leader' }
          this.logger.info(`reflex: leader (${this.host}, pid ${process.pid})`)
          this.hooks.onLeader()
        } else if (!leader && this._state.state === 'leader') {
          this.setPassive('another host took the leader lock')
        }
      } catch (error) {
        this.logger.warn(`reflex: leader lock error: ${errorMessage(error)}`)
      }
      if (!this.stopped) {
        this.timer = setTimeout(() => void loop(), this._state.state === 'leader' ? this.heartbeatMs : 15_000)
        this.timer.unref?.()
      }
    }
    void loop()
  }

  async stop(): Promise<void> {
    this.stopped = true
    if (this.timer !== undefined) clearTimeout(this.timer)
    const current = await readJson<LeaderInfo>(this.file).catch(() => undefined)
    if (current?.token === this.token) await removePath(this.file)
    this._state = { state: 'stopped' }
  }
}
