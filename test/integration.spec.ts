/**
 * Plugin core ↔ real Swift helper (no Accessibility needed): outbox delivery, ack, replay after the
 * plugin was down, reconnect after a helper restart. Skipped when the helper is not built.
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { ReflexCore } from '../src/core.js'
import { HelperClient } from '../src/helper/client.js'
import { reflexPaths, type ReflexPaths } from '../src/paths.js'
import { readJson, readText } from '../src/util/fs.js'
import { silentLogger, sleep } from '../src/util/misc.js'
import { FakeBridge, tempDir, waitFor } from './helpers.js'

const HELPER = join(process.cwd(), 'swift/.build/DSH Reflex Helper.app/Contents/MacOS/reflex-helper')
const enabled = existsSync(HELPER) && process.platform === 'darwin'

const RULES = `
version: 1
rules:
  - id: local-only
    on: sim.local.ping
    steps:
      - id: echo
        run: { argv: ["/usr/bin/true"] }
  - id: ask-dsh
    on: sim.ask.dsh
    steps:
      - id: ask
        dsh: { prompt: "summarize", target: new }
`

let helper: ChildProcess | undefined
const cores: ReflexCore[] = []

async function startHelper(paths: ReflexPaths): Promise<void> {
  helper = spawn(HELPER, ['--home', paths.dshHome, '--idle-exit', '0'], { stdio: 'ignore' })
  await waitFor(async () => (await readJson<{ pid?: number }>(paths.helperInfo))?.pid === helper?.pid, 10_000)
}

async function stopHelper(): Promise<void> {
  if (helper === undefined || helper.exitCode !== null) return
  const h = helper
  h.kill('SIGTERM')
  await waitFor(() => h.exitCode !== null || h.signalCode !== null, 10_000)
}

async function devClient(paths: ReflexPaths): Promise<HelperClient> {
  const info = await readJson<{ socket: string }>(paths.helperInfo)
  const token = (await readText(paths.helperToken))!.trim()
  return HelperClient.connect(info!.socket, token, { name: 'test', version: '0' })
}

function makeCore(paths: ReflexPaths, bridge = new FakeBridge()): ReflexCore {
  const core = new ReflexCore({
    paths, logger: silentLogger, bridge, hostName: 'test', version: '0.0.0-test', packageRoot: process.cwd(),
    settings: {
      autoLaunchHelper: false, helperIdleExitSec: 0, rulesFile: paths.rulesFile, workspacePath: paths.dataDir,
      allowedFileRoots: [paths.dataDir], stopGraceMs: 1000, defaultTaskTimeoutMs: 60_000, defaultRunTimeoutMs: 10_000,
      defaultDshTimeoutMs: 10_000, retentionDays: 30, programConfig: {},
    },
  })
  cores.push(core)
  return core
}

afterEach(async () => {
  for (const c of cores.splice(0)) await c.stop().catch(() => undefined)
  await stopHelper()
})

describe.skipIf(!enabled)('plugin core ↔ Swift helper', () => {
  it('delivers outbox events, runs rules, acks; DSH is called only by the dsh rule', async () => {
    const home = await tempDir('reflex-int-')
    const paths = reflexPaths(home)
    await startHelper(paths)
    await writeFile(paths.rulesFile, RULES)
    await writeFile(paths.devModeFile, '')
    const bridge = new FakeBridge()
    const core = makeCore(paths, bridge)
    core.start()
    await waitFor(() => core.active?.supervisor.state === 'connected', 10_000)
    const client = await devClient(paths)
    await expect(client.request('desktop.shutdown', {})).rejects.toThrow('only the active desktop')
    core.active!.menuLocale = 'zh-CN'
    await core.active!.updateMenu()
    expect((await client.request('helper.status', {}) as any).menu.locale).toBe('zh-CN')
    await client.request('sim.emit', { event: { eventType: 'sim.local.ping', resourceId: 'r1' } })
    await client.request('sim.emit', { event: { eventType: 'sim.ask.dsh', resourceId: 'r2' } })
    const runs = await waitFor(() => {
      const list = core.active!.store.list()
      return list.length === 2 && list.every((r) => r.status === 'succeeded') ? list : undefined
    }, 10_000)
    expect(runs.map((r) => r.ruleId).sort()).toEqual(['ask-dsh', 'local-only'])
    expect(bridge.calls).toHaveLength(1)
    const status = (await client.request('helper.status', {})) as { outbox: { depth: number } }
    await waitFor(async () => (((await client.request('helper.status', {})) as { outbox: { depth: number } }).outbox.depth === 0 ? true : undefined))
    void status
    client.close()
  })

  it('events emitted while the plugin is down are replayed once it is back', async () => {
    const home = await tempDir('reflex-int-')
    const paths = reflexPaths(home)
    await startHelper(paths)
    await writeFile(paths.rulesFile, RULES)
    await writeFile(paths.devModeFile, '')
    const client = await devClient(paths)
    await client.request('sim.emit', { event: { eventType: 'sim.local.ping', resourceId: 'while-down' } })
    client.close()
    const core = makeCore(paths)
    core.start()
    const run = await waitFor(() => core.active?.store.list().find((r) => r.status === 'succeeded'), 10_000)
    expect(run.ruleId).toBe('local-only')
  })

  it('reconnects after the helper restarts', async () => {
    const home = await tempDir('reflex-int-')
    const paths = reflexPaths(home)
    await startHelper(paths)
    await writeFile(paths.rulesFile, RULES)
    await writeFile(paths.devModeFile, '')
    const core = makeCore(paths)
    core.start()
    await waitFor(() => core.active?.supervisor.state === 'connected', 10_000)
    await stopHelper()
    await sleep(300)
    await startHelper(paths)
    await waitFor(() => core.active?.supervisor.state === 'connected', 20_000)
    const client = await devClient(paths)
    await client.request('sim.emit', { event: { eventType: 'sim.local.ping', resourceId: 'after-restart' } })
    client.close()
    const run = await waitFor(() => core.active?.store.list().find((r) => r.status === 'succeeded'), 10_000)
    expect(run.ruleId).toBe('local-only')
  })
})

describe.skipIf(!enabled || !existsSync(join(process.cwd(), 'swift/.build/debug/reflex-testprog')))('restart with a program task', () => {
  it('stops the helper and cancels the capture when DSH shuts down', async () => {
    const { copyFile, mkdir } = await import('node:fs/promises')
    const { execFileSync } = await import('node:child_process')
    const home = await tempDir('reflex-int-')
    const paths = reflexPaths(home)
    // Install the test program and confirm it as the user would.
    const dir = join(paths.programsDir, 'testprog')
    await mkdir(dir, { recursive: true })
    await copyFile(join(process.cwd(), 'swift/.build/debug/reflex-testprog'), join(dir, 'testprog'))
    const manifest = JSON.parse(execFileSync(join(dir, 'testprog'), ['--manifest'], { encoding: 'utf8' }))
    await writeFile(join(dir, 'manifest.json'), JSON.stringify(manifest))
    await mkdir(paths.stateDir, { recursive: true })
    await writeFile(join(paths.stateDir, 'programs.json'), JSON.stringify({ programs: { testprog: {
      enabled: true, grantedActions: [], config: {}, updatedAt: new Date().toISOString(),
      confirmed: { apps: manifest.apps, capabilities: manifest.capabilities, actions: [], version: manifest.version, confirmedAt: new Date().toISOString() },
    } } }))
    await writeFile(paths.rulesFile, `
version: 1
rules:
  - id: capture
    on: sim.meeting.started
    steps:
      - id: wait
        task: testprog/wait
        stopOn: sim.meeting.ended
        resumable: true
`)
    await writeFile(paths.devModeFile, '')
    await startHelper(paths)
    const first = makeCore(paths)
    first.start()
    await waitFor(() => first.active?.supervisor.state === 'connected', 10_000)
    // The rule references testprog, so the helper starts it (Finder is always running).
    const client = await devClient(paths)
    await waitFor(async () => (((await client.request('helper.status', {})) as any).programs as any[]).find((p) => p.id === 'testprog' && p.state === 'running'), 15_000)
    await client.request('sim.emit', { event: { eventType: 'sim.meeting.started', resourceId: 'm', correlationId: 'c1' } })
    const runId = (await waitFor(() => first.active?.store.list().find((r) => r.status === 'running')?.runId, 10_000))
    await waitFor(async () => ((await client.request('tasks.list', {})) as any[]).find((t) => t.taskId === `${runId}.wait`), 10_000)
    // Shutting down DSH deliberately interrupts capture.
    await first.stop()
    cores.splice(cores.indexOf(first), 1)
    client.close()
    const saved = JSON.parse(await (await import('node:fs/promises')).readFile(join(paths.runsDir, runId, 'run.json'), 'utf8'))
    expect(saved.status).toBe('cancelled')
    await waitFor(() => helper?.exitCode !== null || helper?.signalCode !== null, 10_000)
    await startHelper(paths)
    const inspection = await devClient(paths)
    expect(await inspection.request('tasks.list', {})).toEqual([])
    inspection.close()
    const second = makeCore(paths)
    second.start()
    await waitFor(() => second.active?.supervisor.state === 'connected', 10_000)
    expect((await second.active!.store.get(runId))?.status).toBe('cancelled')
  })
})
