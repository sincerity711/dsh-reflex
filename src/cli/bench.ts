/** `dsh-reflex bench`: sample helper/program CPU, RSS, and event latency; append a table to docs/PERF.md. */

import { appendFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { connectHelper } from '../helper/connect.js'
import type { ReflexPaths } from '../paths.js'
import { parseDuration, sleep } from '../util/misc.js'
import { flag, type ParsedArgs } from './args.js'

interface Sample {
  cpu: number
  rss: number
  footprint: number
  latency?: number
}

export async function benchCommand(paths: ReflexPaths, _root: string, args: ParsedArgs): Promise<number> {
  const durationMs = parseDuration(flag(args, 'duration') ?? '60s')
  const intervalMs = parseDuration(flag(args, 'interval') ?? '2s')
  const label = flag(args, 'label') ?? 'unlabeled'
  const client = await connectHelper(paths)
  const series = new Map<string, Sample[]>()
  const push = (k: string, s: Sample): void => {
    const list = series.get(k) ?? []
    list.push(s)
    series.set(k, list)
  }
  process.stdout.write(`sampling every ${intervalMs}ms for ${durationMs / 1000}s (${label})…\n`)
  const end = Date.now() + durationMs
  while (Date.now() < end) {
    const s = (await client.request('helper.status', {})) as Record<string, any>
    push('helper', { cpu: s['helper']?.cpuPercent ?? 0, rss: s['helper']?.rssBytes ?? 0, footprint: s['helper']?.footprintBytes ?? 0 })
    for (const p of (s['programs'] ?? []) as any[]) {
      if (p.pid === undefined) continue
      const latency = p.metrics?.avgEventLatencyMs
      push(`program:${p.id}`, { cpu: p.cpuPercent ?? 0, rss: p.rssBytes ?? 0, footprint: p.footprintBytes ?? 0, ...(typeof latency === 'number' && latency > 0 ? { latency } : {}) })
    }
    await sleep(intervalMs)
  }
  client.close()
  const avg = (xs: number[]): number => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0)
  const rows: string[] = []
  rows.push(`\n### ${label} · ${new Date().toISOString()} · ${durationMs / 1000}s\n`)
  rows.push('| 进程 | CPU 平均 | CPU 峰值 | RSS 平均 | RSS 峰值 | 物理占用（footprint）平均 | 事件延迟（平均） |', '|---|---|---|---|---|---|---|')
  for (const [k, samples] of series) {
    // The first CPU sample has no baseline; skip it.
    const cpu = samples.slice(1).map((x) => x.cpu)
    const rss = samples.map((x) => x.rss / 1048576)
    const lat = samples.map((x) => x.latency).filter((x): x is number => x !== undefined)
    const fp = samples.map((x) => x.footprint / 1048576)
    rows.push(`| ${k} | ${avg(cpu).toFixed(2)}% | ${Math.max(0, ...cpu).toFixed(2)}% | ${avg(rss).toFixed(1)}MB | ${Math.max(0, ...rss).toFixed(1)}MB | ${avg(fp).toFixed(1)}MB | ${lat.length ? `${avg(lat).toFixed(0)}ms` : '—'} |`)
  }
  const table = rows.join('\n')
  process.stdout.write(`${table}\n`)
  const out = flag(args, 'out')
  if (out !== undefined) {
    await appendFile(resolve(out), `${table}\n`)
    process.stdout.write(`appended to ${resolve(out)}\n`)
  }
  return 0
}
