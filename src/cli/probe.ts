/** `dsh-reflex probe teams`: guided recording of a real meeting + analysis report. */

import { execFile } from 'node:child_process'
import { createReadStream } from 'node:fs'
import { readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import type { HelperClient } from '../helper/client.js'
import { ensurePrivateDir, writeFileAtomic, writeJsonAtomic } from '../util/fs.js'
import { sleep, type JsonValue } from '../util/misc.js'

export const TEAMS_BUNDLE = 'com.microsoft.teams2'
const CAPTION_CLASS = 'fui-ChatMessageCompact__body'
const ANCHOR_IDS = ['hangup-button', 'call-duration-custom']

/** Selectors the probe recorder keeps at full rate (other branches only in keyframes). */
export const PROBE_KEEP = [
  '#hangup-button',
  '#call-duration-custom',
  `.${CAPTION_CLASS}`,
  '#~caption',
  '.~caption',
  '#~closed-captions',
]

interface ProbeStep {
  readonly id: string
  readonly instruction: string
}

export const PROBE_STEPS: readonly ProbeStep[] = [
  { id: 'foreground', instruction: '会议窗口保持在前台，正常说几句话。' },
  { id: 'background', instruction: '切到别的 App（会议窗口仍然可见，只是不在前台），继续说话。' },
  { id: 'covered', instruction: '用另一个窗口把会议窗口完全遮住，继续说话。' },
  { id: 'side-by-side', instruction: '会议窗口和 Teams 主窗口左右并排、互不遮挡（Window → Move & Resize → Left / Right），点一下主窗口：焦点在主窗口，会议窗口仍然完整可见。继续说话。' },
  { id: 'covered-full', instruction: '用一个铺满屏幕的窗口（例如 TextEdit 的 Window → Fill）把会议窗口整个盖住，一点都不露。继续说话。' },
  { id: 'minimized', instruction: '把会议窗口最小化，继续说话。' },
  { id: 'popout', instruction: '恢复会议窗口，在字幕区的 ⋯ 菜单里选“弹出字幕”（Pop out），说几句话。没有这个选项就直接回车。' },
  { id: 'popout-covered', instruction: '把主会议窗口完全遮住，但让弹出的字幕窗口保持可见，继续说话。' },
  { id: 'captions-off', instruction: '关闭实时字幕，说几句话。' },
  { id: 'captions-on', instruction: '重新打开实时字幕，说几句话。' },
  { id: 'network', instruction: '断开网络约 15 秒再恢复（关掉再打开 Wi-Fi），期间说几句话。' },
  { id: 'fullscreen-away', instruction: '把会议窗口切到全屏（⌃⌘F 或绿色按钮），再切到别的桌面（⌃←，或调度中心里选桌面 1），让会议窗口不在屏幕上，继续说话。' },
  { id: 'fullscreen-teams', instruction: '会议窗口仍在它的全屏桌面上，在当前桌面点一下 Teams 主窗口（看聊天），继续说话。' },
  { id: 'hidden', instruction: '回到会议窗口并退出全屏，然后按 ⌘H 隐藏 Teams（所有 Teams 窗口都不显示），继续说话。' },
  { id: 'leave', instruction: '挂断，离开会议。' },
]

/**
 * Scripted English lines spoken with `say` during each step (`--speak`). Known text lets the report
 * check, sentence by sentence, whether captions were captured in each window state.
 */
export const PROBE_SCRIPT: Readonly<Record<string, readonly string[]>> = {
  foreground: ['The quarterly roadmap review starts with the mobile release.', 'Please confirm the budget numbers by Friday.', 'Our next milestone is the payment integration.'],
  background: ['Marketing will prepare the launch checklist.', 'The design team finished the onboarding screens.', 'We still need a decision on the pricing page.'],
  covered: ['Engineering estimates two weeks for the database migration.', 'Support tickets dropped by thirty percent this month.', 'Let us schedule a follow up meeting on Tuesday.'],
  'side-by-side': ['The chat window has focus but the meeting stays visible.', 'Inventory counts are due at the end of the month.'],
  'covered-full': ['A full screen window now covers the meeting.', 'The new printer arrives on Thursday morning.'],
  minimized: ['The vendor contract expires in December.', 'Security review is blocked on the audit report.', 'Remember to update the release notes tonight.'],
  popout: ['Captions should now appear in a separate window.', 'The analytics dashboard needs better filters.', 'Customer interviews continue next week.'],
  'popout-covered': ['This sentence tests the popped out captions window.', 'Hiring plans include two backend engineers.', 'The demo went well with the pilot customer.'],
  'captions-off': ['Captions are turned off for this part.', 'Nothing in this part should appear in the transcript.'],
  'captions-on': ['Captions are back on again.', 'The final agenda item is the holiday schedule.'],
  network: ['The network is disconnected during this sentence.', 'Reconnecting should bring the captions back.'],
  'fullscreen-away': ['The meeting window is now on another desktop.', 'Quarterly revenue grew faster than expected.', 'Please send the slides before lunch.'],
  'fullscreen-teams': ['Now the chat list is open on this desktop.', 'The office move is planned for next spring.', 'We need two more volunteers for the workshop.'],
  hidden: ['Microsoft Teams is hidden for this part.', 'The training budget was approved yesterday.', 'Our customers asked for a dark mode option.'],
  leave: [],
}

export function scriptWords(): string[] {
  const words = new Set<string>()
  for (const lines of Object.values(PROBE_SCRIPT)) for (const l of lines) for (const w of normalizeWords(l)) words.add(w)
  return [...words]
}

export function normalizeWords(text: string): string[] {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter((w) => w !== '')
}

function say(text: string, voice: string, rate: number): Promise<void> {
  return new Promise((resolve) => execFile('/usr/bin/say', ['-v', voice, '-r', String(rate), text], () => resolve()))
}

export interface ProbeIO {
  print(text: string): void
  ask(prompt: string): Promise<string>
  close(): void
}

export function terminalIO(): ProbeIO {
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  return {
    print: (t) => process.stdout.write(`${t}\n`),
    ask: (p) => new Promise((resolve) => rl.question(p, resolve)),
    close: () => rl.close(),
  }
}

/**
 * `--auto`: prompts are answered through files instead of stdin, so another process (a script, or an
 * agent operating Teams) can drive the probe. While waiting, `<dir>/waiting` holds the prompt; writing
 * `<dir>/next` answers it (its content is the answer, e.g. `s` to skip a step).
 */
export function signalFileIO(dir: string): ProbeIO {
  const waiting = join(dir, 'waiting')
  const next = join(dir, 'next')
  let closed = false
  return {
    print: (t) => process.stdout.write(`${t}\n`),
    ask: async (prompt) => {
      await writeFileAtomic(waiting, `${prompt}\n`)
      process.stdout.write(`${prompt} [等待 ${next}]\n`)
      while (!closed) {
        const answer = await readFile(next, 'utf8').catch(() => undefined)
        if (answer !== undefined) {
          await rm(next, { force: true })
          await rm(waiting, { force: true })
          return answer.trim()
        }
        await sleep(250)
      }
      return 's'
    },
    close: () => {
      closed = true
    },
  }
}

export interface ProbeOptions {
  readonly outDir: string
  readonly dwellSec: number
  readonly redaction: 'pseudo' | 'ui' | 'mask' | 'none'
  readonly intervalSec: number
  /** Speak the scripted lines with `say` during each step. */
  readonly speak?: { readonly voice: string; readonly rate: number }
  /** Run only these steps (ids of PROBE_STEPS, in their usual order). */
  readonly steps?: readonly string[]
}

/** Run the interactive probe. Returns the report path. */
export async function runTeamsProbe(client: HelperClient, options: ProbeOptions, io: ProbeIO): Promise<string> {
  const unknown = (options.steps ?? []).filter((id) => !PROBE_STEPS.some((s) => s.id === id))
  if (unknown.length > 0) throw new Error(`unknown probe steps: ${unknown.join(', ')} (known: ${PROBE_STEPS.map((s) => s.id).join(', ')})`)
  const steps = options.steps === undefined ? PROBE_STEPS : PROBE_STEPS.filter((s) => options.steps!.includes(s.id))
  await ensurePrivateDir(options.outDir)
  io.print('DSH Reflex · Teams 探针')
  io.print('准备：打开 Teams，进入一场会议（设置 → 设备 → “Make a test call”，或日历里的 Meet now），打开实时字幕（⋯ → 语言和语音 → 打开实时字幕）。')
  io.print('test call 里如果没有字幕选项，换 Meet now 自己说话即可。')
  if (options.speak) {
    io.print(`--speak：每一步会用 say（${options.speak.voice}）自动念 2–3 句英文台词。请用外放（不要戴耳机），把 Teams 的降噪调到“低”，字幕的口语语言设为 English。`)
  }
  await io.ask('进入会议并打开字幕后，按回车开始。')

  // 1. Wake the WebView tree and take a first look.
  io.print('唤醒 Teams 的 AX 树…')
  const woke = await client.request('ax.prepareWeb', { bundleId: TEAMS_BUNDLE })
  await writeJsonAtomic(join(options.outDir, 'prepare-web.json'), woke)
  await sleep(2500)
  const inspect = await client.request('ax.inspect', { bundleId: TEAMS_BUNDLE, redaction: 'ui', maxNodes: 6000 }, 60_000)
  await writeJsonAtomic(join(options.outDir, 'inspect-initial.json'), inspect)
  const initial = summarizeInspect(inspect)
  io.print(`初始检查：${initial.nodes} 个节点，DOM id ${initial.domIds} 个，挂断按钮 ${initial.anchors['hangup-button'] ? '有' : '无'}，计时器 ${initial.anchors['call-duration-custom'] ? '有' : '无'}，字幕条目 ${initial.captionEntries} 个`)
  if (initial.domIds === 0) io.print('⚠️ 没有看到 DOM id：WebView 可能还没唤醒。继续录制，报告里会标出来。')

  // 2. Record the whole guided session.
  const fixture = join(options.outDir, 'teams-probe.jsonl')
  const recordId = `probe-${Date.now()}`
  const recording = client.request('ax.record', {
    bundleId: TEAMS_BUNDLE, durationSec: 3600, out: fixture, recordId, intervalSec: options.intervalSec,
    redaction: options.redaction, keep: PROBE_KEEP, keyframeSec: 10, note: 'dsh-reflex probe teams', maxNodes: 8000,
    ...(options.speak ? { keepWords: scriptWords() } : {}),
  }, 0)
  await sleep(1500)
  for (const step of steps) {
    io.print(`\n[${step.id}] ${step.instruction}`)
    const answer = (await io.ask('做好后按回车（输入 s 跳过）：')).trim().toLowerCase()
    if (answer === 's') {
      await client.request('ax.record.mark', { recordId, label: `skip:${step.id}` })
      continue
    }
    await client.request('ax.record.mark', { recordId, label: `start:${step.id}` })
    const stepStart = Date.now()
    if (options.speak) {
      const lines = PROBE_SCRIPT[step.id] ?? []
      for (const [i, line] of lines.entries()) {
        await client.request('ax.record.mark', { recordId, label: `say:${step.id}:${i}:${line}` })
        process.stdout.write(`  🔊 ${line}\n`)
        await say(line, options.speak.voice, options.speak.rate)
        await sleep(1500)
      }
    }
    for (let left = Math.ceil(options.dwellSec - (Date.now() - stepStart) / 1000); left > 0; left -= 5) {
      process.stdout.write(`  录制中… ${left}s\r`)
      await sleep(Math.min(5, left) * 1000)
    }
    await client.request('ax.record.mark', { recordId, label: `end:${step.id}` })
    io.print('  完成。          ')
  }
  await client.request('ax.record.stop', { recordId })
  const recorded = await recording
  await writeJsonAtomic(join(options.outDir, 'record-summary.json'), recorded)

  // 3. Analyze.
  io.print('\n分析录制结果…')
  const report = await analyzeFixture(fixture)
  await writeJsonAtomic(join(options.outDir, 'probe-report.json'), report as unknown as JsonValue)
  const md = renderReport(report)
  const mdPath = join(options.outDir, 'probe-report.md')
  await writeFileAtomic(mdPath, md)
  io.print(md)
  return mdPath
}

interface InspectSummary {
  nodes: number
  domIds: number
  anchors: Record<string, boolean>
  captionEntries: number
}

function summarizeInspect(inspect: JsonValue): InspectSummary {
  const out: InspectSummary = { nodes: 0, domIds: 0, anchors: {}, captionEntries: 0 }
  const apps = (inspect as { apps?: JsonValue[] } | null)?.apps ?? []
  for (const app of apps) walk(app as unknown as AXNodeJson, (n) => {
    out.nodes += 1
    if (n.domId) out.domIds += 1
    if (n.domId && ANCHOR_IDS.includes(n.domId)) out.anchors[n.domId] = true
    if (n.domClasses?.includes(CAPTION_CLASS)) out.captionEntries += 1
  })
  return out
}

// MARK: - analysis

export interface AXNodeJson {
  role?: string
  subrole?: string
  title?: string
  desc?: string
  value?: string
  domId?: string
  domClasses?: string[]
  chromeId?: string
  pid?: number
  minimized?: boolean
  /** A window the app's AXWindows list left out (on a Space that is not on screen). */
  unlisted?: boolean
  omittedChildren?: number
  children?: AXNodeJson[]
}

export function walk(node: AXNodeJson, visit: (n: AXNodeJson, parent: AXNodeJson | undefined) => void, parent?: AXNodeJson): void {
  visit(node, parent)
  for (const c of node.children ?? []) walk(c, visit, node)
}

export function textsOf(node: AXNodeJson): string[] {
  const out: string[] = []
  walk(node, (n) => {
    if (n.role === 'AXStaticText') {
      const t = (n.value !== undefined && n.value !== '' ? n.value : n.title)?.trim()
      if (t) out.push(t)
    }
  })
  return out
}

export interface CaptionEntry {
  id: string
  speaker: string
  text: string
}

/** Caption entries in a tree (Teams 2 structure from meeting-capture; verified by this probe). */
export function captionEntries(root: AXNodeJson, entryClass = CAPTION_CLASS): CaptionEntry[] {
  const out: CaptionEntry[] = []
  walk(root, (n) => {
    if (!n.domClasses?.includes(entryClass)) return
    const texts = textsOf(n)
    if (texts.length < 2 || n.chromeId === undefined) return
    out.push({ id: n.chromeId, speaker: texts[0]!, text: texts.slice(1).join(' ') })
  })
  return out
}

/** Teams 26246 window states: minimized call window (AXDialog), compact view (AXSystemDialog with the
 * hangup button), popped-out captions (caption panel without the hangup button). A window the app's
 * AXWindows list left out (on a Space that is not on screen) is `unlisted:<call|minimized|compact|popout|other>`. */
export function windowStates(root: AXNodeJson): string[] {
  const out: string[] = []
  for (const w of root.children ?? []) {
    if (w.role !== 'AXWindow') continue
    let hangup = false
    let captions = false
    walk(w, (n) => {
      if (n.domId === 'hangup-button') hangup = true
      if (n.domClasses?.includes(CAPTION_CLASS) || /^captions-(panel|settings)/.test(n.domId ?? '')) captions = true
    })
    const kind = hangup ? (w.minimized ? 'minimized' : w.subrole === 'AXSystemDialog' ? 'compact' : 'call') : captions ? 'popout' : 'other'
    if (w.unlisted) out.push(`unlisted:${kind}`)
    else if (kind !== 'call' && kind !== 'other') out.push(kind)
  }
  return out
}

function clockOf(root: AXNodeJson): string | undefined {
  let found: string | undefined
  walk(root, (n) => {
    if (found === undefined && n.domId === 'call-duration-custom') found = textsOf(n).join(' ') || n.title
  })
  return found
}

export interface SegmentReport {
  label: string
  start: number
  end: number
  frames: number
  captionChanges: number
  clockChanges: number
  notices: number
  captionsVisible: boolean
  hangupPresent: boolean
  windows: string[]
  /** Window states seen in this step: call window minimized, Teams' compact view, popped-out captions,
   * windows off the AXWindows list (`unlisted:*`), Teams hidden. */
  states: string[]
  /** --speak: scripted lines spoken in this step and how many showed up in captions. */
  spoken: number
  captured: number
  avgLatencyMs: number | null
  verdict: string
}

export interface ProbeReport {
  fixture: string
  recordedAt?: string
  teamsVersion?: string
  durationSec: number
  frames: number
  keyframes: number
  notices: number
  pids: { app: number[]; contentOwners: number[]; noticeSenders: number[] }
  notifications: Record<string, number>
  noticesByPid: Record<string, Record<string, number>>
  captionNoticeNames: Record<string, number>
  selectors: {
    anchors: Record<string, number>
    captionEntryClass: { className: string; framesWithEntries: number; maxVisible: number }
    captionDomIds: string[]
    captionClasses: string[]
    windowSubroles: Record<string, number>
  }
  captions: {
    distinctIds: number
    revisionsPerIdAvg: number
    revisionsPerIdMax: number
    reRenderedIds: number
    medianChangeMs: number | null
    p90ChangeMs: number | null
    recommendedPollMs: number | null
  }
  segments: SegmentReport[]
  warnings: string[]
}

interface Line {
  kind: string
  t?: number
  pid?: number
  root?: AXNodeJson
  name?: string
  element?: AXNodeJson
  label?: string
  apps?: { pid: number; bundleId: string; isHidden?: boolean; isActive?: boolean }[]
  startedAt?: string
  appVersions?: Record<string, string>
}

export async function readFixture(file: string): Promise<Line[]> {
  const lines: Line[] = []
  const rl = createInterface({ input: createReadStream(file, 'utf8'), crlfDelay: Infinity })
  for await (const raw of rl) {
    if (raw.trim() === '') continue
    try {
      lines.push(JSON.parse(raw) as Line)
    } catch {
      // skip partial last line
    }
  }
  return lines
}

export async function analyzeFixture(file: string): Promise<ProbeReport> {
  const lines = await readFixture(file)
  const meta = lines.find((l) => l.kind === 'meta')
  const report: ProbeReport = {
    fixture: file,
    ...(meta?.startedAt ? { recordedAt: meta.startedAt } : {}),
    ...(meta?.appVersions?.[TEAMS_BUNDLE] ? { teamsVersion: meta.appVersions[TEAMS_BUNDLE] } : {}),
    durationSec: 0, frames: 0, keyframes: 0, notices: 0,
    pids: { app: [], contentOwners: [], noticeSenders: [] },
    notifications: {}, noticesByPid: {}, captionNoticeNames: {},
    selectors: {
      anchors: Object.fromEntries(ANCHOR_IDS.map((id) => [id, 0])),
      captionEntryClass: { className: CAPTION_CLASS, framesWithEntries: 0, maxVisible: 0 },
      captionDomIds: [], captionClasses: [], windowSubroles: {},
    },
    captions: { distinctIds: 0, revisionsPerIdAvg: 0, revisionsPerIdMax: 0, reRenderedIds: 0, medianChangeMs: null, p90ChangeMs: null, recommendedPollMs: null },
    segments: [],
    warnings: [],
  }
  const appPids = new Set<number>()
  const owners = new Set<number>()
  const senders = new Set<number>()
  const captionDomIds = new Set<string>()
  const captionClasses = new Set<string>()
  const revisions = new Map<string, string[]>()
  const textToIds = new Map<string, Set<string>>()
  const changeTimes: number[] = []
  let lastCaptionKey = ''
  let lastCaptionAt: number | undefined

  // Segment bookkeeping.
  const markers = lines.filter((l) => l.kind === 'marker' && typeof l.label === 'string')
  const segments = new Map<string, SegmentReport>()
  for (const m of markers) {
    const [edge, id] = (m.label ?? '').split(':')
    if (id === undefined) continue
    const seg = segments.get(id) ?? { label: id, start: 0, end: 0, frames: 0, captionChanges: 0, clockChanges: 0, notices: 0, captionsVisible: false, hangupPresent: false, windows: [], states: [], spoken: 0, captured: 0, avgLatencyMs: null, verdict: '' }
    if (edge === 'start') seg.start = m.t ?? 0
    if (edge === 'end') seg.end = m.t ?? 0
    if (edge === 'skip') seg.verdict = 'skipped'
    segments.set(id, seg)
  }
  const segmentAt = (t: number): SegmentReport | undefined => {
    for (const s of segments.values()) if (s.start <= t && t <= s.end && s.end > 0) return s
    return undefined
  }
  const lastClock = new Map<number, string>()
  const captionTexts: { t: number; text: string }[] = []
  const seenTexts = new Set<string>()
  const addState = (seg: SegmentReport | undefined, state: string): void => {
    if (seg !== undefined && !seg.states.includes(state)) seg.states.push(state)
  }
  // Teams hidden with ⌘H (every window is off screen).
  let hidden = false

  for (const line of lines) {
    const t = line.t ?? 0
    report.durationSec = Math.max(report.durationSec, t)
    if (line.kind === 'apps') {
      for (const a of line.apps ?? []) appPids.add(a.pid)
      hidden = (line.apps ?? []).some((a) => a.bundleId === TEAMS_BUNDLE && a.isHidden === true)
      if (hidden) addState(segmentAt(t), 'hidden')
    }
    if (line.kind === 'notice') {
      report.notices += 1
      const name = line.name ?? '?'
      report.notifications[name] = (report.notifications[name] ?? 0) + 1
      const pid = String(line.pid ?? 0)
      report.noticesByPid[pid] ??= {}
      report.noticesByPid[pid][name] = (report.noticesByPid[pid][name] ?? 0) + 1
      if (line.pid !== undefined) senders.add(line.pid)
      const el = line.element
      const related = el !== undefined && (el.domClasses?.some((c) => /caption|ChatMessageCompact/i.test(c)) || /caption/i.test(el.domId ?? ''))
      if (related) report.captionNoticeNames[name] = (report.captionNoticeNames[name] ?? 0) + 1
      const seg = segmentAt(t)
      if (seg) seg.notices += 1
      continue
    }
    if (line.kind !== 'tree' || line.root === undefined) continue
    report.frames += 1
    const root = line.root
    let keyframe = true
    walk(root, (n) => {
      if (n.pid !== undefined) owners.add(n.pid)
      if (n.domId && ANCHOR_IDS.includes(n.domId)) report.selectors.anchors[n.domId] = (report.selectors.anchors[n.domId] ?? 0) + 1
      if (n.domId && /caption/i.test(n.domId)) captionDomIds.add(n.domId)
      for (const c of n.domClasses ?? []) if (/caption/i.test(c)) captionClasses.add(c)
      if (n.role === 'AXWindow') report.selectors.windowSubroles[n.subrole ?? '?'] = (report.selectors.windowSubroles[n.subrole ?? '?'] ?? 0) + 1
      if (n.role === 'AXWindow' && n.omittedChildren !== undefined && (n.children ?? []).length === 0) keyframe = false
    })
    if (keyframe) report.keyframes += 1
    const entries = captionEntries(root)
    if (entries.length > 0) {
      report.selectors.captionEntryClass.framesWithEntries += 1
      report.selectors.captionEntryClass.maxVisible = Math.max(report.selectors.captionEntryClass.maxVisible, entries.length)
    }
    const key = entries.map((e) => `${e.id}:${e.text}`).join('|')
    const seg = segmentAt(t)
    if (seg) {
      seg.frames += 1
      if (entries.length > 0) seg.captionsVisible = true
      let hangup = false
      walk(root, (n) => {
        if (n.domId === 'hangup-button') hangup = true
        if (n.role === 'AXWindow' && n.title && !seg.windows.includes(n.title)) seg.windows.push(n.title)
      })
      if (hangup) seg.hangupPresent = true
      for (const state of windowStates(root)) addState(seg, state)
      if (hidden) addState(seg, 'hidden')
    }
    if (key !== lastCaptionKey) {
      if (lastCaptionAt !== undefined && entries.length > 0) changeTimes.push((t - lastCaptionAt) * 1000)
      lastCaptionKey = key
      lastCaptionAt = t
      if (seg && entries.length > 0) seg.captionChanges += 1
    }
    for (const e of entries) {
      if (!seenTexts.has(e.text)) {
        seenTexts.add(e.text)
        captionTexts.push({ t, text: e.text })
      }
      const list = revisions.get(e.id) ?? []
      if (list[list.length - 1] !== e.text) list.push(e.text)
      revisions.set(e.id, list)
      const textKey = `${e.speaker}\u0000${e.text}`
      const ids = textToIds.get(textKey) ?? new Set<string>()
      ids.add(e.id)
      textToIds.set(textKey, ids)
    }
    const clock = clockOf(root)
    if (clock !== undefined && line.pid !== undefined) {
      if (lastClock.get(line.pid) !== clock && seg) seg.clockChanges += 1
      lastClock.set(line.pid, clock)
    }
  }

  // --speak: did each scripted line show up in the captions (≥60% of its words in one row)?
  const spokenLines = markers
    .map((m) => /^say:([^:]+):(\d+):(.*)$/.exec(m.label ?? ''))
    .map((m, i) => (m === null ? undefined : { step: m[1]!, text: m[3]!, t: markers[i]!.t ?? 0 }))
    .filter((x): x is { step: string; text: string; t: number } => x !== undefined)
  for (const line of spokenLines) {
    const want = new Set(normalizeWords(line.text))
    const hit = captionTexts.find((c) => {
      if (c.t < line.t) return false
      const got = new Set(normalizeWords(c.text))
      let n = 0
      for (const w of want) if (got.has(w)) n += 1
      return want.size > 0 && n / want.size >= 0.6
    })
    const seg = segments.get(line.step)
    if (seg === undefined) continue
    seg.spoken += 1
    if (hit !== undefined) {
      seg.captured += 1
      const lat = (hit.t - line.t) * 1000
      seg.avgLatencyMs = seg.avgLatencyMs === null ? lat : (seg.avgLatencyMs * (seg.captured - 1) + lat) / seg.captured
    }
  }
  report.pids = { app: [...appPids].sort(), contentOwners: [...owners].sort(), noticeSenders: [...senders].sort() }
  report.selectors.captionDomIds = [...captionDomIds].sort()
  report.selectors.captionClasses = [...captionClasses].sort()
  const revCounts = [...revisions.values()].map((r) => r.length)
  report.captions.distinctIds = revisions.size
  report.captions.revisionsPerIdAvg = revCounts.length ? Math.round((revCounts.reduce((a, b) => a + b, 0) / revCounts.length) * 10) / 10 : 0
  report.captions.revisionsPerIdMax = revCounts.length ? Math.max(...revCounts) : 0
  report.captions.reRenderedIds = [...textToIds.values()].filter((ids) => ids.size > 1).length
  if (changeTimes.length > 0) {
    const sorted = [...changeTimes].sort((a, b) => a - b)
    const pick = (q: number): number => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!)
    report.captions.medianChangeMs = pick(0.5)
    report.captions.p90ChangeMs = pick(0.9)
    // Poll at most every second; faster when lines change faster than that.
    report.captions.recommendedPollMs = Math.max(250, Math.min(1000, Math.round(pick(0.25) / 2 / 50) * 50))
  }
  for (const seg of segments.values()) {
    if (seg.verdict !== 'skipped') {
      seg.verdict = seg.frames === 0 ? 'no frames (tree unchanged or unreadable)'
        : seg.captionChanges > 0 ? 'captions updating'
          : seg.captionsVisible ? 'captions visible but frozen'
            : seg.clockChanges > 0 ? 'meeting UI updating, no captions'
              : 'no updates seen'
    }
    report.segments.push(seg)
  }
  report.segments.sort((a, b) => a.start - b.start)
  if (report.selectors.captionEntryClass.framesWithEntries === 0) {
    report.warnings.push(`no caption entries with class ${CAPTION_CLASS} were seen: captions off, not readable through AX, or the structure changed (decision gate)`)
  }
  if ((report.selectors.anchors['hangup-button'] ?? 0) === 0 && (report.selectors.anchors['call-duration-custom'] ?? 0) === 0) {
    report.warnings.push('no meeting anchors (hangup-button / call-duration-custom) were seen')
  }
  if (Object.keys(report.notifications).length === 0) report.warnings.push('no AX notifications were received; change detection must rely on polling')
  return report
}

export function renderReport(r: ProbeReport): string {
  const lines: string[] = []
  lines.push('# Teams 探针报告', '')
  lines.push(`- 录制文件：\`${r.fixture}\``)
  if (r.recordedAt) lines.push(`- 录制时间：${r.recordedAt}`)
  if (r.teamsVersion) lines.push(`- Teams 版本：${r.teamsVersion}`)
  lines.push(`- 时长 ${Math.round(r.durationSec)}s，快照 ${r.frames} 帧（完整关键帧 ${r.keyframes}），通知 ${r.notices} 条`, '')
  if (r.warnings.length > 0) {
    lines.push('## ⚠️ 警告', '')
    for (const w of r.warnings) lines.push(`- ${w}`)
    lines.push('')
  }
  lines.push('## 选择器', '')
  lines.push(`- 会议锚点：${Object.entries(r.selectors.anchors).map(([k, v]) => `\`#${k}\` ${v} 帧`).join('，')}`)
  lines.push(`- 字幕条目 \`.${r.selectors.captionEntryClass.className}\`：${r.selectors.captionEntryClass.framesWithEntries} 帧出现，最多同时 ${r.selectors.captionEntryClass.maxVisible} 条`)
  lines.push(`- 含 caption 的 DOM id：${r.selectors.captionDomIds.map((x) => `\`${x}\``).join(', ') || '无'}`)
  lines.push(`- 含 caption 的 class：${r.selectors.captionClasses.map((x) => `\`${x}\``).join(', ') || '无'}`)
  lines.push(`- 窗口 subrole：${Object.entries(r.selectors.windowSubroles).map(([k, v]) => `${k}×${v}`).join('，')}`, '')
  lines.push('## 进程与通知', '')
  lines.push(`- Teams 进程：${r.pids.app.join(', ') || '?'}；树里出现的所有者 pid：${r.pids.contentOwners.join(', ') || '无'}；发通知的 pid：${r.pids.noticeSenders.join(', ') || '无'}`)
  lines.push(`- 通知类型：${Object.entries(r.notifications).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join('，') || '无'}`)
  lines.push(`- 字幕相关元素发出的通知：${Object.entries(r.captionNoticeNames).map(([k, v]) => `${k} ${v}`).join('，') || '无'}`, '')
  lines.push('## 字幕行为', '')
  lines.push(`- 条目 id ${r.captions.distinctIds} 个；每个 id 的文本修订 平均 ${r.captions.revisionsPerIdAvg} 次，最多 ${r.captions.revisionsPerIdMax} 次`)
  lines.push(`- 同一发言人同一文本换了新 id（重新渲染）：${r.captions.reRenderedIds} 处`)
  lines.push(`- 快照中字幕变化间隔：中位数 ${r.captions.medianChangeMs ?? '—'}ms，P90 ${r.captions.p90ChangeMs ?? '—'}ms → 建议补偿轮询 ${r.captions.recommendedPollMs ?? '—'}ms`, '')
  lines.push('## 各窗口状态', '')
  const spoken = r.segments.some((s) => s.spoken > 0)
  lines.push(`| 步骤 | 帧数 | 字幕变化 | 计时器变化 | 通知 | 挂断按钮 | 窗口状态 |${spoken ? ' 台词采到 | 平均延迟 |' : ''} 结论 |`, `|---|---|---|---|---|---|---|${spoken ? '---|---|' : ''}---|`)
  for (const s of r.segments) {
    const said = spoken ? ` ${s.spoken ? `${s.captured}/${s.spoken}` : '—'} | ${s.avgLatencyMs === null ? '—' : `${Math.round(s.avgLatencyMs)}ms`} |` : ''
    lines.push(`| ${s.label} | ${s.frames} | ${s.captionChanges} | ${s.clockChanges} | ${s.notices} | ${s.hangupPresent ? '有' : '无'} | ${s.states.join(', ') || '—'} |${said} ${s.verdict} |`)
  }
  lines.push('')
  return lines.join('\n')
}

// MARK: - fixture trimming

/** DOM ids kept with their subtree when a recording becomes a test fixture. */
const FIXTURE_IDS = new Set([
  ...ANCHOR_IDS, 'captions-panel-dismiss-button', 'closed-captions-overflow-menu-button', 'closed-captions-pop-out-button',
  'captions-settings-menu-trigger-button-non-overflow', 'captions-settings-menu-trigger-button-overflow',
])
const WINDOW_NOTICES = new Set(['AXWindowCreated', 'AXWindowMiniaturized', 'AXWindowDeminiaturized', 'AXFocusedWindowChanged', 'AXMainWindowChanged'])

export interface TrimOptions {
  /**
   * Time ranges to keep, in seconds from the start of the recording; everything when empty. The cut-out
   * time between ranges is removed (each range follows the previous one after a second), so replay does
   * not see the call timer standing still across a cut.
   */
  readonly ranges: readonly (readonly [number, number])[]
  /** Keep only caption rows that are scripted probe lines: what else was said in the room is dropped. */
  readonly scriptOnly: boolean
  /** Frames that differ only in the call timer are kept at most this often (seconds). */
  readonly clockEverySec: number
}

export interface TrimSummary {
  linesIn: number
  linesOut: number
  frames: number
  droppedRows: number
  bytes: number
}

/** Whether a caption text is (a prefix of) one of the scripted probe lines: ≥60% of its words in one line. */
export function isScriptedText(text: string): boolean {
  const words = normalizeWords(text)
  if (words.length === 0) return false
  for (const lines of Object.values(PROBE_SCRIPT)) {
    for (const line of lines) {
      const want = new Set(normalizeWords(line))
      if (words.filter((w) => want.has(w)).length / words.length >= 0.6) return true
    }
  }
  return false
}

/**
 * Keep what the teams program reads: windows (title, subrole, minimized), meeting anchors and the
 * timer, caption panel controls and caption rows, plus the path to them (with Chromium ids, so
 * replayed handles resolve). Everything else, including texts on the path, is dropped.
 */
export function pruneForFixture(node: AXNodeJson, keepRow: (text: string) => boolean, dropped: { rows: number }): AXNodeJson | undefined {
  if (node.domId !== undefined && FIXTURE_IDS.has(node.domId)) return withoutHashedClasses(node)
  if (node.domClasses?.includes(CAPTION_CLASS)) {
    const texts = textsOf(node)
    if (texts.length >= 2 && !keepRow(texts.slice(1).join(' '))) {
      dropped.rows += 1
      return undefined
    }
    return withoutHashedClasses(node)
  }
  const children = (node.children ?? []).map((c) => pruneForFixture(c, keepRow, dropped)).filter((c): c is AXNodeJson => c !== undefined)
  if (node.role === 'AXApplication' || node.role === 'AXWindow') {
    const out: AXNodeJson = { ...node, children }
    delete out.omittedChildren
    delete out.domClasses
    return out
  }
  if (children.length === 0) return undefined
  // Collapse single-child links of the path, except the caption list itself (the rows' parent).
  const holdsRows = children.some((c) => c.domClasses?.includes(CAPTION_CLASS))
  if (children.length === 1 && !holdsRows) return children[0]
  return {
    ...(node.role !== undefined ? { role: node.role } : {}), ...(node.domId !== undefined ? { domId: node.domId } : {}),
    ...(node.chromeId !== undefined ? { chromeId: node.chromeId } : {}), children,
  }
}

/** Fluent UI's generated atomic classes ("___1v52uhs", "f22iagw") carry no meaning for the program. */
function withoutHashedClasses(node: AXNodeJson): AXNodeJson {
  const classes = node.domClasses?.filter((c) => !/^_{2,3}[a-z0-9]+$|^f[a-z0-9]{5,8}$/i.test(c))
  const out: AXNodeJson = { ...node, ...(node.children ? { children: node.children.map(withoutHashedClasses) } : {}) }
  if (classes === undefined || classes.length === 0) delete out.domClasses
  else out.domClasses = classes
  return out
}

/** Windows with nothing kept (Teams' main window) only keep their first title segment ("Chat"): the rest names the open chat. */
function scrubTitles(root: AXNodeJson): void {
  for (const w of root.children ?? []) {
    if (w.role !== 'AXWindow' || (w.children ?? []).length > 0 || w.title === undefined) continue
    const first = w.title.split(' | ')[0] ?? ''
    w.title = first === 'Microsoft Teams' || first === '' ? 'Microsoft Teams' : `${first} | Microsoft Teams`
  }
}

function withoutClock(node: AXNodeJson): AXNodeJson {
  if (node.domId === 'call-duration-custom') return { domId: node.domId }
  return { ...node, ...(node.children ? { children: node.children.map(withoutClock) } : {}) }
}

/** Turn a probe recording into a small fixture for replay tests (`programs/teams/Fixtures`). */
export async function trimFixture(input: string, output: string, options: TrimOptions): Promise<TrimSummary> {
  const lines = await readFixture(input)
  const ranges = [...options.ranges].sort((a, b) => a[0] - b[0])
  const inRange = (t: number): boolean => ranges.length === 0 || ranges.some(([a, b]) => a <= t && t <= b)
  // Shift of each range: the time cut out before it, minus a one-second seam.
  const shifts: number[] = []
  for (const [i, [a]] of ranges.entries()) shifts.push(i === 0 ? 0 : shifts[i - 1]! + (a - ranges[i - 1]![1]) - 1)
  const shifted = (t: number): number => {
    const i = ranges.findIndex(([a, b]) => a <= t && t <= b)
    return i < 0 ? t : Math.round((t - shifts[i]!) * 1000) / 1000
  }
  const keepRow = options.scriptOnly ? isScriptedText : () => true
  const dropped = { rows: 0 }
  const last = new Map<number, { full: string; noClock: string; at: number }>()
  const out: string[] = []
  let frames = 0
  let end = 0
  for (const line of lines) {
    const t = line.t ?? 0
    if (line.kind === 'meta') {
      out.push(JSON.stringify({ ...line, note: `${(line as { note?: string }).note ?? ''} · trimmed`.trim(), trimmed: options }))
      continue
    }
    if (line.kind === 'apps') {
      out.push(JSON.stringify(line))
      continue
    }
    if (!inRange(t)) continue
    const t2 = shifted(t)
    end = Math.max(end, t2)
    if (line.kind === 'marker') {
      out.push(JSON.stringify({ ...line, t: t2 }))
    } else if (line.kind === 'notice') {
      if (!WINDOW_NOTICES.has(line.name ?? '')) continue
      const el = line.element
      out.push(JSON.stringify({ ...line, t: t2, element: el ? { role: el.role, subrole: el.subrole } : undefined }))
    } else if (line.kind === 'tree' && line.root !== undefined) {
      const root = pruneForFixture(line.root, keepRow, dropped)
      if (root === undefined) continue
      scrubTitles(root)
      const pid = line.pid ?? 0
      const full = JSON.stringify(root)
      const noClock = JSON.stringify(withoutClock(root))
      const prev = last.get(pid)
      if (prev !== undefined && (prev.full === full || (prev.noClock === noClock && t - prev.at < options.clockEverySec))) continue
      last.set(pid, { full, noClock, at: t })
      out.push(JSON.stringify({ ...line, t: t2, root }))
      frames += 1
    }
  }
  out.push(JSON.stringify({ kind: 'marker', t: end, label: 'end' }))
  const text = `${out.join('\n')}\n`
  await writeFileAtomic(output, text, 0o644)
  return { linesIn: lines.length, linesOut: out.length, frames, droppedRows: dropped.rows, bytes: Buffer.byteLength(text) }
}
