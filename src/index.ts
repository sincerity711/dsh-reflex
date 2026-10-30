/**
 * dsh-reflex: macOS UI events → rules → programs / external commands / DSH sessions.
 * The plugin is the rules + dispatch side; Accessibility lives in the separate helper app.
 * @module dsh-reflex
 */

import { readFileSync } from 'node:fs'
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-commands'
import { runReflexCommand } from './control/command.js'
import { PACKAGE_ROOT, ReflexCore, type CoreSettings } from './core.js'
import { HostDshBridge } from './dispatch/dsh-bridge.js'
import { reflexPaths } from './paths.js'
import { errorMessage, expandHome } from './util/fs.js'
import { parseDuration, type JsonObject, type Logger } from './util/misc.js'
import { makeReflexHandler, REFLEX_API_PREFIX } from './control/web.js'
import type { IncomingMessage, ServerResponse } from 'node:http'

export { ReflexCore, LeaderWork } from './core.js'
export { Engine, resolveNext, conditionsMatch } from './dispatch/engine.js'
export { parseRules, RuleStore, validateRulesFile } from './rules/loader.js'
export { validateRules, RulesError } from './rules/schema.js'
export type * from './helper/protocol.js'

export const name = 'dsh-reflex'

export const inject = [
  'commands',
  'agents',
  'sessions',
  'sessionController',
  'agentPresets',
  'permissionPresets',
  'workspaceRegistry',
  'sessionTitle',
  'agentDefaultModel',
  'llm',
]

export interface Config {
  readonly autoLaunchHelper?: boolean
  readonly helperIdleExitSec?: number
  readonly rulesFile?: string
  readonly workspacePath?: string
  readonly allowedFileRoots?: string[]
  readonly stopGraceSec?: number
  readonly defaultTaskTimeout?: string
  readonly defaultRunTimeout?: string
  readonly defaultDshTimeout?: string
  readonly retentionDays?: number
  readonly programs?: Record<string, JsonObject>
}

export const Config: z<Config> = z.object({
  autoLaunchHelper: z.boolean().default(true).description('Launch DSH Reflex Helper.app when it is not running.'),
  helperIdleExitSec: z.number().min(0).default(600).description('Helper exits after this many idle seconds (no clients, no tasks).'),
  rulesFile: z.string().description('Rules file. Default: $DSH_HOME/reflex/rules.yaml'),
  workspacePath: z.string().description('Workspace for reflex DSH sessions. Default: $DSH_HOME/reflex/data'),
  allowedFileRoots: z.array(z.string()).description('Directories whose files may be referenced in dsh steps. Default: the reflex data dir.'),
  stopGraceSec: z.number().min(1).default(60).description('Grace period for a task to finish after a stop signal.'),
  defaultTaskTimeout: z.string().default('12h'),
  defaultRunTimeout: z.string().default('5m'),
  defaultDshTimeout: z.string().default('30m'),
  retentionDays: z.number().min(1).default(30).description('Keep finished runs and event logs this many days.'),
  programs: z.dict(z.dict(z.any())).default({}).description('Per-program config overrides, e.g. { teams: { leaveGraceSec: 180 } }.'),
}) as unknown as z<Config>

function readVersion(): string {
  try {
    return (JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version?: string }).version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

export function resolveSettings(config: Config, dshHome: string): CoreSettings {
  const paths = reflexPaths(dshHome)
  return {
    autoLaunchHelper: config.autoLaunchHelper ?? true,
    helperIdleExitSec: config.helperIdleExitSec ?? 600,
    rulesFile: config.rulesFile ? expandHome(config.rulesFile) : paths.rulesFile,
    workspacePath: config.workspacePath ? expandHome(config.workspacePath) : paths.dataDir,
    allowedFileRoots: (config.allowedFileRoots?.length ? config.allowedFileRoots : [paths.dataDir]).map(expandHome),
    stopGraceMs: (config.stopGraceSec ?? 60) * 1000,
    defaultTaskTimeoutMs: parseDuration(config.defaultTaskTimeout ?? '12h'),
    defaultRunTimeoutMs: parseDuration(config.defaultRunTimeout ?? '5m'),
    defaultDshTimeoutMs: parseDuration(config.defaultDshTimeout ?? '30m'),
    retentionDays: config.retentionDays ?? 30,
    programConfig: config.programs ?? {},
  }
}

export function apply(ctx: Context, config: Config): void {
  if (process.platform !== 'darwin') {
    ctx.logger.warn('dsh-reflex: macOS only; the plugin stays idle on this platform')
    return
  }
  const paths = reflexPaths()
  const logger: Logger = {
    debug: (m) => ctx.logger.debug(m),
    info: (m) => ctx.logger.info(m),
    warn: (m) => ctx.logger.warn(m),
    error: (m) => ctx.logger.error(m),
  }
  const profile = (ctx.get('profileContext') as { name?: string } | undefined)?.name
  const core = new ReflexCore({
    paths, logger, bridge: new HostDshBridge(ctx, logger), hostName: profile ?? 'dsh', version: readVersion(),
    settings: resolveSettings(config, paths.dshHome), packageRoot: PACKAGE_ROOT,
  })
  ctx.effect(() => {
    try {
      core.start()
    } catch (error) {
      logger.error(`dsh-reflex: start failed: ${errorMessage(error)}`)
    }
    return async () => {
      await core.stop().catch((error: unknown) => logger.warn(`dsh-reflex: stop failed: ${errorMessage(error)}`))
    }
  }, 'dsh-reflex.core')
  ctx.inject(['webServer', 'connection'], webCtx => {
    const web = webCtx.get('webServer') as { register(route: { kind: 'prefix'; path: string; handler: (req: IncomingMessage, res: ServerResponse) => Promise<void> }): () => void }
    const connection = webCtx.get('connection') as { requestRejection(req: IncomingMessage): number | undefined }
    webCtx.effect(() => web.register({ kind: 'prefix', path: REFLEX_API_PREFIX, handler: makeReflexHandler(core, req => connection.requestRejection(req)) }), 'dsh-reflex.web')
  })
  ctx.commands.register({
    name: 'reflex',
    description: 'dsh-reflex: status, pause/resume, rules, runs, programs (no model involved)',
    input: { hint: 'status | pause [--all] | resume | rules | runs | program … | help' },
    recordInput: true,
    handler: async (invocation) => {
      const r = await runReflexCommand(core, invocation.rawInput)
      return r.kind === 'success' ? { kind: 'success', text: r.text } : { kind: 'error', text: r.text }
    },
  })

}
