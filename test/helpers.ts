import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Engine, type EngineConfig, type HelperPort } from '../src/dispatch/engine.js'
import type { DeliveryProgress, DshBridgeLike, DshDelivery, DshOutcome } from '../src/dispatch/dsh-bridge.js'
import { RunStore, TERMINAL, type RunRecord } from '../src/dispatch/runs-store.js'
import type { ReflexEvent, StopReason, TaskResultData } from '../src/helper/protocol.js'
import { parseRules } from '../src/rules/loader.js'
import type { RulesDocument } from '../src/rules/schema.js'
import { silentLogger, sleep, type JsonValue } from '../src/util/misc.js'

export async function tempDir(prefix = 'reflex-test-'): Promise<string> {
  return mkdtemp(join(tmpdir(), prefix))
}

export class FakeHelper implements HelperPort {
  connected = true
  started: { taskId: string; program: string; task: string; input: JsonValue; dir: string; resumable: boolean }[] = []
  stops: { taskId: string; reason: StopReason; graceMs: number }[] = []
  tasks = new Map<string, string>()
  private waiters: (() => void)[] = []

  async startTask(p: FakeHelper['started'][number]): Promise<void> {
    this.started.push(p)
    this.tasks.set(p.taskId, 'running')
  }

  async stopTask(taskId: string, reason: StopReason, graceMs: number): Promise<void> {
    this.stops.push({ taskId, reason, graceMs })
  }

  async listTasks(): Promise<{ taskId: string; state: string }[]> {
    return [...this.tasks].map(([taskId, state]) => ({ taskId, state }))
  }

  waitConnected(signal: AbortSignal): Promise<void> {
    if (this.connected) return Promise.resolve()
    return new Promise((resolve, reject) => {
      this.waiters.push(resolve)
      signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
    })
  }

  connect(): void {
    this.connected = true
    for (const w of this.waiters.splice(0)) w()
  }
}

export class FakeBridge implements DshBridgeLike {
  readonly available = true
  calls: DshDelivery[] = []
  outcome: (d: DshDelivery) => DshOutcome = () => ({ status: 'ok', sessionId: 'sess-1', messageId: 'msg-1', reply: '## 摘要\n测试纪要' })

  async deliver(d: DshDelivery, progress: (p: DeliveryProgress) => Promise<void>): Promise<DshOutcome> {
    this.calls.push(d)
    await progress({ sessionId: 'sess-1', messageId: `msg-${this.calls.length}`, seqBefore: 0 })
    return this.outcome(d)
  }
}

export function event(eventType: string, over: Partial<ReflexEvent> = {}): ReflexEvent {
  const id = over.eventId ?? `ev-${Math.random().toString(36).slice(2)}`
  return {
    eventId: id,
    eventType,
    timestamp: new Date().toISOString(),
    observedAt: new Date().toISOString(),
    app: { bundleId: 'com.microsoft.teams2', program: eventType.split('.')[0] ?? 'x' },
    resourceId: 'meeting:standup',
    correlationId: 'm1',
    identity: 'stable',
    dedupeKey: `${eventType}:m1`,
    payload: { title: 'Standup' },
    ...over,
  }
}

export interface Harness {
  dir: string
  engine: Engine
  store: RunStore
  helper: FakeHelper
  bridge: FakeBridge
  rules: RulesDocument
  config: EngineConfig
}

export async function harness(rulesYaml: string, over: Partial<EngineConfig> = {}, dir?: string, helper = new FakeHelper(), bridge = new FakeBridge()): Promise<Harness> {
  const root = dir ?? (await tempDir())
  const store = new RunStore(join(root, 'runs'))
  await store.load()
  const rules = parseRules(rulesYaml)
  const config: EngineConfig = {
    workspacePath: root,
    allowedFileRoots: [root],
    promptDirs: [join(process.cwd(), 'prompts')],
    defaultTaskTimeoutMs: 60_000,
    defaultRunTimeoutMs: 10_000,
    defaultDshTimeoutMs: 10_000,
    stopGraceMs: 1000,
    builtins: {},
    sessionMapFile: join(root, 'sessions.json'),
    ...over,
  }
  const engine = new Engine({ store, rules: () => rules, helper, bridge, logger: silentLogger, config })
  return { dir: root, engine, store, helper, bridge, rules, config }
}

export async function waitFor<T>(fn: () => T | undefined | false | Promise<T | undefined | false>, timeoutMs = 5000): Promise<T> {
  const end = Date.now() + timeoutMs
  for (;;) {
    const v = await fn()
    if (v !== undefined && v !== false) return v
    if (Date.now() > end) throw new Error('waitFor timed out')
    await sleep(10)
  }
}

export async function waitRunDone(h: Harness, runId: string): Promise<RunRecord> {
  return waitFor(async () => {
    const r = await h.store.get(runId)
    return r !== undefined && TERMINAL.has(r.status) ? r : undefined
  }, 10_000)
}

export function result(taskId: string, status: string, over: Partial<TaskResultData> = {}): TaskResultData {
  return { taskId, program: 'teams', task: 'captureCaptions', status, output: {}, files: [], ...over }
}
