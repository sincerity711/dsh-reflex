import { afterEach, expect, it } from 'vitest'
import { rm } from 'node:fs/promises'
import { LeaderWork, type CoreSettings } from '../src/core.js'
import { reflexPaths } from '../src/paths.js'
import type { ProgramManifest } from '../src/helper/protocol.js'
import { silentLogger } from '../src/util/misc.js'
import { FakeBridge, tempDir } from './helpers.js'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
it('does not inject a zero-second Teams grace into the helper desired config', async () => {
  const home = await tempDir(); roots.push(home)
  const paths = reflexPaths(home)
  const settings: CoreSettings = {
    autoLaunchHelper: false, helperIdleExitSec: 0, rulesFile: paths.rulesFile, workspacePath: home,
    allowedFileRoots: [home], stopGraceMs: 1000, defaultTaskTimeoutMs: 60000, defaultRunTimeoutMs: 60000,
    defaultDshTimeoutMs: 10000, retentionDays: 30, programConfig: {},
  }
  const work = new LeaderWork({ paths, settings, logger: silentLogger, bridge: new FakeBridge(), hostName: 'test', version: 'test', packageRoot: process.cwd() })
  const manifest: ProgramManifest = {
    id: 'teams', version: 'test', description: '', apps: ['com.microsoft.teams2'], capabilities: ['read'],
    actions: [], emits: [], tasks: [], config: { leaveGraceSec: 120 }, protocolVersion: 1, stallTimeoutSec: 120, lingerSec: 180,
  }
  const rules = { version: 1 as const, rules: [] }
  expect(work.programs.desired([manifest], rules)[0]?.config).toEqual({})
  settings.programConfig['teams'] = { leaveGraceSec: 180, captionPollMs: 500 }
  expect(work.programs.desired([manifest], rules)[0]?.config).toEqual({ leaveGraceSec: 180, captionPollMs: 500 })
})
