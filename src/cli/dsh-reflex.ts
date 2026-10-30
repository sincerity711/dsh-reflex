#!/usr/bin/env node
/** dsh-reflex CLI: helper management, dev tools (inspect/record/probe), programs, rules, status. */

import { createInterface } from 'node:readline'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { connectHelper, helperRunning } from '../helper/connect.js'
import type { HelperClient } from '../helper/client.js'
import { launchHelper } from '../helper/supervisor.js'
import { reflexPaths, type ReflexPaths } from '../paths.js'
import { ensurePrivateDir, errorMessage, pidAlive, removePath, writeFileAtomic, writeJsonAtomic } from '../util/fs.js'
import { parseDuration, sleep, type JsonValue } from '../util/misc.js'
import { bool, flag, flags, num, parseArgs, type ParsedArgs } from './args.js'
import { devModeUntil, ensureDev } from './devmode.js'
import { run } from './exec.js'
import { analyzeFixture, renderReport, runTeamsProbe, signalFileIO, terminalIO, trimFixture, TEAMS_BUNDLE } from './probe.js'
import { programCommand } from './programs.js'
import { controlCommand } from './control-client.js'
import { benchCommand } from './bench.js'

export const PACKAGE_ROOT = resolve(fileURLToPath(new URL('../..', import.meta.url)))

const HELP = `dsh-reflex — macOS UI events → DSH (helper + ReflexKit programs + DSH plugin)

helper:
  helper install [--debug]          编译、签名并安装 helper（需要 Swift/Xcode），并安装内置程序
  helper start | stop | restart     启动 / 停止 / 重启 helper
  helper status [--json]            helper 状态（权限、程序、任务、发件箱）
  helper access                     弹出辅助功能授权
  selftest [--app <bundleId>]       验证子进程能否继承 helper 的辅助功能授权

dev tools (需要先 dev on):
  dev on [--hours 2] | dev off | dev status
  ax inspect --app <bundleId> [--depth N] [--nodes N] [--redaction ui|pseudo|mask|none] [--json] [--out file]
  ax record --app <bundleId> [--duration 60s] [--out file] [--interval 0.5] [--keep '<selector>']... [--redaction pseudo]
  ax wake --app <bundleId>          打开 WebView 的 AX 树（AXEnhancedUserInterface / AXManualAccessibility）
  probe teams [--out dir] [--dwell 20] [--speak [--voice Samantha]] [--auto] [--steps a,b,...]
                                    交互式 Teams 探针（录制 + 报告；--speak 自动念台词；--auto 用 <out>/next 文件推进；--steps 只跑这些步骤）
  probe analyze <fixture.jsonl>     重新分析一份录制
  probe trim <in.jsonl> --out <file> [--range 10-260]... [--script-only] [--clock-every 5]
                                    把录制裁成回放测试样本（只留窗口、锚点、字幕；--script-only 只留探针台词）

programs:
  program new <id> --app <bundleId> [--dir path]
  program build [dir] | program test [dir] | program install [dir] | program lint [dir]
  program list | program run <id> --dev

plugin (需要 DSH 里已挂载插件):
  status [--json] | pause [--all] | resume
  runs [--limit N] | run <runId> | cancel <runId>
  rules validate [file] | rules path | rules reload
  sim <eventType> [--resource id] [--correlation id] [--payload '{"k":"v"}'] [--via plugin|helper]
  sim --file examples/sim/teams-meeting.jsonl [--delay 2s]   回放一串模拟事件

perf:
  bench [--duration 60s] [--interval 2s] [--label name] [--out docs/PERF.md]
`

async function main(argv: string[]): Promise<number> {
  const args = parseArgs(argv)
  const [cmd, sub] = args.positionals
  const paths = reflexPaths()
  if (cmd === undefined || cmd === 'help' || bool(args, 'help')) {
    process.stdout.write(HELP)
    return 0
  }
  switch (cmd) {
    case 'helper':
      return helperCommand(paths, sub, args)
    case 'selftest':
      return selftest(paths, args)
    case 'dev':
      return devCommand(paths, sub, args)
    case 'ax':
      return axCommand(paths, sub, args)
    case 'probe':
      return probeCommand(paths, sub, args)
    case 'program':
      return programCommand(paths, PACKAGE_ROOT, args)
    case 'bench':
      return benchCommand(paths, PACKAGE_ROOT, args)
    case 'status':
    case 'pause':
    case 'resume':
    case 'runs':
    case 'run':
    case 'cancel':
    case 'rules':
    case 'sim':
      return controlCommand(paths, args)
    default:
      process.stderr.write(`unknown command ${cmd}\n\n${HELP}`)
      return 64
  }
}

// MARK: helper

async function helperCommand(paths: ReflexPaths, sub: string | undefined, args: ParsedArgs): Promise<number> {
  switch (sub) {
    case 'install': {
      const script = join(PACKAGE_ROOT, 'scripts', 'build-helper.sh')
      const code = await run(script, bool(args, 'debug') ? ['--debug'] : [], { env: { DSH_HOME: paths.dshHome } })
      if (code !== 0) return code
      // Built-in programs (teams, browser) are installed when present.
      const programs = await import('./programs.js')
      let programsOK = true
      for (const id of ['teams', 'browser']) {
        const dir = join(PACKAGE_ROOT, 'programs', id)
        const ok = await programs.buildAndInstall(paths, PACKAGE_ROOT, dir, { quiet: true }).catch((error: unknown) => {
          process.stderr.write(`program ${id}: ${errorMessage(error)}\n`)
          return false
        })
        if (ok) process.stdout.write(`installed program ${id}\n`)
        else programsOK = false
      }
      if (!programsOK) return 1
      process.stdout.write('\n下一步：dsh-reflex helper start && dsh-reflex helper access（授予辅助功能权限），然后 dsh-reflex selftest\n')
      return 0
    }
    case 'start': {
      const client = await connectHelper(paths, { launch: true })
      printHelperInfo(client)
      client.close()
      return 0
    }
    case 'stop': {
      const pid = await helperRunning(paths)
      if (pid === undefined) {
        process.stdout.write('helper is not running\n')
        return 0
      }
      try {
        const client = await connectHelper(paths)
        await client.request('helper.shutdown', {})
        client.close()
      } catch {
        process.kill(pid, 'SIGTERM')
      }
      for (let i = 0; i < 50 && pidAlive(pid); i++) await sleep(100)
      process.stdout.write(pidAlive(pid) ? `helper ${pid} still running\n` : 'helper stopped\n')
      return 0
    }
    case 'restart': {
      await helperCommand(paths, 'stop', args)
      return helperCommand(paths, 'start', args)
    }
    case 'status': {
      const pid = await helperRunning(paths)
      if (pid === undefined) {
        process.stdout.write(`helper: not running (app: ${paths.helperApp})\n`)
        return 1
      }
      const client = await connectHelper(paths)
      const status = await client.request('helper.status', {})
      client.close()
      if (bool(args, 'json')) process.stdout.write(`${JSON.stringify(status, null, 2)}\n`)
      else process.stdout.write(formatHelperStatus(status))
      return 0
    }
    case 'access': {
      const client = await connectHelper(paths, { launch: true })
      const r = await client.request('helper.requestAccess', {})
      client.close()
      const trusted = (r as { trusted?: boolean }).trusted === true
      process.stdout.write(trusted
        ? '辅助功能权限：已授权\n'
        : '辅助功能权限：未授权。已打开“系统设置 → 隐私与安全性 → 辅助功能”，请打开 “DSH Reflex Helper”。授权后 helper 会自动重启生效。\n')
      return trusted ? 0 : 2
    }
    default:
      process.stderr.write('usage: dsh-reflex helper install|start|stop|restart|status|access\n')
      return 64
  }
}

function printHelperInfo(client: HelperClient): void {
  const i = client.info
  if (i === undefined) return
  process.stdout.write(`helper ${i.version} pid ${i.pid} · AX ${i.axTrusted ? '已授权' : '未授权'} · 签名 ${i.signing?.identity ?? 'ad-hoc'} · dev ${i.devMode ? 'on' : 'off'}\n`)
}

export function formatHelperStatus(status: JsonValue): string {
  const s = status as Record<string, any>
  const h = s['helper'] ?? {}
  const out: string[] = []
  const mb = (b: number | undefined): string => (b === undefined ? '?' : `${(b / 1048576).toFixed(1)}MB`)
  out.push(`helper ${h.version} pid ${h.pid} · 运行 ${Math.round((h.uptimeSec ?? 0) / 60)} 分钟 · RSS ${mb(h.rssBytes)} · CPU ${h.cpuPercent ?? 0}%`)
  out.push(`  辅助功能：${h.axTrusted ? '已授权' : '未授权'} · 签名：${h.signing?.identity ?? 'ad-hoc（每次重建要重新授权）'} · dev 模式：${h.devMode ? 'on' : 'off'}`)
  const ob = s['outbox'] ?? {}
  out.push(`  发件箱：待确认 ${ob.depth ?? 0} 条（lastSeq ${ob.lastSeq ?? 0}，${ob.consumer ? '插件已订阅' : '无订阅者'}）`)
  const programs = (s['programs'] ?? []) as any[]
  out.push(`  程序（${programs.length}）：`)
  for (const p of programs) {
    const proc = p.pid ? ` pid ${p.pid} RSS ${mb(p.rssBytes)} CPU ${p.cpuPercent}%` : ''
    out.push(`    ${p.id} ${p.version ?? ''} · ${p.enabled ? '启用' : '未启用'}${p.required ? '·被规则引用' : ''} · ${p.state}${proc}${p.appRunning ? ' · App 运行中' : ''}${p.lastError ? ` · 错误：${p.lastError}` : ''}`)
    if (p.status) out.push(`      状态：${JSON.stringify(p.status)}`)
  }
  const tasks = (s['tasks'] ?? []) as any[]
  if (tasks.length > 0) {
    out.push(`  任务（${tasks.length}）：`)
    for (const t of tasks) out.push(`    ${t.taskId} ${t.program}/${t.task} · ${t.state} · 开始于 ${t.startedAt}`)
  }
  return `${out.join('\n')}\n`
}

async function selftest(paths: ReflexPaths, args: ParsedArgs): Promise<number> {
  const client = await connectHelper(paths, { launch: true })
  const apps = flags(args, 'app')
  const r = (await client.request('selftest', { bundleIds: apps.length ? apps : [TEAMS_BUNDLE] }, 30_000)) as Record<string, any>
  client.close()
  if (bool(args, 'json')) {
    process.stdout.write(`${JSON.stringify(r, null, 2)}\n`)
  }
  const helperTrusted = r['helper']?.trusted === true
  process.stdout.write(`helper (pid ${r['helper']?.pid}) 辅助功能：${helperTrusted ? '已授权' : '未授权'}\n`)
  let allOk = helperTrusted
  for (const c of (r['children'] ?? []) as any[]) {
    const where = String(c.executable ?? '?').includes('.app/') ? 'bundle 内' : 'bundle 外'
    const windows = Array.isArray(c.windows) ? c.windows.length : 0
    const responsible = c.responsiblePid === r['helper']?.pid ? 'helper' : `pid ${c.responsiblePid ?? '?'}（不是 helper：helper 不是经 LaunchServices 启动的？）`
    process.stdout.write(`child (${where}, pid ${c.pid}, TCC 归属 ${responsible}) 授权：${c.trusted ? '继承成功' : '未继承'} · 目标 App：${(c.apps ?? []).length} 个进程 · 读到窗口 ${windows} 个${c.error ? ` · ${c.error}` : ''}\n`)
    allOk = allOk && c.trusted === true
  }
  if (!helperTrusted) process.stdout.write('先运行 dsh-reflex helper access 授权。\n')
  else process.stdout.write(allOk ? '✅ 子进程继承了 helper 的授权：程序可以作为独立进程运行。\n' : '❌ 子进程没有继承授权：需要改为把程序编进 helper 进程（见 PLAN P0）。\n')
  return allOk ? 0 : 2
}

// MARK: dev

async function devCommand(paths: ReflexPaths, sub: string | undefined, args: ParsedArgs): Promise<number> {
  switch (sub) {
    case 'on': {
      const hours = num(args, 'hours', 2)
      const until = new Date(Date.now() + hours * 3_600_000).toISOString()
      await ensurePrivateDir(paths.root)
      await writeFileAtomic(paths.devModeFile, `${until}\n`)
      process.stdout.write(`dev 模式已开启，到 ${until}（ax inspect / record / probe / program run --dev / sim 可用）\n`)
      return 0
    }
    case 'off':
      await removePath(paths.devModeFile)
      process.stdout.write('dev 模式已关闭\n')
      return 0
    default: {
      const until = await devModeUntil(paths)
      process.stdout.write(until === undefined ? 'dev 模式：off\n' : `dev 模式：on（${until === 'manual' ? '手动关闭' : `到 ${until.toISOString()}`}）\n`)
      return 0
    }
  }
}

// MARK: ax

async function axCommand(paths: ReflexPaths, sub: string | undefined, args: ParsedArgs): Promise<number> {
  await ensureDev(paths)
  const app = flag(args, 'app')
  if (app === undefined) throw new Error('--app <bundleId> is required')
  const client = await connectHelper(paths, { launch: true })
  try {
    switch (sub) {
      case 'wake': {
        const r = await client.request('ax.prepareWeb', { bundleId: app })
        process.stdout.write(`${JSON.stringify(r)}\n`)
        return 0
      }
      case 'inspect': {
        const params: Record<string, JsonValue> = { bundleId: app, redaction: bool(args, 'no-redact') ? 'none' : flag(args, 'redaction') ?? 'ui' }
        if (flag(args, 'depth') !== undefined) params['maxDepth'] = num(args, 'depth', 40)
        if (flag(args, 'nodes') !== undefined) params['maxNodes'] = num(args, 'nodes', 8000)
        if (flag(args, 'text') !== undefined) params['maxTextLength'] = num(args, 'text', 200)
        const r = (await client.request('ax.inspect', params, 120_000)) as { apps?: any[] }
        const text = bool(args, 'json') ? JSON.stringify(r, null, 2) : (r.apps ?? []).map((a) => renderTree(a)).join('\n\n')
        const out = flag(args, 'out')
        if (out !== undefined) {
          await writeFileAtomic(resolve(out), `${text}\n`)
          process.stdout.write(`wrote ${resolve(out)}\n`)
        } else {
          process.stdout.write(`${text}\n`)
        }
        if ((r.apps ?? []).length === 0) process.stderr.write(`${app} 没有在运行\n`)
        return 0
      }
      case 'record': {
        const durationMs = parseDuration(flag(args, 'duration') ?? '60s')
        const out = resolve(flag(args, 'out') ?? `ax-record-${app}-${Date.now()}.jsonl`)
        const recordId = `cli-${Date.now()}`
        const params: Record<string, JsonValue> = {
          bundleId: app, durationSec: durationMs / 1000, out, recordId,
          intervalSec: num(args, 'interval', 0.5), redaction: flag(args, 'redaction') ?? 'pseudo',
        }
        const keep = flags(args, 'keep')
        if (keep.length > 0) params['keep'] = keep
        if (flag(args, 'keyframe') !== undefined) params['keyframeSec'] = num(args, 'keyframe', 15)
        process.stdout.write(`录制 ${app} ${durationMs / 1000}s → ${out}\n回车添加标记（可先输入标记文字），Ctrl-C 提前结束。\n`)
        const pending = client.request('ax.record', params, 0)
        const rl = createInterface({ input: process.stdin })
        rl.on('line', (line) => {
          void client.request('ax.record.mark', { recordId, label: line.trim() || `mark-${new Date().toISOString()}` }).catch(() => undefined)
        })
        const stop = (): void => {
          void client.request('ax.record.stop', { recordId }).catch(() => undefined)
        }
        process.once('SIGINT', stop)
        const r = (await pending) as { summary?: JsonValue }
        rl.close()
        process.removeListener('SIGINT', stop)
        process.stdout.write(`${JSON.stringify(r.summary ?? r, null, 2)}\n`)
        return 0
      }
      default:
        process.stderr.write('usage: dsh-reflex ax inspect|record|wake --app <bundleId>\n')
        return 64
    }
  } finally {
    client.close()
  }
}

function renderTree(node: any, depth = 0, lines: string[] = []): string {
  const parts: string[] = [node.role ?? '?']
  if (node.subrole) parts.push(`[${node.subrole}]`)
  if (node.domId) parts.push(`#${node.domId}`)
  if (node.domClasses?.length) parts.push(node.domClasses.slice(0, 4).map((c: string) => `.${c}`).join(''))
  if (node.title) parts.push(`title=${JSON.stringify(node.title)}`)
  if (node.desc) parts.push(`desc=${JSON.stringify(node.desc)}`)
  if (node.value) parts.push(`value=${JSON.stringify(node.value)}`)
  if (node.identifier) parts.push(`id=${node.identifier}`)
  if (node.chromeId) parts.push(`cid=${node.chromeId}`)
  if (node.pid) parts.push(`pid=${node.pid}`)
  if (node.minimized) parts.push('minimized')
  if (node.unlisted) parts.push('unlisted')
  if (node.omittedChildren) parts.push(`(+${node.omittedChildren} omitted)`)
  lines.push(`${'  '.repeat(depth)}${parts.join(' ')}`)
  for (const c of node.children ?? []) renderTree(c, depth + 1, lines)
  return lines.join('\n')
}

// MARK: probe

async function probeCommand(paths: ReflexPaths, sub: string | undefined, args: ParsedArgs): Promise<number> {
  if (sub === 'analyze') {
    const file = args.positionals[2]
    if (file === undefined) throw new Error('usage: dsh-reflex probe analyze <fixture.jsonl>')
    const report = await analyzeFixture(resolve(file))
    const md = renderReport(report)
    const out = flag(args, 'out')
    if (out !== undefined) {
      await writeFileAtomic(resolve(out), md)
      await writeJsonAtomic(resolve(out).replace(/\.md$/, '.json'), report as unknown as JsonValue)
    }
    process.stdout.write(`${md}\n`)
    return 0
  }
  if (sub === 'trim') {
    const file = args.positionals[2]
    const out = flag(args, 'out')
    if (file === undefined || out === undefined) throw new Error('usage: dsh-reflex probe trim <in.jsonl> --out <file> [--range a-b]... [--script-only]')
    const ranges = flags(args, 'range').map((r) => {
      const m = /^(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)$/.exec(r)
      if (m === null) throw new Error(`bad --range ${r} (want e.g. 10-260)`)
      return [Number(m[1]), Number(m[2])] as const
    })
    const summary = await trimFixture(resolve(file), resolve(out), { ranges, scriptOnly: bool(args, 'script-only'), clockEverySec: num(args, 'clock-every', 5) })
    process.stdout.write(`${JSON.stringify(summary)}\n`)
    return 0
  }
  if (sub !== 'teams') {
    process.stderr.write('usage: dsh-reflex probe teams [--out dir] [--dwell 20] | probe analyze <fixture> | probe trim <fixture> --out <file>\n')
    return 64
  }
  await ensureDev(paths)
  const client = await connectHelper(paths, { launch: true })
  try {
    if (client.info?.axTrusted !== true) throw new Error('helper 还没有辅助功能权限：先运行 dsh-reflex helper access')
    const outDir = resolve(flag(args, 'out') ?? join(paths.dataDir, 'probes', new Date().toISOString().replace(/[:.]/g, '-')))
    const io = bool(args, 'auto') ? signalFileIO(outDir) : terminalIO()
    if (bool(args, 'auto')) process.stdout.write(`输出目录：${outDir}\n`)
    try {
      const report = await runTeamsProbe(client, {
        outDir, dwellSec: num(args, 'dwell', 20), intervalSec: num(args, 'interval', 0.5),
        redaction: (flag(args, 'redaction') as 'pseudo' | 'ui' | 'mask' | 'none' | undefined) ?? 'pseudo',
        ...(bool(args, 'speak') ? { speak: { voice: flag(args, 'voice') ?? 'Samantha', rate: num(args, 'rate', 170) } } : {}),
        ...(flag(args, 'steps') !== undefined ? { steps: flag(args, 'steps')!.split(',').map((x) => x.trim()).filter((x) => x !== '') } : {}),
      }, io)
      process.stdout.write(`\n报告：${report}\n录制样本（已脱敏）可直接用作 programs/teams 的测试 fixture。\n`)
    } finally {
      io.close()
    }
    return 0
  } finally {
    client.close()
  }
}

export { launchHelper }

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code
  },
  (error: unknown) => {
    process.stderr.write(`dsh-reflex: ${errorMessage(error)}\n`)
    process.exitCode = 1
  },
)
