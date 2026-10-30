import { afterEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { archiveTeamsMeeting, parseSummaryReply, preserveTeamsCapture } from '../src/meeting-archive.js'
import { RunStore, type RunRecord } from '../src/dispatch/runs-store.js'

const roots: string[] = []
afterEach(async () => { vi.unstubAllEnvs(); await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))) })
async function setup() {
  const root = await mkdtemp(join(tmpdir(), 'reflex-archive-')); roots.push(root)
  const store = new RunStore(join(root, 'runs')); await store.load()
  const vault = join(root, 'vault', '02_Sources', 'Meetings')
  async function capture(id: string, start: string, text: string) {
    const run = { runId: id, dir: store.runDir(id), ruleId: 'teams-meeting-summary', createdAt: start, status: 'succeeded',
      event: { eventType: 'teams.meeting.started', observedAt: start, payload: { title: '项目 / Standup' } },
      steps: { capture: { endedAt: new Date(Date.parse(start) + 60000).toISOString() } }, attachedEvents: [], stepOrder: [] } as unknown as RunRecord
    await mkdir(join(run.dir, 'capture'), { recursive: true })
    await writeFile(join(run.dir, 'capture', 'record.md'), text)
    await writeFile(join(run.dir, 'capture', 'raw.jsonl'), '{"original":"不改写"}\n')
    await writeFile(join(run.dir, 'capture', 'record.json'), '{"lines":[]}\n')
    await store.create(run)
    return run
  }
  return { root, vault, store, capture }
}
const firstId = '01AAAAAAAAAAAAAAAAAAAAAAAA', secondId = '01BBBBBBBBBBBBBBBBBBBBBBBB'

describe('programmatic Teams archive', () => {
  it('uses the runtime timezone instead of a developer-specific timezone', async () => {
    vi.stubEnv('TZ', 'UTC')
    const h = await setup()
    const run = await h.capture(firstId, '2026-10-28T23:59:00Z', 'source')
    await preserveTeamsCapture(h.vault, run)
    const result = await archiveTeamsMeeting(h.vault, run, h.store, [], 'summary')
    expect(result.note).toContain('2026-10-28')
    expect(await readFile(result.note, 'utf8')).toContain('Time zone: UTC.')
  })

  it('preserves complete source bytes, merges in time order and deduplicates retries by runId', async () => {
    const h = await setup()
    const original = '# 原文\n' + '很长的原始字幕🪴\n'.repeat(15000) + '[缺口 10:00–10:01]\n'
    const first = await h.capture(firstId, '2026-10-28T15:59:00Z', original)
    await preserveTeamsCapture(h.vault, first)
    const a = await archiveTeamsMeeting(h.vault, first, h.store, [], 'first summary')
    expect(await readFile(a.transcript, 'utf8')).toBe(original)
    expect(a.note).toContain('2026-10-28') // date in the runtime local timezone
    const second = await h.capture(secondId, '2026-10-28T16:01:00Z', '# second\n后续字幕\n')
    await preserveTeamsCapture(h.vault, second)
    const b = await archiveTeamsMeeting(h.vault, second, h.store, [firstId], 'combined summary')
    expect(b.note).toBe(a.note)
    const combined = await readFile(b.transcript, 'utf8')
    expect(combined).toContain(original)
    expect(combined.indexOf(original)).toBeLessThan(combined.indexOf('后续字幕'))
    expect(await readFile(b.summary, 'utf8')).toBe('combined summary\n')
    expect(await readFile(join(h.vault, '_reflex-captures', firstId, 'raw.jsonl'), 'utf8')).toBe('{"original":"不改写"}\n')
    await archiveTeamsMeeting(h.vault, second, h.store, [firstId], 'combined summary')
    expect(await readFile(b.transcript, 'utf8')).toBe(combined)
    expect(JSON.parse(await readFile(b.manifest, 'utf8')).segments).toHaveLength(2)
    await expect(archiveTeamsMeeting(h.vault, first, h.store, [], 'stale summary')).rejects.toThrow('更新的片段')
    expect(await readFile(b.summary, 'utf8')).toBe('combined summary\n')
  })

  it('does not overwrite a Teams recap or an independent same-title meeting', async () => {
    const h = await setup()
    await mkdir(h.vault, { recursive: true })
    const recap = join(h.vault, '2026-10-28 - 项目 Standup.md')
    await writeFile(recap, 'existing recap')
    const first = await h.capture(firstId, '2026-10-28T10:00:00Z', 'raw')
    await preserveTeamsCapture(h.vault, first)
    const a = await archiveTeamsMeeting(h.vault, first, h.store, [])
    expect(a.note).not.toBe(recap)
    expect(await readFile(recap, 'utf8')).toBe('existing recap')
    expect(await readFile(a.note, 'utf8')).toContain('Minutes have not been generated yet')
    const second = await h.capture(secondId, '2026-10-28T12:00:00Z', 'another')
    await preserveTeamsCapture(h.vault, second)
    const b = await archiveTeamsMeeting(h.vault, second, h.store, [], 'independent')
    expect(dirname(b.transcript)).not.toBe(dirname(a.transcript))
  })

  it('refuses symlink escapes while preserving the original outside file', async () => {
    const h = await setup()
    await mkdir(h.vault, { recursive: true })
    const outside = join(h.root, 'outside'); await mkdir(outside)
    await symlink(outside, join(h.vault, '_reflex-captures'))
    const run = await h.capture(firstId, '2026-10-28T10:00:00Z', 'raw')
    await expect(preserveTeamsCapture(h.vault, run)).rejects.toThrow('escapes')
  })

  it('accepts only merge candidates offered to the model and leaves transcript generation to code', () => {
    expect(parseSummaryReply(`<!-- reflex-merge: ["${firstId}","${firstId}"] -->\n## Summary\nresult`, [firstId])).toEqual({ summary: '## Summary\nresult', previousRunIds: [firstId] })
    expect(() => parseSummaryReply(`<!-- reflex-merge: ["${secondId}"] -->\nresult`, [firstId])).toThrow('候选范围')
    expect(parseSummaryReply('## Summary', [])).toEqual({ summary: '## Summary', previousRunIds: [] })
  })
})
