/** First-run installer. Only explicit UI actions start native processes. */
import { spawn, type ChildProcess } from 'node:child_process'
import { constants } from 'node:fs'
import { copyFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { capture } from './cli/exec.js'
import type { ReflexPaths } from './paths.js'
import { exists, readJson, writeJsonAtomic } from './util/fs.js'

export class ReflexSetup {
  private child: ChildProcess | undefined
  private running: Promise<void> | undefined
  private stopped = false
  private phase = 'idle'
  private log = ''
  private error: string | null = null
  constructor(private readonly paths: ReflexPaths, private readonly packageRoot: string, private readonly rulesFile: string, private readonly reconnect: () => void) {}

  async status() {
    const state = await readJson<{ dismissed?: boolean }>(join(this.paths.stateDir, 'setup.json'))
    return { phase: this.phase, log: this.log, error: this.error, installed: await exists(this.paths.helperApp), dismissed: state?.dismissed === true, platform: process.platform }
  }

  async dismiss(): Promise<void> {
    await writeJsonAtomic(join(this.paths.stateDir, 'setup.json'), { dismissed: true })
  }

  start(): void {
    if (this.running || this.stopped) return
    if (process.platform !== 'darwin') throw new Error('macOS only')
    this.phase = 'checking'; this.log = ''; this.error = null
    this.running = this.install().catch(error => {
      this.phase = 'failed'; this.error = error instanceof Error ? error.message : String(error)
    }).finally(() => { this.running = undefined })
  }

  private async install(): Promise<void> {
    const swift = await capture('/usr/bin/xcrun', ['swift', '--version'], { timeoutMs: 15000 })
    if (this.stopped) return
    if (swift.code !== 0 || !/Swift version (?:[6-9]|[1-9]\d+)\./.test(swift.stdout)) {
      this.phase = 'tools'
      await this.command('/usr/bin/xcode-select', ['--install'])
      return
    }
    this.phase = 'signing'
    await this.command(join(this.packageRoot, 'scripts/setup-local-signing.sh'), [])
    this.phase = 'building'
    await this.command(process.execPath, [join(this.packageRoot, 'lib/cli/dsh-reflex.js'), 'helper', 'install'])
    if (this.stopped) return
    await mkdir(join(this.rulesFile, '..'), { recursive: true, mode: 0o700 })
    try {
      await copyFile(join(this.packageRoot, 'examples/rules/teams-meeting-summary.yaml'), this.rulesFile, constants.COPYFILE_EXCL)
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
    this.reconnect()
    this.phase = 'installed'
  }

  private command(file: string, args: string[]): Promise<void> {
    if (this.stopped) return Promise.reject(new Error('Installer stopped'))
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, { env: { ...process.env, DSH_HOME: this.paths.dshHome }, stdio: ['ignore', 'pipe', 'pipe'], detached: true })
      this.child = child
      const append = (data: Buffer) => { this.log = (this.log + data.toString()).slice(-16000) }
      child.stdout.on('data', append); child.stderr.on('data', append)
      child.once('error', reject)
      child.once('close', code => {
        this.child = undefined
        code === 0 ? resolve() : reject(new Error(`${file.split('/').at(-1)} failed (${code ?? 'signal'}). ${this.log.slice(-2000)}`))
      })
    })
  }

  async stop(): Promise<void> {
    this.stopped = true
    const child = this.child
    const terminate = (signal: NodeJS.Signals) => {
      if (!child) return
      try { if (child.pid) process.kill(-child.pid, signal); else child.kill(signal) } catch { /* already stopped */ }
    }
    terminate('SIGTERM')
    const timer = setTimeout(() => terminate('SIGKILL'), 3000)
    try { await this.running } finally { clearTimeout(timer) }
  }
}
