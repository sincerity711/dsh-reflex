import { open, realpath, stat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { isAbsolute, join, relative } from 'node:path'
import { readJson, readText, writeJsonAtomic } from './util/fs.js'
import type { RunRecord, RunStore } from './dispatch/runs-store.js'
import type { ModelSelection } from '@deepseek-ai/dsh-agent'

export interface TeamsSettings {
  prompt: string
  workspace: string
  lookbackMinutes: number
  model?: ModelSelection | null
  /** Empty/absent disables vault archiving. */
  archiveDirectory?: string
}

/** Settings are independent of rules.yaml: editing a scenario never rewrites custom rules. */
export class TeamsSettingsStore {
  constructor(private readonly root: string, private readonly packageRoot: string, private readonly defaultWorkspace: string) {}

  private saves: Promise<void> = Promise.resolve()

  private get path(): string { return join(this.root, 'state', 'teams-settings.json') }

  async read(): Promise<TeamsSettings> {
    const saved = await readJson<Partial<TeamsSettings>>(this.path)
    return {
      prompt: saved?.prompt ?? (await readText(join(this.packageRoot, 'prompts', 'meeting-summary.md'))) ?? '',
      workspace: saved?.workspace ?? this.defaultWorkspace,
      lookbackMinutes: saved?.lookbackMinutes ?? 5,
      model: saved?.model ?? null,
      archiveDirectory: saved?.archiveDirectory ?? '',
    }
  }

  async hasSaved(): Promise<boolean> { return (await stat(this.path).catch(() => undefined))?.isFile() === true }

  async snapshot(): Promise<{ settings: TeamsSettings; revision: string }> {
    const settings = await this.read()
    return { settings, revision: createHash('sha256').update(JSON.stringify(settings)).digest('hex') }
  }

  async saveChecked(value: TeamsSettings, revision: string): Promise<{ settings: TeamsSettings; revision: string }> {
    const work = this.saves.then(async () => {
      if ((await this.snapshot()).revision !== revision) throw new Error('设置已在其他页面更改，请刷新后重试')
      await this.save(value)
      return this.snapshot()
    })
    this.saves = work.then(() => undefined, () => undefined)
    return work
  }

  async save(value: TeamsSettings): Promise<void> {
    if (typeof value.prompt !== 'string' || !value.prompt.trim() || value.prompt.length > 50000) throw new Error('请输入不超过 50000 字符的总结提示词')
    if (typeof value.workspace !== 'string' || !isAbsolute(value.workspace)) throw new Error('工作目录必须是绝对路径')
    if (!(await stat(value.workspace).catch(() => undefined))?.isDirectory()) throw new Error('工作目录不存在或不是文件夹')
    if (!Number.isInteger(value.lookbackMinutes) || value.lookbackMinutes < 0 || value.lookbackMinutes > 60) throw new Error('回看时间必须是 0–60 分钟')
    if (value.model != null && (typeof value.model.provider !== 'string' || !value.model.provider.trim() || typeof value.model.model !== 'string' || !value.model.model.trim() || value.model.provider.length > 200 || value.model.model.length > 200 || (value.model.reasoningEffort !== undefined && (typeof value.model.reasoningEffort !== 'string' || value.model.reasoningEffort.length > 100)))) throw new Error('请选择有效的任务模型')
    if (value.archiveDirectory !== undefined && (typeof value.archiveDirectory !== 'string' || (value.archiveDirectory !== '' && !isAbsolute(value.archiveDirectory)))) throw new Error('归档目录必须是绝对路径或留空')
    await writeJsonAtomic(this.path, { prompt: value.prompt, workspace: value.workspace, lookbackMinutes: value.lookbackMinutes,
      model: value.model ? { provider: value.model.provider, model: value.model.model, ...(value.model.reasoningEffort ? { reasoningEffort: value.model.reasoningEffort } : {}) } : null,
      archiveDirectory: value.archiveDirectory ?? '', })
  }
}

async function boundedText(root: string, name: string, limit: number): Promise<string | undefined> {
  const base = await realpath(root)
  const path = await realpath(join(root, name))
  const rel = relative(base, path)
  if (rel === '..' || rel.startsWith('../') || isAbsolute(rel)) return undefined
  const file = await open(path, 'r').catch(() => undefined)
  if (!file) return undefined
  try { const buffer = Buffer.alloc(limit); const { bytesRead } = await file.read(buffer, 0, limit, 0); return buffer.subarray(0, bytesRead).toString('utf8') }
  finally { await file.close() }
}

/** Collect only explicitly matched prior Teams runs. Content is returned as untrusted input. */
export interface PreviousTeamsRecord { runId: string; startedAt: string; endedAt: string; record: string; recordPath: string; archiveTranscriptPath?: string; summary?: string }

export async function previousTeamsRecords(store: RunStore, current: RunRecord, minutes: number, archiveDirectory?: string): Promise<PreviousTeamsRecord[]> {
  const title = String(current.event.payload?.['title'] ?? '').trim().toLocaleLowerCase()
  const started = Date.parse(current.event.observedAt)
  if (!title || !Number.isFinite(started) || minutes <= 0) return []
  const results: PreviousTeamsRecord[] = []
  for (const item of store.list(100)) {
    if (item.runId === current.runId || item.eventType !== 'teams.meeting.started') continue
    const run = await store.get(item.runId).catch(() => undefined)
    if (!run || String(run.event.payload?.['title'] ?? '').trim().toLocaleLowerCase() !== title) continue
    const end = Date.parse(run.steps['capture']?.endedAt ?? run.endedAt ?? '')
    if (!Number.isFinite(end) || end > started || started - end > minutes * 60000) continue
    const record = await boundedText(store.runDir(run.runId), 'capture/record.md', 100000).catch(() => undefined)
    if (!record) continue
    const summary = await boundedText(store.runDir(run.runId), 'summary.md', 50000).catch(() => undefined)
    let archiveTranscriptPath: string | undefined
    if (archiveDirectory) {
      const pointer = await readJson<{ name: string; directory: string }>(join(store.runDir(run.runId), 'archive.json')).catch(() => undefined)
      if (pointer?.name && !/[\/\\]/.test(pointer.name) && pointer.name !== '.' && pointer.name !== '..') {
        const base = await realpath(archiveDirectory).catch(() => undefined)
        const target = await realpath(join(archiveDirectory, pointer.name, 'transcript.md')).catch(() => undefined)
        if (base && target && pointer.directory === base && !relative(base, target).startsWith('..') && !isAbsolute(relative(base, target))) archiveTranscriptPath = target
      }
    }
    results.push({ runId: run.runId, startedAt: run.event.observedAt, endedAt: new Date(end).toISOString(), recordPath: join(store.runDir(run.runId), 'capture', 'record.md'), record, ...(archiveTranscriptPath ? { archiveTranscriptPath } : {}), ...(summary ? { summary } : {}) })
    if (results.length >= 5) break
  }
  return results
}
