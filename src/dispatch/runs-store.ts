/** Durable runs: `runs/<runId>/run.json` plus an append-only `runs/index.jsonl`. */

import { join } from 'node:path'
import type { ReflexEvent } from '../helper/protocol.js'
import type { Rule } from '../rules/schema.js'
import { appendLine, ensurePrivateDir, readJson, readText, removePath, writeFileAtomic, writeJsonAtomic } from '../util/fs.js'
import type { JsonObject } from '../util/misc.js'
import type { TeamsSettings } from '../teams-settings.js'

export type RunStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'timed_out'
export const TERMINAL: ReadonlySet<RunStatus> = new Set(['succeeded', 'failed', 'cancelled', 'timed_out'])

export interface StepRecord {
  readonly id: string
  readonly kind: 'task' | 'run' | 'dsh'
  state: 'running' | 'done'
  status?: string
  startedAt: string
  endedAt?: string
  deadline?: string
  output?: JsonObject
  files?: string[]
  error?: string
  /** task */
  taskId?: string
  stopRequested?: string
  stopRequestedAt?: string
  /** run */
  pid?: number
  /** dsh */
  sessionId?: string
  messageId?: string
  seqBefore?: number
  reply?: string
  /** Freeze setup choices for an in-flight summary, including restart recovery. */
  teamsSettings?: TeamsSettings
}

export interface RunRecord {
  readonly runId: string
  readonly ruleId: string
  /** The rule as it was when the run was created (hot reloads do not change running runs). */
  readonly rule: Rule
  status: RunStatus
  readonly createdAt: string
  startedAt?: string
  endedAt?: string
  readonly dir: string
  readonly event: ReflexEvent
  readonly dedupeKey: string
  readonly concurrencyKey?: string
  currentStep?: string
  steps: Record<string, StepRecord>
  readonly stepOrder: string[]
  attachedEvents: { eventId: string; eventType: string; at: string; reason: string }[]
  error?: string
  cancelReason?: string
}

export interface RunSummary {
  readonly runId: string
  readonly ruleId: string
  readonly status: RunStatus
  readonly createdAt: string
  readonly endedAt?: string
  readonly dedupeKey: string
  readonly concurrencyKey?: string
  readonly eventType: string
  readonly currentStep?: string
  readonly error?: string
}

export function summarize(run: RunRecord): RunSummary {
  return {
    runId: run.runId, ruleId: run.ruleId, status: run.status, createdAt: run.createdAt, dedupeKey: run.dedupeKey,
    eventType: run.event.eventType,
    ...(run.endedAt ? { endedAt: run.endedAt } : {}),
    ...(run.concurrencyKey !== undefined ? { concurrencyKey: run.concurrencyKey } : {}),
    ...(run.currentStep ? { currentStep: run.currentStep } : {}),
    ...(run.error ? { error: run.error } : {}),
  }
}

export class RunStore {
  private readonly summaries = new Map<string, RunSummary>()
  private readonly live = new Map<string, RunRecord>()

  constructor(readonly dir: string) {}

  get indexFile(): string {
    return join(this.dir, 'index.jsonl')
  }

  runDir(runId: string): string {
    return join(this.dir, runId)
  }

  /** Load the index and every non-terminal run. */
  async load(): Promise<RunRecord[]> {
    await ensurePrivateDir(this.dir)
    const text = (await readText(this.indexFile)) ?? ''
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue
      try {
        const s = JSON.parse(line) as RunSummary
        this.summaries.set(s.runId, s)
      } catch {
        // ignore torn lines
      }
    }
    const active: RunRecord[] = []
    for (const s of this.summaries.values()) {
      if (TERMINAL.has(s.status)) continue
      const run = await readJson<RunRecord>(join(this.runDir(s.runId), 'run.json'))
      if (run === undefined) continue
      this.live.set(run.runId, run)
      if (!TERMINAL.has(run.status)) active.push(run)
      else this.summaries.set(run.runId, summarize(run))
    }
    return active.sort((a, b) => a.createdAt.localeCompare(b.createdAt))
  }

  async create(run: RunRecord): Promise<void> {
    await ensurePrivateDir(run.dir)
    this.live.set(run.runId, run)
    await writeJsonAtomic(join(run.dir, 'run.json'), run)
    await this.index(run)
  }

  /** Persist the run; terminal transitions are also appended to the index. */
  async save(run: RunRecord): Promise<void> {
    await writeJsonAtomic(join(run.dir, 'run.json'), run)
    const prev = this.summaries.get(run.runId)
    if (prev === undefined || prev.status !== run.status || prev.currentStep !== run.currentStep) await this.index(run)
    if (TERMINAL.has(run.status)) this.live.delete(run.runId)
  }

  private async index(run: RunRecord): Promise<void> {
    const s = summarize(run)
    this.summaries.set(run.runId, s)
    await appendLine(this.indexFile, JSON.stringify(s))
  }

  async get(runId: string): Promise<RunRecord | undefined> {
    return this.live.get(runId) ?? (await readJson<RunRecord>(join(this.runDir(runId), 'run.json')))
  }

  liveRun(runId: string): RunRecord | undefined {
    return this.live.get(runId)
  }

  /** Every non-terminal run (driven or still waiting to be resumed). */
  activeRuns(): RunRecord[] {
    return [...this.live.values()].filter((r) => !TERMINAL.has(r.status))
  }

  list(limit = 50): RunSummary[] {
    return [...this.summaries.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).slice(0, limit)
  }

  /** Most recent run of `ruleId` with this dedupe key created within `windowMs` (or still active). */
  findDuplicate(ruleId: string, dedupeKey: string, windowMs: number, now = Date.now()): RunSummary | undefined {
    let best: RunSummary | undefined
    for (const s of this.summaries.values()) {
      if (s.ruleId !== ruleId || s.dedupeKey !== dedupeKey) continue
      const active = !TERMINAL.has(s.status)
      const recent = now - Date.parse(s.createdAt) <= windowMs
      if (!active && !recent) continue
      if (best === undefined || s.createdAt > best.createdAt) best = s
    }
    return best
  }

  /** Remove finished runs older than `days` and rewrite the index. */
  async prune(days: number, now = Date.now()): Promise<number> {
    const cutoff = now - days * 86_400_000
    let removed = 0
    for (const s of [...this.summaries.values()]) {
      if (!TERMINAL.has(s.status)) continue
      if (Date.parse(s.endedAt ?? s.createdAt) >= cutoff) continue
      await removePath(this.runDir(s.runId))
      this.summaries.delete(s.runId)
      removed += 1
    }
    if (removed > 0) {
      const body = [...this.summaries.values()].map((s) => JSON.stringify(s)).join('\n')
      await writeFileAtomic(this.indexFile, body === '' ? '' : `${body}\n`)
    }
    return removed
  }
}
