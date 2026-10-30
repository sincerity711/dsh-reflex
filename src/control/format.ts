/** Human-readable status (used by `/reflex status` and `dsh-reflex status`). */

import type { JsonValue } from '../util/misc.js'

type Any = Record<string, any>

const mb = (b: unknown): string => (typeof b === 'number' ? `${(b / 1048576).toFixed(1)}MB` : '?')

export function formatStatus(status: JsonValue): string {
  const s = (status ?? {}) as Any
  const out: string[] = []
  const plugin = s['plugin'] as Any | undefined
  if (plugin) {
    const leader = plugin['leader'] as Any | undefined
    out.push(`dsh-reflex ${plugin['version'] ?? ''} · ${leader?.['state'] === 'leader' ? '主实例' : `被动（${leader?.['reason'] ?? '另一个 DSH 实例是主实例'}）`}${plugin['paused'] ? ` · 已暂停${plugin['pausedAll'] ? '（含程序）' : ''}` : ''}`)
  }
  const sup = s['supervisor'] as Any | undefined
  const helperStatus = s['helper'] as Any | undefined
  const h = helperStatus?.['helper'] as Any | undefined
  if (h) {
    out.push(`helper ${h['version']} pid ${h['pid']} · 运行 ${Math.round((h['uptimeSec'] ?? 0) / 60)} 分钟 · RSS ${mb(h['rssBytes'])} · CPU ${h['cpuPercent'] ?? 0}%`)
    out.push(`  辅助功能：${h['axTrusted'] ? '已授权' : '未授权（/reflex access）'} · 签名：${h['signing']?.identity ?? 'ad-hoc'} · dev：${h['devMode'] ? 'on' : 'off'}`)
    const ob = helperStatus?.['outbox'] as Any | undefined
    if (ob) out.push(`  发件箱：待确认 ${ob['depth'] ?? 0}（lastSeq ${ob['lastSeq'] ?? 0}）`)
  } else if (sup) {
    out.push(`helper：${sup['state']}${sup['lastError'] ? ` · ${sup['lastError']}` : ''}`)
  }
  const rules = s['rules'] as Any | undefined
  if (rules) {
    out.push(`规则：${rules['file']} · ${rules['state'] === 'ok' ? `${rules['ruleCount']} 条有效` : rules['state'] === 'missing' ? '文件不存在' : `无效（沿用上一份 ${rules['ruleCount']} 条）`}`)
    for (const e of (rules['errors'] ?? []) as string[]) out.push(`  ✗ ${e}`)
  }
  const programs = (s['programs'] ?? helperStatus?.['programs'] ?? []) as Any[]
  if (programs.length > 0) {
    out.push('程序：')
    for (const p of programs) {
      const run = p['process'] as Any | undefined
      const proc = run?.['pid'] ? ` · pid ${run['pid']} RSS ${mb(run['rssBytes'])} CPU ${run['cpuPercent']}%` : p['pid'] ? ` · pid ${p['pid']} RSS ${mb(p['rssBytes'])} CPU ${p['cpuPercent']}%` : ''
      const enabled = p['enabled'] ? '启用' : p['needsConfirm'] ? '待确认' : '未启用'
      out.push(`  ${p['id']} ${p['version'] ?? ''} · ${enabled}${p['required'] ? ' · 被规则引用' : ''} · ${p['state'] ?? '-'}${proc}${p['restarts'] ? ` · 重启 ${p['restarts']} 次` : ''}${p['lastError'] ? ` · 错误：${p['lastError']}` : ''}`)
      const st = p['status'] as Any | undefined
      if (st && Object.keys(st).length > 0) out.push(`    ${JSON.stringify(st)}`)
      const loops = p['loops'] as Any[] | undefined
      if (loops && loops.length > 0) out.push(`    循环：${loops.map((l) => `${l['name']}（${l['ticks']} 次，平均 ${Number(l['avgHandlerMs'] ?? 0).toFixed(1)}ms）`).join('，')}`)
    }
  }
  const runs = s['runs'] as Any | undefined
  if (runs) {
    const active = (runs['active'] ?? []) as Any[]
    const recent = (runs['recent'] ?? []) as Any[]
    out.push(`运行中的 run：${active.length}`)
    for (const r of active) out.push(`  ${r['runId']} ${r['ruleId']} · ${r['status']}${r['currentStep'] ? `(${r['currentStep']})` : ''} · 开始 ${r['createdAt']}`)
    if (recent.length > 0) {
      out.push('最近的 run：')
      for (const r of recent.slice(0, 8)) out.push(`  ${r['runId']} ${r['ruleId']} · ${r['status']}${r['error'] ? ` · ${r['error']}` : ''} · ${r['endedAt'] ?? r['createdAt']}`)
    }
  }
  const events = (s['events'] ?? []) as Any[]
  if (events.length > 0) {
    out.push('最近的事件：')
    for (const e of events.slice(0, 8)) out.push(`  ${e['at']} ${e['eventType']} → ${e['decision']}`)
  }
  return `${out.join('\n')}\n`
}
