import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { TeamsSettingsStore, previousTeamsRecords } from '../src/teams-settings.js'
import { RunStore, type RunRecord } from '../src/dispatch/runs-store.js'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function setup() {
  const root = await mkdtemp(join(tmpdir(), 'reflex-settings-')); roots.push(root)
  await mkdir(join(root, 'prompts')); await writeFile(join(root, 'prompts', 'meeting-summary.md'), 'default')
  return { root, settings: new TeamsSettingsStore(root, root, root) }
}
describe('Teams scenario settings', () => {
  it('validates, persists and rejects a stale concurrent edit without touching rules', async () => {
    const { root, settings } = await setup(); const rules = join(root, 'rules.yaml'); await writeFile(rules, 'custom rules')
    const initial = await settings.snapshot(); expect(initial.settings.lookbackMinutes).toBe(5)
    await expect(settings.save({ ...initial.settings, workspace: 'relative' })).rejects.toThrow()
    await expect(settings.save({ ...initial.settings, lookbackMinutes: 61 })).rejects.toThrow()
    await expect(settings.save({ ...initial.settings, model: { provider: '', model: 'chosen' } })).rejects.toThrow('模型')
    await expect(settings.save({ ...initial.settings, archiveDirectory: 'relative' })).rejects.toThrow('归档')
    const updated = await settings.saveChecked({ ...initial.settings, prompt: 'new prompt' }, initial.revision)
    expect(updated.settings.prompt).toBe('new prompt')
    await expect(settings.saveChecked(initial.settings, initial.revision)).rejects.toThrow('其他页面')
    expect((await settings.read()).prompt).toBe('new prompt'); expect(await readFile(rules, 'utf8')).toBe('custom rules')
  })
  it('keeps the explicit setup model and archive directory across reloads', async () => {
    const { root, settings } = await setup()
    const saved = { ...(await settings.read()), model: { provider: 'p', model: 'chosen' }, archiveDirectory: join(root, 'Meetings') }
    await settings.save(saved)
    expect(await new TeamsSettingsStore(root, root, '/other').read()).toEqual(saved)
  })
  it('offers only recent same-title records without changing the source', async () => {
    const { root } = await setup(); const store = new RunStore(join(root, 'runs')); await store.load()
    const make = (id: string, title: string, start: string, end: string) => ({ runId:id, ruleId:'teams-meeting-summary', status:'succeeded', createdAt:start, endedAt:end, dir:store.runDir(id), event:{ eventType:'teams.meeting.started', observedAt:start, payload:{title} }, steps:{ capture:{ endedAt:end } }, stepOrder:[], attachedEvents:[], dedupeKey:id }) as unknown as RunRecord
    const old = make('01AAAAAAAAAAAAAAAAAAAAAAAA', 'Standup', '2026-01-01T10:00:00Z', '2026-01-01T10:01:00Z')
    const other = make('01BBBBBBBBBBBBBBBBBBBBBBBB', 'Other', '2026-01-01T10:02:00Z', '2026-01-01T10:03:00Z')
    for (const run of [old, other]) { await store.create(run); await mkdir(join(run.dir, 'capture')); await writeFile(join(run.dir, 'capture', 'record.md'), run.runId); await store.save(run) }
    const current = make('01CCCCCCCCCCCCCCCCCCCCCCCC', 'STANDUP', '2026-01-01T10:04:00Z', '2026-01-01T10:05:00Z')
    expect(await previousTeamsRecords(store, current, 5)).toMatchObject([{runId:old.runId,record:old.runId}])
    expect(await previousTeamsRecords(store, current, 2)).toEqual([])
    expect(await readFile(join(old.dir, 'capture', 'record.md'), 'utf8')).toBe(old.runId)
  })
})
