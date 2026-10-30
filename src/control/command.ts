/** `/reflex …` slash command: handled by the host without involving the model. */

import type { ReflexCore } from '../core.js'
import { errorMessage } from '../util/fs.js'
import type { JsonValue } from '../util/misc.js'
import { formatStatus } from './format.js'

export const REFLEX_USAGE = [
  '/reflex [status]                         状态（不触发模型）',
  '/reflex pause [--all] | resume           暂停派发（--all 同时停掉所有程序）/ 恢复',
  '/reflex rules [reload]                   规则文件状态 / 重新加载',
  '/reflex runs | run <runId> | cancel <runId>',
  '/reflex program list',
  '/reflex program enable <id> [--confirm <code>]   查看并确认程序申请的能力后启用',
  '/reflex program disable <id> | restart <id>',
  '/reflex helper restart                   重启 helper（清除熔断）',
  '/reflex access                           弹出辅助功能授权',
  '/reflex sim <eventType> [JSON payload]   注入模拟事件（需要 dev 模式）',
].join('\n')

export interface CommandResultText {
  readonly kind: 'success' | 'error'
  readonly text: string
}

function tokenize(input: string): string[] {
  const out: string[] = []
  const re = /"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(input)) !== null) out.push(m[1] ?? m[2] ?? m[3] ?? '')
  return out
}

export async function runReflexCommand(core: ReflexCore, rawInput: string): Promise<CommandResultText> {
  const args = tokenize(rawInput.trim())
  const [cmd = 'status', sub, third] = args
  const ok = (text: string): CommandResultText => ({ kind: 'success', text })
  try {
    if (cmd === 'help') return ok(REFLEX_USAGE)
    if (cmd === 'status') return ok(formatStatus(await core.status()))
    const work = core.active
    if (work === undefined) {
      const st = core.leader.state
      return { kind: 'error', text: `这个 DSH 实例不是 dsh-reflex 的主实例（${st.state === 'passive' ? st.reason : st.state}）。请在主实例里执行。` }
    }
    switch (cmd) {
      case 'pause':
        return ok(await work.pause(args.includes('--all')))
      case 'resume':
        return ok(await work.resume())
      case 'rules': {
        const st = sub === 'reload' ? await work.rules.load() : work.rules.status
        return ok([`规则文件：${st.file}`, `状态：${st.state}，${st.ruleCount} 条`, ...st.errors.map((e) => `✗ ${e}`)].join('\n'))
      }
      case 'runs': {
        const runs = work.store.list(15)
        if (runs.length === 0) return ok('还没有 run。')
        return ok(runs.map((r) => `${r.runId} ${r.ruleId} · ${r.status}${r.currentStep ? `(${r.currentStep})` : ''} · ${r.createdAt}${r.error ? ` · ${r.error}` : ''}`).join('\n'))
      }
      case 'run': {
        if (sub === undefined) return { kind: 'error', text: '用法：/reflex run <runId>' }
        const run = await work.store.get(sub)
        if (run === undefined) return { kind: 'error', text: `没有 run ${sub}` }
        const lines = [`${run.runId} · 规则 ${run.ruleId} · ${run.status}${run.error ? ` · ${run.error}` : ''}`, `目录：${run.dir}`, `事件：${run.event.eventType}（${run.event.observedAt}）`]
        for (const id of run.stepOrder) {
          const s = run.steps[id]
          if (s === undefined) continue
          lines.push(`  ${id} [${s.kind}] ${s.state === 'running' ? '进行中' : s.status}${s.error ? ` · ${s.error}` : ''}${s.sessionId ? ` · 会话 ${s.sessionId}` : ''}`)
        }
        return ok(lines.join('\n'))
      }
      case 'cancel': {
        if (sub === undefined) return { kind: 'error', text: '用法：/reflex cancel <runId>' }
        return ok((await work.engine.cancelRun(sub, 'cancelled with /reflex cancel')) ? `已请求取消 ${sub}` : `${sub} 不在运行`)
      }
      case 'program':
        return ok(await programCommand(core, sub, third, args))
      case 'helper': {
        if (sub !== 'restart') return { kind: 'error', text: '用法：/reflex helper restart' }
        const client = work.supervisor.client
        if (client !== undefined) await client.request('helper.shutdown', {}).catch(() => undefined)
        work.supervisor.reset()
        return ok('helper 正在重启。')
      }
      case 'access': {
        const client = work.supervisor.client
        if (client === undefined) return { kind: 'error', text: `helper 未连接（${work.supervisor.state}${work.supervisor.lastError ? `：${work.supervisor.lastError}` : ''}）` }
        const r = (await client.request('helper.requestAccess', {})) as { trusted?: boolean }
        return ok(r.trusted === true ? '辅助功能权限：已授权。' : '已打开“系统设置 → 隐私与安全性 → 辅助功能”，请打开 DSH Reflex Helper。授权后 helper 会自动重启生效。')
      }
      case 'sim': {
        if (sub === undefined) return { kind: 'error', text: '用法：/reflex sim <eventType> [JSON payload]' }
        const rest = args.slice(2).join(' ').trim()
        const payload = rest === '' ? {} : (JSON.parse(rest) as JsonValue)
        const r = await work.simulate({ eventType: sub, resourceId: 'sim', payload })
        return ok(`已注入 ${sub}：${JSON.stringify(r)}`)
      }
      default:
        return { kind: 'error', text: `未知子命令 ${cmd}\n${REFLEX_USAGE}` }
    }
  } catch (error) {
    return { kind: 'error', text: errorMessage(error) }
  }
}

async function programCommand(core: ReflexCore, sub: string | undefined, id: string | undefined, args: string[]): Promise<string> {
  const work = core.active!
  const installed = await work.installedPrograms()
  if (sub === undefined || sub === 'list') {
    if (installed.length === 0) return '还没有安装程序（dsh-reflex program install <dir>，或 dsh-reflex helper install 安装内置程序）。'
    return work.programs.views(installed, work.rules.rules).map((v) =>
      `${v.id} ${v.version ?? ''} · ${v.enabled ? '已启用' : v.needsConfirm ? '待重新确认' : '未启用'}${v.required ? ' · 被规则引用' : ''} · App ${v.apps.join(', ')} · 能力 ${v.capabilities.join(', ')}${v.reason ? `\n    ${v.reason}` : ''}`,
    ).join('\n')
  }
  if (id === undefined) throw new Error(`用法：/reflex program ${sub} <id>`)
  const manifest = installed.find((m) => m.id === id)
  switch (sub) {
    case 'enable': {
      if (manifest === undefined) throw new Error(`没有安装程序 ${id}`)
      const i = args.indexOf('--confirm')
      const code = i >= 0 ? args[i + 1] : undefined
      const r = await work.programs.enable(manifest, code)
      if (r.enabled) await work.pushPrograms()
      return r.text
    }
    case 'disable':
      await work.programs.disable(id)
      await work.pushPrograms()
      return `已停用 ${id}（进行中的任务会被取消）。`
    case 'restart': {
      const client = work.supervisor.client
      if (client === undefined) throw new Error('helper 未连接')
      await client.request('programs.restart', { id })
      return `已重启 ${id}。`
    }
    default:
      throw new Error(`未知子命令 program ${sub}`)
  }
}
