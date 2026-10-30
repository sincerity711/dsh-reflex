/** Vault writes are performed by the plugin. The model never writes or rewrites a transcript. */
import { mkdir, realpath, readFile, lstat } from 'node:fs/promises'
import { isAbsolute, join, relative } from 'node:path'
import { readJson, readText, writeFileAtomic, writeJsonAtomic } from './util/fs.js'
import type { RunRecord, RunStore } from './dispatch/runs-store.js'

interface Segment { runId: string; startedAt: string; endedAt: string }
interface Manifest { source: 'dsh-reflex'; name: string; segments: Segment[] }
export interface ArchiveResult { note: string; transcript: string; summary: string; manifest: string }
const locks = new Map<string, Promise<unknown>>()
const validId = (id: string) => /^[0-9A-HJKMNP-TV-Z]{26}$/.test(id)

async function serial<T>(root: string, work: () => Promise<T>): Promise<T> {
  const pending = (locks.get(root) ?? Promise.resolve()).catch(() => undefined).then(work)
  locks.set(root, pending)
  try { return await pending } finally { if (locks.get(root) === pending) locks.delete(root) }
}

function inside(root: string, path: string): boolean {
  const rel = relative(root, path)
  return rel !== '..' && !rel.startsWith('../') && !isAbsolute(rel)
}

/** Refuse symlink escapes, including existing destination files, before atomic writes. */
async function directory(root: string, ...parts: string[]): Promise<string> {
  await mkdir(root, { recursive: true })
  const base = await realpath(root)
  let path = base
  for (const part of parts) {
    if (!part || part === '.' || part === '..' || /[\/\\]/.test(part)) throw new Error('invalid archive path')
    path = join(path, part)
    await mkdir(path).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'EEXIST') throw error })
    if (!inside(base, await realpath(path))) throw new Error('archive path escapes configured directory')
  }
  return path
}

async function writable(path: string): Promise<void> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => { if (error.code === 'ENOENT') return undefined; throw error })
  if (info && (!info.isFile() || info.isSymbolicLink())) throw new Error('archive destination is not a regular file')
}

async function put(path: string, content: string | Uint8Array): Promise<void> {
  await writable(path)
  await writeFileAtomic(path, content)
}

function segment(run: RunRecord): Segment {
  return { runId: run.runId, startedAt: run.event.observedAt, endedAt: run.steps['capture']?.endedAt ?? run.endedAt ?? run.event.observedAt }
}

/** Preserve every byte of original capture data before requesting a model. */
export async function preserveTeamsCapture(root: string, run: RunRecord): Promise<void> {
  if (!validId(run.runId)) throw new Error('invalid capture run id')
  await serial(root, async () => {
    const target = await directory(root, '_reflex-captures', run.runId)
    const source = await realpath(join(run.dir, 'capture'))
    for (const [from, to] of [['record.md', 'transcript.md'], ['record.json', 'transcript.json'], ['raw.jsonl', 'raw.jsonl'], ['gaps.json', 'gaps.json']] as const) {
      const path = await realpath(join(source, from)).catch((error: NodeJS.ErrnoException) => { if (error.code === 'ENOENT' && from !== 'record.md') return undefined; throw error })
      if (!path) continue
      if (!inside(source, path)) throw new Error('capture file escapes run directory')
      await put(join(target, to), await readFile(path))
    }
    await put(join(target, 'metadata.json'), JSON.stringify({ ...segment(run), title: String(run.event.payload['title'] ?? ''), source: 'teams-live-captions' }, null, 2) + '\n')
  })
}

/** Only this leading marker can request a merge; IDs must have been offered by this run. */
export function parseSummaryReply(reply: string, allowed: readonly string[]): { summary: string; previousRunIds: string[] } {
  const marker = /^\s*<!--\s*reflex-merge:\s*(\[[^\r\n]*\])\s*-->\s*\n?/.exec(reply)
  if (!marker) {
    if (allowed.length) throw new Error('模型未返回会议片段选择，无法确认纪要与原文一致')
    return { summary: reply, previousRunIds: [] }
  }
  const ids: unknown = JSON.parse(marker[1]!)
  if (!Array.isArray(ids) || ids.some(id => typeof id !== 'string' || !allowed.includes(id))) throw new Error('模型返回了不在本次候选范围内的会议片段')
  const summary = reply.slice(marker[0].length).trim()
  if (!summary) throw new Error('模型未返回会议纪要')
  return { summary, previousRunIds: [...new Set(ids as string[])] }
}

async function manifestFor(root: string, store: RunStore, id: string): Promise<Manifest | undefined> {
  const pointer = await readJson<{ name: string; directory: string }>(join(store.runDir(id), 'archive.json'))
  if (!pointer?.name || /[\/\\]/.test(pointer.name) || pointer.name === '.' || pointer.name === '..') return undefined
  const base = await realpath(root)
  if (pointer.directory !== base) return undefined
  const path = await realpath(join(base, pointer.name, 'reflex.json')).catch(() => undefined)
  if (!path || !inside(base, path)) return undefined
  const data = await readJson<Manifest>(path)
  if (data?.source !== 'dsh-reflex' || data.name !== pointer.name || !Array.isArray(data.segments) || data.segments.some(s => !validId(s.runId) || !Number.isFinite(Date.parse(s.startedAt)))) return undefined
  return data
}

function safeTitle(title: string): string {
  return title.replace(/[\x00-\x1f\x7f/\\:*?"<>|\[\]#^]/g, ' ').replace(/\s+/g, ' ').replace(/^[. ]+|[. ]+$/g, '').slice(0, 100).trim() || 'Teams meeting'
}

export async function archiveTeamsMeeting(root: string, run: RunRecord, store: RunStore, previousRunIds: readonly string[], summary?: string): Promise<ArchiveResult> {
  return serial(root, async () => {
    const base = await directory(root)
    const members = new Map<string, Segment>()
    let anchor = await manifestFor(root, store, run.runId)
    for (const id of previousRunIds) {
      if (!validId(id)) throw new Error('invalid merge run id')
      const prior = await manifestFor(root, store, id)
      if (prior) {
        anchor ??= prior
        for (const member of prior.segments) members.set(member.runId, member)
      } else {
        const priorRun = await store.get(id)
        if (!priorRun) throw new Error(`合并片段不存在：${id}`)
        // Old runs may predate vault archiving. Copy complete files, never the bounded prompt preview.
        // This call is intentionally inline because the archive root is already locked.
        const target = await directory(root, '_reflex-captures', id)
        const captureRoot = await realpath(join(store.runDir(id), 'capture'))
        for (const [from, to] of [['record.md', 'transcript.md'], ['record.json', 'transcript.json'], ['raw.jsonl', 'raw.jsonl'], ['gaps.json', 'gaps.json']] as const) {
          const path = await realpath(join(captureRoot, from)).catch((error: NodeJS.ErrnoException) => { if (error.code === 'ENOENT' && from !== 'record.md') return undefined; throw error })
          if (!path) continue
          if (!inside(captureRoot, path)) throw new Error('capture file escapes run directory')
          await put(join(target, to), await readFile(path))
        }
        members.set(id, segment(priorRun))
      }
    }
    if (anchor) for (const member of anchor.segments) members.set(member.runId, member)
    if (summary !== undefined && [...members.values()].some(s => Date.parse(s.startedAt) > Date.parse(run.event.observedAt))) throw new Error('会议归档已有更新的片段，请重试总结以免覆盖新纪要')
    members.set(run.runId, segment(run))
    const segments = [...members.values()].sort((a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt) || a.runId.localeCompare(b.runId))
    const title = safeTitle(String(run.event.payload['title'] ?? 'Teams meeting'))
    const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(segments[0]!.startedAt))
    let name = anchor?.name ?? `${date} - ${title}`
    if (!anchor && ((await lstat(join(base, name)).catch(() => undefined)) || (await lstat(join(base, `${name}.md`)).catch(() => undefined)))) {
      const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Shanghai', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(run.event.observedAt)).replaceAll(':', '')
      name += ` ${clock}-${run.runId}`
    }
    const folder = await directory(root, name)
    const transcript = join(folder, 'transcript.md'), summaryPath = join(folder, 'ai-summary.md'), note = join(base, `${name}.md`)
    const originals: string[] = []
    for (const item of segments) {
      const source = await directory(root, '_reflex-captures', item.runId)
      const path = await realpath(join(source, 'transcript.md'))
      if (!inside(base, path)) throw new Error('archived transcript escapes configured directory')
      originals.push(await readFile(path, 'utf8'))
    }
    // A single segment is byte-for-byte identical; multiple segments keep all original text and provenance.
    const combined = segments.length === 1 ? originals[0]! : segments.map((item, i) => `<!-- dsh-reflex run: ${item.runId}; start: ${item.startedAt} -->\n\n${originals[i]!}`).join('\n\n---\n\n')
    await put(transcript, combined)
    if (summary !== undefined) await put(summaryPath, summary + '\n')
    const manifest: Manifest = { source: 'dsh-reflex', name, segments }
    await put(join(folder, 'reflex.json'), JSON.stringify(manifest, null, 2) + '\n')
    const refs = segments.map(s => `- [[_reflex-captures/${s.runId}/transcript|${s.runId}]] (${s.startedAt} – ${s.endedAt})`).join('\n')
    const summaryBlock = summary !== undefined || await readText(summaryPath) !== undefined ? `![[${name}/ai-summary.md]]` : 'Minutes have not been generated yet; the original captions have been saved.'
    await put(note, `---\ntype: meeting\nsource: dsh-reflex\ndate: ${date}\ntitle: ${JSON.stringify(String(run.event.payload['title'] ?? title))}\nstart: ${segments[0]!.startedAt}\nend: ${segments.at(-1)!.endedAt}\n---\n\n# ${title}\n\nSource: Teams live captions (not Teams recap). Speech recognition errors and capture gaps may be present. Time zone: Asia/Shanghai.\n\n## AI Summary\n\n${summaryBlock}\n\n## Transcript\n\n![[${name}/transcript.md]]\n\n## Original Capture Segments\n\n${refs}\n`)
    await writeJsonAtomic(join(run.dir, 'archive.json'), { name, directory: base })
    return { note, transcript, summary: summaryPath, manifest: join(folder, 'reflex.json') }
  })
}
