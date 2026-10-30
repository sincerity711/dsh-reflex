import { ReflexSetup } from './setup.js'
/** ReflexCore: leader lock + (as leader) helper supervisor, event bus, rules, engine, control socket. */

import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ControlServer } from './control/server.js'
import { LeaderLock } from './control/leader.js'
import { Engine, type EngineConfig, type HelperPort } from './dispatch/engine.js'
import type { DshBridgeLike } from './dispatch/dsh-bridge.js'
import { RunStore, type RunRecord } from './dispatch/runs-store.js'
import { EventBus } from './events/bus.js'
import { SeenEvents } from './events/dedupe.js'
import { EventLog } from './events/log.js'
import type { HelperClient } from './helper/client.js'
import { ProgramsState } from './helper/programs.js'
import { toReflexEvent, type ProgramManifest, type StopReason } from './helper/protocol.js'
import { HelperSupervisor } from './helper/supervisor.js'
import type { ReflexPaths } from './paths.js'
import { RuleStore } from './rules/loader.js'
import { ensurePrivateDir, errorMessage, readText } from './util/fs.js'
import { ulid, type JsonObject, type JsonValue, type Logger } from './util/misc.js'
import { TeamsSettingsStore } from './teams-settings.js'

export interface CoreSettings {
  readonly autoLaunchHelper: boolean
  readonly helperIdleExitSec: number
  readonly rulesFile: string
  readonly workspacePath: string
  readonly allowedFileRoots: readonly string[]
  readonly stopGraceMs: number
  readonly defaultTaskTimeoutMs: number
  readonly defaultRunTimeoutMs: number
  readonly defaultDshTimeoutMs: number
  readonly retentionDays: number
  readonly programConfig: Record<string, JsonObject>
}

export interface CoreOptions {
  readonly paths: ReflexPaths
  readonly logger: Logger
  readonly bridge: DshBridgeLike
  readonly hostName: string
  readonly version: string
  readonly settings: CoreSettings
  /** Package root (prompts/, lib/builtins). */
  readonly packageRoot: string
}

export const PACKAGE_ROOT = fileURLToPath(new URL('..', import.meta.url))

/** Everything that only the leader runs. Created on becoming leader, torn down on losing it. */
export class LeaderWork {
  readonly rules: RuleStore
  readonly store: RunStore
  readonly engine: Engine
  readonly bus: EventBus
  readonly supervisor: HelperSupervisor
  readonly programs: ProgramsState
  readonly eventLog: EventLog
  readonly setup: ReflexSetup
  readonly teamsSettings: TeamsSettingsStore
  private readonly seen: SeenEvents
  private control: ControlServer | undefined
  private resumed = false
  private active: RunRecord[] = []
  private menuTimer: ReturnType<typeof setInterval> | undefined
  menuLocale = 'en'
  installed: ProgramManifest[] = []
  paused = false
  pausedAll = false

  constructor(private readonly o: CoreOptions) {
    const { paths, logger, settings } = o
    this.rules = new RuleStore(settings.rulesFile, logger)
    this.store = new RunStore(paths.runsDir)
    this.seen = new SeenEvents(join(paths.stateDir, 'seen-events.txt'))
    this.eventLog = new EventLog(paths.logsDir, logger, settings.retentionDays)
    this.teamsSettings = new TeamsSettingsStore(paths.root, o.packageRoot, settings.workspacePath)
    this.programs = new ProgramsState(paths.stateDir, () => settings.programConfig)
    this.supervisor = new HelperSupervisor({
      paths, clientName: `dsh-reflex@${o.hostName}`, clientVersion: o.version, logger,
      autoLaunch: settings.autoLaunchHelper, helperIdleExitSec: settings.helperIdleExitSec,
    })
    this.setup = new ReflexSetup(paths, o.packageRoot, settings.rulesFile, () => this.supervisor.reset())
    const rulesDir = join(settings.rulesFile, '..')
    const engineConfig: EngineConfig = {
      workspacePath: settings.workspacePath,
      allowedFileRoots: settings.allowedFileRoots,
      promptDirs: [rulesDir, join(rulesDir, 'prompts'), join(o.packageRoot, 'prompts')],
      defaultTaskTimeoutMs: settings.defaultTaskTimeoutMs,
      defaultRunTimeoutMs: settings.defaultRunTimeoutMs,
      defaultDshTimeoutMs: settings.defaultDshTimeoutMs,
      stopGraceMs: settings.stopGraceMs,
      builtins: {
        notify: { argv: [process.execPath, join(o.packageRoot, 'lib', 'builtins', 'notify.js')], env: { ELECTRON_RUN_AS_NODE: '1' } },
      },
      sessionMapFile: join(paths.stateDir, 'sessions.json'),
    }
    this.engine = new Engine({ store: this.store, rules: () => this.rules.rules, helper: this.helperPort(), bridge: o.bridge, logger, config: engineConfig, teamsSettings: this.teamsSettings })
    this.bus = new EventBus(this.engine, this.seen, this.eventLog, logger)
  }

  private helperPort(): HelperPort {
    const sup = this.supervisor
    const client = (): HelperClient => {
      const c = sup.client
      if (c === undefined) throw new Error('helper not connected')
      return c
    }
    return {
      get connected() {
        return sup.client !== undefined
      },
      startTask: async (p) => {
        await client().request('tasks.start', p as unknown as JsonValue)
      },
      stopTask: async (taskId: string, reason: StopReason, graceMs: number) => {
        await client().request('tasks.stop', { taskId, reason, graceMs })
      },
      listTasks: async () => (await client().request('tasks.list', {})) as unknown as { taskId: string; state: string }[],
      waitConnected: (signal: AbortSignal) => new Promise<void>((resolve, reject) => {
        if (sup.client !== undefined) {
          resolve()
          return
        }
        const onConnected = (): void => {
          signal.removeEventListener('abort', onAbort)
          resolve()
        }
        const onAbort = (): void => {
          sup.off('connected', onConnected)
          reject(signal.reason ?? new Error('aborted'))
        }
        sup.once('connected', onConnected)
        signal.addEventListener('abort', onAbort, { once: true })
      }),
    }
  }

  async start(): Promise<void> {
    const { paths, logger } = this.o
    for (const d of [paths.root, paths.runDir, paths.stateDir, paths.logsDir, paths.dataDir, paths.runsDir]) await ensurePrivateDir(d)
    await this.programs.load()
    await this.seen.load()
    this.active = await this.store.load()
    await this.store.prune(this.o.settings.retentionDays).catch(() => 0)
    await this.eventLog.prune().catch(() => undefined)
    await this.rules.load()
    this.rules.watch()
    this.rules.onChange(() => void this.pushPrograms())
    this.supervisor.on('connected', (client) => void this.onConnected(client))
    this.supervisor.on('disconnected', () => this.bus.detach())
    this.supervisor.start()
    this.menuTimer = setInterval(() => void this.updateMenu(), 2000)
    this.control = new ControlServer(paths.controlSocket, (m, p) => this.controlCall(m, p), logger)
    await this.control.start().catch((e: unknown) => logger.warn(`reflex: control socket unavailable: ${errorMessage(e)}`))
  }

  private async onConnected(client: HelperClient): Promise<void> {
    try {
      await this.bus.attach(client)
      await this.bus.whenCaughtUp()
      if (!this.resumed) {
        this.resumed = true
        await this.engine.resume(this.active)
        this.active = []
      }
      await this.pushPrograms()
      await this.engine.onHelperConnected()
      await this.updateMenu()
    } catch (error) {
      this.o.logger.warn(`reflex: helper setup failed: ${errorMessage(error)}`)
    }
  }

  async updateMenu(): Promise<void> {
    const client = this.supervisor.client
    if (!client) return
    const items = this.store.list(100).filter(r => r.ruleId === 'teams-meeting-summary')
    const item = items.find(r => r.status === 'running' || r.status === 'queued') ?? items[0]
    const run = item ? await this.store.get(item.runId) : undefined
    const status = run ? { runId: run.runId, correlationId: run.event.correlationId ?? '', title: String(run.event.payload['title'] ?? ''), status: run.status,
      step: run.currentStep ?? '', captureStatus: run.steps['capture']?.status ?? '', summaryAvailable: run.steps['summarize']?.status === 'ok' } : null
    await client.request('desktop.status', { status, locale: this.menuLocale }, 3000).catch(() => undefined)
  }

  /** Tell the helper which programs are enabled and needed by rules. */
  async pushPrograms(): Promise<void> {
    const client = this.supervisor.client
    if (client === undefined) return
    try {
      this.installed = (await client.request('programs.list', {})) as unknown as ProgramManifest[]
      let desired = this.programs.desired(this.installed, this.rules.rules)
      if (this.pausedAll) desired = desired.map((d) => ({ ...d, enabled: false }))
      await client.request('programs.configure', { programs: desired as unknown as JsonValue, replaceAll: true })
    } catch (error) {
      this.o.logger.warn(`reflex: cannot configure programs: ${errorMessage(error)}`)
    }
  }

  async installedPrograms(): Promise<ProgramManifest[]> {
    const client = this.supervisor.client
    if (client !== undefined) this.installed = (await client.request('programs.list', {})) as unknown as ProgramManifest[]
    return this.installed
  }

  async pause(all: boolean): Promise<string> {
    this.paused = true
    this.engine.paused = true
    if (all) {
      this.pausedAll = true
      await this.pushPrograms()
    }
    return all ? '已暂停：不再派发新的 run，并停止所有程序进程（进行中的采集也会结束）。' : '已暂停：不再派发新的 run（程序继续运行）。'
  }

  async resume(): Promise<string> {
    this.paused = false
    this.pausedAll = false
    this.engine.paused = false
    await this.pushPrograms()
    return '已恢复。'
  }

  async status(): Promise<JsonObject> {
    let helper: JsonValue = null
    const client = this.supervisor.client
    if (client !== undefined) helper = await client.request('helper.status', {}, 3000).catch(() => null)
    const helperPrograms = new Map<string, Record<string, JsonValue>>()
    if (helper !== null && typeof helper === 'object' && !Array.isArray(helper)) {
      for (const p of ((helper as Record<string, JsonValue>)['programs'] ?? []) as Record<string, JsonValue>[]) helperPrograms.set(String(p['id']), p)
    }
    const programs = this.programs.views(this.installed, this.rules.rules).map((v) => {
      const h = helperPrograms.get(v.id) ?? {}
      return {
        ...v,
        state: h['state'] ?? null,
        ...(h['pid'] !== undefined ? { process: { pid: h['pid'], rssBytes: h['rssBytes'] ?? null, cpuPercent: h['cpuPercent'] ?? null } } : {}),
        restarts: h['restarts'] ?? 0,
        ...(h['lastError'] !== undefined ? { lastError: h['lastError'] } : {}),
        ...(h['status'] !== undefined ? { status: h['status'] } : {}),
        ...(loopsOf(h['metrics']) ? { loops: loopsOf(h['metrics'])! } : {}),
      }
    })
    return {
      supervisor: { state: this.supervisor.state, lastError: this.supervisor.lastError ?? null },
      helper,
      rules: this.rules.status as unknown as JsonValue,
      programs: programs as unknown as JsonValue,
      runs: { active: this.engine.activeRuns() as unknown as JsonValue, recent: this.store.list(10) as unknown as JsonValue },
      events: this.eventLog.recentEntries() as unknown as JsonValue,
      paused: this.paused,
      pausedAll: this.pausedAll,
    }
  }

  /** Inject a simulated event (dev mode only). */
  async simulate(eventJson: JsonValue): Promise<JsonValue> {
    const raw = (await readText(this.o.paths.devModeFile))?.trim()
    if (raw === undefined || (raw !== '' && new Date(raw) <= new Date())) throw new Error('dev 模式未开启（dsh-reflex dev on）')
    const e = (eventJson ?? {}) as Record<string, JsonValue>
    const now = new Date().toISOString()
    const event = toReflexEvent({ ...e, eventId: ulid(), timestamp: now, observedAt: now, app: { bundleId: 'simulated', program: 'sim' }, origin: 'simulated' })
    const decision = await this.bus.inject(event)
    return { eventId: event.eventId, ...decision } as unknown as JsonValue
  }

  private async controlCall(method: string, params: JsonValue): Promise<JsonValue> {
    const p = (params ?? {}) as Record<string, JsonValue>
    switch (method) {
      case 'status':
        return { plugin: { version: this.o.version, host: this.o.hostName, leader: { state: 'leader' }, paused: this.paused, pausedAll: this.pausedAll }, ...(await this.status()) }
      case 'pause':
        return this.pause(p['all'] === true)
      case 'resume':
        return this.resume()
      case 'runs.list':
        return this.store.list(typeof p['limit'] === 'number' ? p['limit'] : 20) as unknown as JsonValue
      case 'runs.get': {
        const run = await this.store.get(String(p['runId'] ?? ''))
        if (run === undefined) throw new Error('no such run')
        return run as unknown as JsonValue
      }
      case 'runs.cancel':
        return { cancelled: await this.engine.cancelRun(String(p['runId'] ?? ''), 'cancelled from the CLI') }
      case 'rules.reload':
        return (await this.rules.load()) as unknown as JsonValue
      case 'sim.emit':
        return this.simulate(p['event'] ?? {})
      default:
        throw new Error(`unknown control method ${method}`)
    }
  }

  async stop(shutdownHelper = false): Promise<void> {
    await this.setup.stop()
    if (this.menuTimer) clearInterval(this.menuTimer)
    await this.control?.stop().catch(() => undefined)
    this.control = undefined
    if (shutdownHelper) {
      await this.engine.close()
      for (const run of this.store.activeRuns()) {
        run.status = 'cancelled'
        run.cancelReason = 'DSH stopped'
        run.endedAt = new Date().toISOString()
        delete run.currentStep
        await this.store.save(run)
      }
      const client = this.supervisor.client
      if (client) {
        await client.request('desktop.shutdown', {}, 2000).catch(() => undefined)
        await new Promise(resolve => setTimeout(resolve, 350))
      }
    }
    await this.supervisor.stop().catch(() => undefined)
    this.rules.close()
    await this.engine.close()
  }
}

/** Active tick/watch loops of a program (from its pong metrics): name → ticks. */
function loopsOf(metrics: JsonValue | undefined): JsonValue | undefined {
  if (metrics === null || typeof metrics !== 'object' || Array.isArray(metrics)) return undefined
  const loops = (metrics as Record<string, JsonValue>)['loops']
  if (!Array.isArray(loops) || loops.length === 0) return undefined
  return loops.map((l) => {
    const o = (l ?? {}) as Record<string, JsonValue>
    return { name: o['name'] ?? '?', ticks: o['ticks'] ?? 0, avgHandlerMs: o['avgHandlerMs'] ?? 0 }
  })
}

export class ReflexCore {
  readonly leader: LeaderLock
  private work: LeaderWork | undefined
  private transition: Promise<void> = Promise.resolve()

  constructor(readonly o: CoreOptions) {
    this.leader = new LeaderLock(o.paths.leaderLock, o.hostName, o.logger, {
      onLeader: () => this.serialize(async () => {
        if (this.work !== undefined) return
        const work = new LeaderWork(this.o)
        this.work = work
        await work.start()
      }),
      onPassive: (reason) => this.serialize(async () => {
        this.o.logger.warn(`reflex: now passive: ${reason}`)
        const work = this.work
        this.work = undefined
        await work?.stop()
      }),
    })
  }

  private serialize(op: () => Promise<void>): void {
    this.transition = this.transition.then(op).catch((error: unknown) => this.o.logger.error(`reflex: ${errorMessage(error)}`))
  }

  /** The leader's components, or undefined while passive. */
  get active(): LeaderWork | undefined {
    return this.work
  }

  start(): void {
    this.leader.start()
  }

  async status(): Promise<JsonObject> {
    const base = { plugin: { version: this.o.version, host: this.o.hostName, leader: this.leader.state as unknown as JsonValue, paused: this.work?.paused ?? false, pausedAll: this.work?.pausedAll ?? false } }
    if (this.work === undefined) return base
    return { ...base, ...(await this.work.status()) }
  }

  async stop(): Promise<void> {
    await this.transition
    const work = this.work
    this.work = undefined
    await work?.stop(true)
    await this.leader.stop()
  }
}
