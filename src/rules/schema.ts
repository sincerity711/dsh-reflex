/** rules.yaml: types and validation. Rules come only from the user's file; event data can only fill data positions. */

import { isRecord, parseDuration, type JsonObject, type JsonValue } from '../util/misc.js'
import { templateProblems } from './template.js'

export type OnBusy = 'drop' | 'queue'
export type DshOnBusy = 'queue' | 'skip' | 'new-session'
export type DshTarget = 'new' | 'per-correlation' | { readonly session: string }

export interface Condition {
  readonly path: string
  readonly equals?: JsonValue
  readonly contains?: string
  readonly prefix?: string
  readonly regex?: string
  readonly exists?: boolean
}

export interface StepBase {
  readonly id: string
  readonly timeoutMs?: number
  /** status -> step id | 'end' | 'fail' */
  readonly next?: Readonly<Record<string, string>>
}

export interface TaskStep extends StepBase {
  readonly kind: 'task'
  readonly program: string
  readonly task: string
  readonly input: JsonValue
  readonly stopOn: readonly string[]
  readonly resumable: boolean
}

export interface RunStep extends StepBase {
  readonly kind: 'run'
  readonly builtin?: string
  readonly argv?: readonly string[]
  readonly cwd?: string
  readonly env?: Readonly<Record<string, string>>
  readonly input: JsonValue
}

export interface DshStep extends StepBase {
  readonly kind: 'dsh'
  readonly target: DshTarget
  readonly onBusy: DshOnBusy
  readonly agentPreset?: string
  readonly permissionPreset?: string
  readonly title?: string
  readonly promptFile?: string
  readonly prompt?: string
  readonly files: readonly string[]
  readonly saveReplyTo?: string
  readonly workspace?: string
  /** Put file contents into the prompt (for presets without file tools). */
  readonly inlineFiles?: boolean
  readonly maxInlineBytes?: number
}

export type Step = TaskStep | RunStep | DshStep

export interface Rule {
  readonly id: string
  readonly enabled: boolean
  readonly on: readonly string[]
  readonly when: readonly Condition[]
  readonly dedupe: { readonly key: string; readonly windowMs: number }
  /** max: runs per concurrency key; maxRuns: runs of this rule across all keys. */
  readonly concurrency?: { readonly key: string; readonly onBusy: OnBusy; readonly max: number; readonly maxRuns?: number; readonly queueMax: number; readonly queueTtlMs: number }
  readonly steps: readonly Step[]
}

export interface RulesDocument {
  readonly version: 1
  readonly rules: readonly Rule[]
  readonly maxConcurrentRuns: number
}

export class RulesError extends Error {
  constructor(readonly errors: readonly string[]) {
    super(`invalid rules:\n${errors.map((e) => `  - ${e}`).join('\n')}`)
    this.name = 'RulesError'
  }
}

const EVENT_PATTERN = /^[a-z][a-z0-9_-]*(\.[a-z0-9_-]+)*(\.\*)?$|^\*$/
const ID_PATTERN = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/
const RESERVED_NEXT = new Set(['end', 'fail'])

/** Validate a parsed YAML document. Throws RulesError with every problem found. */
export function validateRules(doc: unknown): RulesDocument {
  const errors: string[] = []
  const err = (path: string, message: string): void => {
    errors.push(`${path}: ${message}`)
  }
  if (!isRecord(doc)) throw new RulesError(['document must be a mapping with `version: 1` and `rules: [...]`'])
  if (doc['version'] !== 1) err('version', 'must be 1')
  const defaults = isRecord(doc['defaults']) ? doc['defaults'] : {}
  const defaultWindow = durationOr(defaults['dedupeWindow'], 600_000, 'defaults.dedupeWindow', err)
  const maxConcurrentRuns = typeof defaults['maxConcurrentRuns'] === 'number' && defaults['maxConcurrentRuns'] > 0 ? defaults['maxConcurrentRuns'] : 8
  const rawRules = doc['rules']
  if (!Array.isArray(rawRules)) {
    err('rules', 'must be a list')
    throw new RulesError(errors)
  }
  const rules: Rule[] = []
  const seen = new Set<string>()
  rawRules.forEach((raw, i) => {
    const p = `rules[${i}]`
    if (!isRecord(raw)) {
      err(p, 'must be a mapping')
      return
    }
    const id = raw['id']
    if (typeof id !== 'string' || !ID_PATTERN.test(id)) err(`${p}.id`, 'must be a name like "teams-meeting-summary"')
    else if (seen.has(id)) err(`${p}.id`, `duplicate rule id ${id}`)
    else seen.add(id)
    const rp = typeof id === 'string' ? `rules[${id}]` : p
    const on = toStringList(raw['on'])
    if (on.length === 0) err(`${rp}.on`, 'must name at least one event type')
    for (const e of on) if (!EVENT_PATTERN.test(e)) err(`${rp}.on`, `invalid event type pattern ${e}`)
    noTemplate(raw['on'], `${rp}.on`, err)
    const when = parseWhen(raw['when'], `${rp}.when`, err)
    const dedupeRaw = isRecord(raw['dedupe']) ? raw['dedupe'] : {}
    checkTemplates(dedupeRaw['key'], `${rp}.dedupe.key`, err)
    const dedupe = {
      key: typeof dedupeRaw['key'] === 'string' ? dedupeRaw['key'] : '${event.dedupeKey}',
      windowMs: durationOr(dedupeRaw['window'], defaultWindow, `${rp}.dedupe.window`, err),
    }
    let concurrency: Rule['concurrency']
    if (raw['concurrency'] !== undefined) {
      const c = raw['concurrency']
      if (!isRecord(c)) err(`${rp}.concurrency`, 'must be a mapping')
      else {
        checkTemplates(c['key'], `${rp}.concurrency.key`, err)
        const onBusy = c['onBusy'] ?? 'drop'
        if (onBusy !== 'drop' && onBusy !== 'queue') err(`${rp}.concurrency.onBusy`, 'must be drop or queue')
        const max = c['max'] ?? 1
        if (typeof max !== 'number' || !Number.isInteger(max) || max < 1) err(`${rp}.concurrency.max`, 'must be a positive integer')
        const maxRuns = c['maxRuns']
        if (maxRuns !== undefined && (typeof maxRuns !== 'number' || !Number.isInteger(maxRuns) || maxRuns < 1)) err(`${rp}.concurrency.maxRuns`, 'must be a positive integer')
        concurrency = {
          key: typeof c['key'] === 'string' ? c['key'] : '${event.correlationId}',
          onBusy: onBusy === 'queue' ? 'queue' : 'drop',
          max: typeof max === 'number' && max >= 1 ? Math.floor(max) : 1,
          ...(typeof maxRuns === 'number' && maxRuns >= 1 ? { maxRuns: Math.floor(maxRuns) } : {}),
          queueMax: typeof c['queueMax'] === 'number' && c['queueMax'] > 0 ? Math.floor(c['queueMax']) : 10,
          queueTtlMs: durationOr(c['queueTtl'], 3_600_000, `${rp}.concurrency.queueTtl`, err),
        }
      }
    }
    const steps = parseSteps(raw['steps'], rp, err)
    if (typeof id === 'string') {
      rules.push({ id, enabled: raw['enabled'] !== false, on, when, dedupe, ...(concurrency ? { concurrency } : {}), steps })
    }
  })
  if (errors.length > 0) throw new RulesError(errors)
  return { version: 1, rules, maxConcurrentRuns }
}

function parseWhen(raw: unknown, path: string, err: (p: string, m: string) => void): Condition[] {
  if (raw === undefined) return []
  if (!isRecord(raw)) {
    err(path, 'must map event paths (e.g. payload.title) to conditions')
    return []
  }
  const out: Condition[] = []
  for (const [key, value] of Object.entries(raw)) {
    if (!/^(eventType|resourceId|correlationId|identity|origin|app\.[a-zA-Z]+|payload(\.[A-Za-z0-9_-]+)+)$/.test(key)) {
      err(`${path}.${key}`, 'condition paths are eventType, resourceId, correlationId, identity, origin, app.*, payload.*')
      continue
    }
    if (!isRecord(value)) {
      out.push({ path: key, equals: value as JsonValue })
      continue
    }
    const c: { -readonly [K in keyof Condition]: Condition[K] } = { path: key }
    for (const [op, v] of Object.entries(value)) {
      if (op === 'equals') c.equals = v as JsonValue
      else if (op === 'contains' && typeof v === 'string') c.contains = v
      else if (op === 'prefix' && typeof v === 'string') c.prefix = v
      else if (op === 'regex' && typeof v === 'string') {
        try {
          new RegExp(v)
          c.regex = v
        } catch {
          err(`${path}.${key}.regex`, 'invalid regular expression')
        }
      } else if (op === 'exists' && typeof v === 'boolean') c.exists = v
      else err(`${path}.${key}.${op}`, 'unknown condition (equals, contains, prefix, regex, exists)')
    }
    out.push(c)
  }
  return out
}

function parseSteps(raw: unknown, rp: string, err: (p: string, m: string) => void): Step[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    err(`${rp}.steps`, 'must be a non-empty list')
    return []
  }
  const steps: Step[] = []
  const ids = new Set<string>()
  raw.forEach((s, i) => {
    const p = `${rp}.steps[${i}]`
    if (!isRecord(s)) {
      err(p, 'must be a mapping')
      return
    }
    const id = typeof s['id'] === 'string' ? s['id'] : `step${i + 1}`
    if (!ID_PATTERN.test(id) || RESERVED_NEXT.has(id)) err(`${p}.id`, `invalid step id ${id}`)
    if (ids.has(id)) err(`${p}.id`, `duplicate step id ${id}`)
    ids.add(id)
    const sp = `${rp}.steps[${id}]`
    const kinds = ['task', 'run', 'dsh'].filter((k) => s[k] !== undefined)
    if (kinds.length !== 1) {
      err(sp, 'must have exactly one of task, run, dsh')
      return
    }
    const timeoutMs = s['timeout'] === undefined ? undefined : durationOr(s['timeout'], 0, `${sp}.timeout`, err)
    let next: Record<string, string> | undefined
    if (s['next'] !== undefined) {
      if (!isRecord(s['next'])) err(`${sp}.next`, 'must map statuses to step ids, end, or fail')
      else {
        next = {}
        for (const [status, target] of Object.entries(s['next'])) {
          if (typeof target !== 'string') err(`${sp}.next.${status}`, 'must be a step id, end, or fail')
          else next[status] = target
        }
      }
    }
    const base = { id, ...(timeoutMs === undefined ? {} : { timeoutMs }), ...(next === undefined ? {} : { next }) }
    checkTemplates(s['input'], `${sp}.input`, err)
    if (kinds[0] === 'task') {
      const ref = s['task']
      noTemplate(ref, `${sp}.task`, err)
      const m = typeof ref === 'string' ? /^([a-z][a-z0-9-]{0,39})\/([A-Za-z][A-Za-z0-9_-]*)$/.exec(ref) : null
      if (m === null) {
        err(`${sp}.task`, 'must be "<program>/<task>" (e.g. teams/captureCaptions)')
        return
      }
      noTemplate(s['stopOn'], `${sp}.stopOn`, err)
      const stopOn = toStringList(s['stopOn'])
      for (const e of stopOn) if (!EVENT_PATTERN.test(e) || e.includes('*')) err(`${sp}.stopOn`, `invalid event type ${e}`)
      steps.push({ ...base, kind: 'task', program: m[1]!, task: m[2]!, input: (s['input'] ?? {}) as JsonValue, stopOn, resumable: s['resumable'] === true })
    } else if (kinds[0] === 'run') {
      const r = s['run']
      noTemplate(r, `${sp}.run`, err)
      if (!isRecord(r)) {
        err(`${sp}.run`, 'must be { builtin: name } or { argv: [program, args...] }')
        return
      }
      const builtin = typeof r['builtin'] === 'string' ? r['builtin'] : undefined
      const argv = Array.isArray(r['argv']) ? r['argv'].filter((a): a is string => typeof a === 'string') : undefined
      if ((builtin === undefined) === (argv === undefined)) {
        err(`${sp}.run`, 'needs exactly one of builtin or argv')
        return
      }
      if (argv !== undefined && (argv.length === 0 || !argv[0]!.startsWith('/'))) err(`${sp}.run.argv`, 'argv[0] must be an absolute path (no shell is used)')
      const env = isRecord(r['env']) ? Object.fromEntries(Object.entries(r['env']).map(([k, v]) => [k, String(v)])) : undefined
      steps.push({
        ...base, kind: 'run', input: (s['input'] ?? {}) as JsonValue,
        ...(builtin === undefined ? {} : { builtin }),
        ...(argv === undefined ? {} : { argv }),
        ...(typeof r['cwd'] === 'string' ? { cwd: r['cwd'] } : {}),
        ...(env === undefined ? {} : { env }),
      })
    } else {
      const d = s['dsh']
      if (!isRecord(d)) {
        err(`${sp}.dsh`, 'must be a mapping')
        return
      }
      for (const k of ['target', 'onBusy', 'agentPreset', 'permissionPreset', 'promptFile', 'prompt', 'workspace']) noTemplate(d[k], `${sp}.dsh.${k}`, err)
      let target: DshTarget = 'new'
      const t = d['target'] ?? 'new'
      if (t === 'new' || t === 'per-correlation') target = t
      else if (isRecord(t) && typeof t['session'] === 'string' && t['session'] !== '') target = { session: t['session'] }
      else err(`${sp}.dsh.target`, 'must be new, per-correlation, or { session: <id> }')
      const onBusy = d['onBusy'] ?? 'queue'
      if (onBusy !== 'queue' && onBusy !== 'skip' && onBusy !== 'new-session') err(`${sp}.dsh.onBusy`, 'must be queue, skip, or new-session')
      checkTemplates(d['title'], `${sp}.dsh.title`, err)
      checkTemplates(d['files'], `${sp}.dsh.files`, err)
      checkTemplates(d['saveReplyTo'], `${sp}.dsh.saveReplyTo`, err)
      const promptFile = typeof d['promptFile'] === 'string' ? d['promptFile'] : undefined
      const prompt = typeof d['prompt'] === 'string' ? d['prompt'] : undefined
      if (promptFile === undefined && prompt === undefined) err(`${sp}.dsh`, 'needs promptFile or prompt')
      const files = d['files'] === undefined ? [] : Array.isArray(d['files']) ? d['files'].filter((f): f is string => typeof f === 'string') : []
      if (d['files'] !== undefined && !Array.isArray(d['files'])) err(`${sp}.dsh.files`, 'must be a list of paths')
      steps.push({
        ...base, kind: 'dsh', target, onBusy: onBusy as DshOnBusy, files,
        ...(typeof d['agentPreset'] === 'string' ? { agentPreset: d['agentPreset'] } : {}),
        ...(typeof d['permissionPreset'] === 'string' ? { permissionPreset: d['permissionPreset'] } : {}),
        ...(typeof d['title'] === 'string' ? { title: d['title'] } : {}),
        ...(promptFile === undefined ? {} : { promptFile }),
        ...(prompt === undefined ? {} : { prompt }),
        ...(typeof d['saveReplyTo'] === 'string' ? { saveReplyTo: d['saveReplyTo'] } : {}),
        ...(typeof d['workspace'] === 'string' ? { workspace: d['workspace'] } : {}),
        ...(d['inlineFiles'] === true ? { inlineFiles: true } : {}),
        ...(typeof d['maxInlineBytes'] === 'number' && d['maxInlineBytes'] > 0 ? { maxInlineBytes: Math.floor(d['maxInlineBytes']) } : {}),
      })
    }
  })
  for (const step of steps) {
    for (const [status, target] of Object.entries(step.next ?? {})) {
      if (!RESERVED_NEXT.has(target) && !ids.has(target)) err(`${rp}.steps[${step.id}].next.${status}`, `unknown step ${target}`)
    }
  }
  return steps
}

function toStringList(v: unknown): string[] {
  if (typeof v === 'string') return [v]
  if (Array.isArray(v)) return v.filter((x): x is string => typeof x === 'string')
  return []
}

function durationOr(v: unknown, fallback: number, path: string, err: (p: string, m: string) => void): number {
  if (v === undefined) return fallback
  try {
    return parseDuration(v as string | number)
  } catch (e) {
    err(path, (e as Error).message)
    return fallback
  }
}

function checkTemplates(v: unknown, path: string, err: (p: string, m: string) => void): void {
  if (typeof v === 'string') for (const problem of templateProblems(v)) err(path, problem)
  else if (Array.isArray(v)) v.forEach((x, i) => checkTemplates(x, `${path}[${i}]`, err))
  else if (isRecord(v)) for (const [k, x] of Object.entries(v)) checkTemplates(x, `${path}.${k}`, err)
}

/** Static positions must not contain `${…}`: UI text must never decide what runs or what the model is told. */
function noTemplate(v: unknown, path: string, err: (p: string, m: string) => void): void {
  const check = (x: unknown, p: string): void => {
    if (typeof x === 'string' && x.includes('${')) err(p, 'templates (${…}) are not allowed here; only input, dsh.title, dsh.files, saveReplyTo, dedupe.key and concurrency.key take templates')
    else if (Array.isArray(x)) x.forEach((y, i) => check(y, `${p}[${i}]`))
    else if (isRecord(x)) for (const [k, y] of Object.entries(x)) check(y, `${p}.${k}`)
  }
  check(v, path)
}

/** Programs a rule needs running (task steps and `on` prefixes). */
export function programsReferenced(rule: Rule): string[] {
  const out = new Set<string>()
  for (const s of rule.steps) if (s.kind === 'task') out.add(s.program)
  for (const e of rule.on) {
    const head = e.split('.')[0]
    if (head !== undefined && head !== '*' && head !== 'sim') out.add(head)
  }
  return [...out]
}

export function matchesEventType(pattern: string, eventType: string): boolean {
  if (pattern === '*') return true
  if (pattern.endsWith('.*')) return eventType.startsWith(pattern.slice(0, -1))
  return pattern === eventType
}

export type { JsonObject }
