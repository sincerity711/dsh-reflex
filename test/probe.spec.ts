import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { analyzeFixture, isScriptedText, normalizeWords, renderReport, scriptWords, trimFixture, windowStates } from '../src/cli/probe.js'
import { tempDir } from './helpers.js'

function tree(entries: [string, string, string][], clock: string): object {
  return {
    role: 'AXApplication',
    children: [{
      role: 'AXWindow', subrole: 'AXStandardWindow', title: 'Standup | Microsoft Teams',
      children: [
        { role: 'AXButton', domId: 'hangup-button' },
        { role: 'AXGroup', domId: 'call-duration-custom', children: [{ role: 'AXStaticText', value: clock }] },
        { role: 'AXList', children: entries.map(([id, speaker, text]) => ({
          role: 'AXGroup', domClasses: ['fui-ChatMessageCompact__body'], chromeId: id,
          children: [{ role: 'AXStaticText', value: speaker }, { role: 'AXStaticText', value: text }],
        })) },
      ],
    }],
  }
}

describe('probe analysis', () => {
  it('matches scripted lines to captured captions per step', async () => {
    const dir = await tempDir()
    const file = join(dir, 'probe.jsonl')
    const lines = [
      { kind: 'meta', version: 1, bundleIds: ['com.microsoft.teams2'], startedAt: new Date().toISOString(), redaction: 'pseudo', limits: {}, tool: 'test', appVersions: {} },
      { kind: 'marker', t: 1, label: 'start:foreground' },
      { kind: 'marker', t: 1.1, label: 'say:foreground:0:The quarterly roadmap review starts with the mobile release.' },
      { kind: 'tree', t: 2.5, pid: 1, root: tree([['1', 'Xyz', 'The quarterly roadmap review starts']], '00:01') },
      { kind: 'tree', t: 3.5, pid: 1, root: tree([['1', 'Xyz', 'The quarterly roadmap review starts with the mobile release.']], '00:02') },
      { kind: 'marker', t: 5, label: 'say:foreground:1:Please confirm the budget numbers by Friday.' },
      { kind: 'marker', t: 10, label: 'end:foreground' },
      { kind: 'marker', t: 11, label: 'start:minimized' },
      { kind: 'marker', t: 11.1, label: 'say:minimized:0:The vendor contract expires in December.' },
      { kind: 'tree', t: 12, pid: 1, root: tree([['1', 'Xyz', 'The quarterly roadmap review starts with the mobile release.']], '00:02') },
      { kind: 'marker', t: 20, label: 'end:minimized' },
    ]
    await writeFile(file, lines.map((l) => JSON.stringify(l)).join('\n'))
    const report = await analyzeFixture(file)
    const fg = report.segments.find((s) => s.label === 'foreground')!
    const min = report.segments.find((s) => s.label === 'minimized')!
    expect(fg).toMatchObject({ spoken: 2, captured: 1 })
    expect(fg.avgLatencyMs).toBeGreaterThan(0)
    expect(min).toMatchObject({ spoken: 1, captured: 0 })
    expect(report.captions.revisionsPerIdMax).toBe(2)
    expect(renderReport(report)).toContain('| foreground |')
    expect(renderReport(report)).toContain('1/2')
  })

  it('script words are normalized and shared with the recorder', () => {
    expect(normalizeWords('Hello, World! 30%')).toEqual(['hello', 'world', '30'])
    expect(scriptWords()).toContain('quarterly')
  })
})

describe('probe trim', () => {
  it('recognizes scripted sentences and their in-progress prefixes, not other speech', () => {
    expect(isScriptedText('Please confirm the budget numbers by Friday.')).toBe(true)
    expect(isScriptedText('Please confirm the')).toBe(true)
    expect(isScriptedText('Support tickets dropped by 30% this month.')).toBe(true)
    expect(isScriptedText('Yeah, I guess I have got to figure it out for you.')).toBe(false)
    expect(isScriptedText('Hello, how are you?')).toBe(false)
    expect(isScriptedText('')).toBe(false)
  })

  it('keeps windows, anchors and scripted rows only, scrubs other titles and closes cut-out time', async () => {
    const dir = await tempDir()
    const input = join(dir, 'probe.jsonl')
    const output = join(dir, 'fixture.jsonl')
    const frame = (t: number, clock: string, rows: [string, string, string][]) => {
      const root = tree(rows, clock) as { children: object[] }
      root.children.push({ role: 'AXWindow', subrole: 'AXStandardWindow', title: 'Chat | Secret Project Chat | Microsoft Teams', children: [{ role: 'AXStaticText', value: 'private message' }] })
      return { kind: 'tree', t, pid: 1, root }
    }
    const lines = [
      { kind: 'meta', version: 1, bundleIds: ['com.microsoft.teams2'], startedAt: new Date().toISOString(), redaction: 'pseudo', limits: {}, tool: 'test' },
      { kind: 'apps', t: 0, apps: [{ pid: 1, bundleId: 'com.microsoft.teams2', name: 'Microsoft Teams' }] },
      frame(1, '00:01', [['1', 'Alice', 'Please confirm the budget numbers by Friday.'], ['2', 'Alice', 'Hello, how are you?']]),
      frame(2, '00:02', [['1', 'Alice', 'Please confirm the budget numbers by Friday.'], ['2', 'Alice', 'Hello, how are you?']]),
      frame(50, '00:50', [['3', 'Alice', 'Marketing will prepare the launch checklist.']]),
      { kind: 'notice', t: 51, pid: 1, name: 'AXValueChanged', element: { role: 'AXStaticText', value: 'secret' } },
      { kind: 'notice', t: 52, pid: 1, name: 'AXWindowMiniaturized', element: { role: 'AXWindow', title: 'Standup | Microsoft Teams' } },
    ]
    await writeFile(input, lines.map((l) => JSON.stringify(l)).join('\n'))
    const summary = await trimFixture(input, output, { ranges: [[0, 5], [49, 60]], scriptOnly: true, clockEverySec: 10 })
    const text = await readFile(output, 'utf8')
    expect(text).not.toContain('Hello, how are you')
    expect(text).not.toContain('Secret Project')
    expect(text).not.toContain('private message')
    expect(text).not.toContain('secret')
    expect(text).toContain('Please confirm the budget numbers by Friday.')
    expect(summary.droppedRows).toBe(2)
    const out = text.trim().split('\n').map((l) => JSON.parse(l) as { kind: string; t?: number; name?: string })
    // The timer-only change at 2 s is dropped (< clockEverySec); 49–60 follows 0–5 after a second.
    expect(out.filter((l) => l.kind === 'tree').map((l) => l.t)).toEqual([1, 7])
    expect(out.filter((l) => l.kind === 'notice').map((l) => [l.t, l.name])).toEqual([[9, 'AXWindowMiniaturized']])
  })

  it('names Teams 26246 window states', () => {
    const root = {
      role: 'AXApplication',
      children: [
        { role: 'AXWindow', subrole: 'AXDialog', minimized: true, children: [{ role: 'AXButton', domId: 'hangup-button' }] },
        { role: 'AXWindow', subrole: 'AXSystemDialog', children: [{ role: 'AXButton', domId: 'hangup-button' }] },
        { role: 'AXWindow', subrole: 'AXSystemDialog', children: [{ role: 'AXPopUpButton', domId: 'captions-settings-menu-trigger-button-non-overflow' }] },
      ],
    }
    expect(windowStates(root)).toEqual(['minimized', 'compact', 'popout'])
  })

  it('names windows the AXWindows list left out', () => {
    const root = {
      role: 'AXApplication',
      children: [
        { role: 'AXWindow', subrole: 'AXStandardWindow', title: 'Chat | Microsoft Teams' },
        { role: 'AXWindow', subrole: 'AXStandardWindow', unlisted: true, children: [{ role: 'AXButton', domId: 'hangup-button' }] },
        { role: 'AXWindow', subrole: 'AXSystemDialog', unlisted: true, children: [{ role: 'AXButton', domId: 'hangup-button' }] },
      ],
    }
    expect(windowStates(root)).toEqual(['unlisted:call', 'unlisted:compact'])
  })
})
