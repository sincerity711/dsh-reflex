/** `${…}` substitution for data positions (input, dsh.title, dsh.files, saveReplyTo, keys). */

import { isAbsolute, normalize, resolve } from 'node:path'
import type { ReflexEvent } from '../helper/protocol.js'
import { expandHome } from '../util/fs.js'
import { getPath, isRecord, type JsonObject, type JsonValue } from '../util/misc.js'

export interface StepOutcome {
  readonly status: string
  readonly output: JsonObject
  readonly files: readonly string[]
  readonly reply?: string
  readonly sessionId?: string
  readonly error?: string
}

export interface TemplateScope {
  readonly event: ReflexEvent
  readonly run: { readonly id: string; readonly dir: string }
  readonly rule: { readonly id: string }
  readonly steps: Readonly<Record<string, StepOutcome>>
  readonly now: string
}

const EXPR = /\$\{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_-]+)*)\s*\}/g
const ROOTS = new Set(['event', 'run', 'rule', 'steps', 'now'])

/** Syntax problems in a template string (unknown roots, unclosed `${`). */
export function templateProblems(text: string): string[] {
  const problems: string[] = []
  const stripped = text.replace(EXPR, (_m, path: string) => {
    const root = path.split('.')[0] ?? ''
    if (!ROOTS.has(root)) problems.push(`unknown template root "${root}" in \${${path}} (use event, run, rule, steps, now)`)
    return ''
  })
  if (stripped.includes('${')) problems.push(`malformed template in "${text}"`)
  return problems
}

function lookup(scope: TemplateScope, path: string): unknown {
  if (path === 'now') return scope.now
  return getPath(scope as unknown, path)
}

function toText(v: unknown): string {
  if (v === undefined || v === null) return ''
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return JSON.stringify(v)
}

/** Interpolate a string. A string that is exactly one `${…}` keeps the value's JSON type. */
export function renderValue(template: string, scope: TemplateScope): JsonValue {
  const whole = /^\$\{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_-]+)*)\s*\}$/.exec(template)
  if (whole !== null) {
    const v = lookup(scope, whole[1]!)
    return v === undefined ? null : (v as JsonValue)
  }
  return template.replace(EXPR, (_m, path: string) => toText(lookup(scope, path)))
}

export function renderText(template: string, scope: TemplateScope): string {
  return template.replace(EXPR, (_m, path: string) => toText(lookup(scope, path)))
}

/** Render a JSON tree (task/run input): every string leaf is a template. */
export function renderJson(value: JsonValue, scope: TemplateScope): JsonValue {
  if (typeof value === 'string') return renderValue(value, scope)
  if (Array.isArray(value)) return value.map((v) => renderJson(v, scope))
  if (isRecord(value)) {
    const out: JsonObject = {}
    for (const [k, v] of Object.entries(value)) out[k] = renderJson(v as JsonValue, scope)
    return out
  }
  return value
}

/** Make an untrusted value safe as one path segment (no separators, no traversal, bounded). */
export function sanitizeSegment(text: string): string {
  const cleaned = text
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .replace(/[/\\:]/g, '_')
    .replace(/^\.+/, '_')
    .trim()
    .slice(0, 120)
  return cleaned === '' ? '_' : cleaned
}

/**
 * Render a filesystem path. Values coming from the event (UI data) are sanitized into single
 * segments; run/steps values (paths the runtime produced) are used as is. Result is absolute.
 */
export function renderPath(template: string, scope: TemplateScope, base: string): string {
  const text = template.replace(EXPR, (_m, path: string) => {
    const v = toText(lookup(scope, path))
    return path.startsWith('event.') ? sanitizeSegment(v) : v
  })
  const expanded = expandHome(text)
  return normalize(isAbsolute(expanded) ? expanded : resolve(base, expanded))
}

/** Whether `path` is inside one of `roots`. */
export function isInside(path: string, roots: readonly string[]): boolean {
  const p = normalize(path)
  return roots.some((r) => {
    const root = normalize(r).replace(/\/+$/, '')
    return p === root || p.startsWith(`${root}/`)
  })
}
