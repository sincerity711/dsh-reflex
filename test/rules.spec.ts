import { describe, expect, it } from 'vitest'
import { parseRules } from '../src/rules/loader.js'
import { RulesError, programsReferenced } from '../src/rules/schema.js'
import { isInside, renderJson, renderPath, renderValue, sanitizeSegment, type TemplateScope } from '../src/rules/template.js'
import { event } from './helpers.js'

function errorsOf(yaml: string): string[] {
  try {
    parseRules(yaml)
    return []
  } catch (error) {
    if (error instanceof RulesError) return [...error.errors]
    throw error
  }
}

describe('rules validation', () => {
  it('accepts the example document', async () => {
    const { readFile } = await import('node:fs/promises')
    const doc = parseRules(await readFile('examples/rules/teams-meeting-summary.yaml', 'utf8'))
    expect(doc.rules.map((r) => r.id)).toEqual(['teams-meeting-summary', 'captions-unavailable-notice'])
    expect(programsReferenced(doc.rules[0]!)).toEqual(['teams'])
  })

  it('rejects templates in static positions (task, argv, prompt, promptFile, on)', () => {
    const errors = errorsOf(`
version: 1
rules:
  - id: bad
    on: "\${event.payload.type}"
    steps:
      - id: a
        task: "teams/\${event.payload.task}"
      - id: b
        run: { argv: ["/bin/echo", "\${event.payload.x}"] }
      - id: c
        dsh: { prompt: "do \${event.payload.what}", promptFile: "\${event.payload.file}" }
`)
    expect(errors.join('\n')).toMatch(/on.*templates/)
    expect(errors.join('\n')).toMatch(/steps\[a\]\.task: templates/)
    expect(errors.join('\n')).toMatch(/run\.argv\[1\]: templates/)
    expect(errors.join('\n')).toMatch(/dsh\.prompt: templates/)
    expect(errors.join('\n')).toMatch(/dsh\.promptFile: templates/)
  })

  it('reports unknown next targets, relative argv, bad durations and unknown template roots', () => {
    const errors = errorsOf(`
version: 1
rules:
  - id: r
    on: x.y
    steps:
      - id: a
        run: { argv: ["echo"] }
        timeout: soon
        next: { ok: nowhere }
        input: { v: "\${secrets.token}" }
`)
    expect(errors.join('\n')).toMatch(/argv\[0\] must be an absolute path/)
    expect(errors.join('\n')).toMatch(/invalid duration "soon"/)
    expect(errors.join('\n')).toMatch(/unknown step nowhere/)
    expect(errors.join('\n')).toMatch(/unknown template root "secrets"/)
  })

  it('rejects duplicate rule ids and invalid YAML', () => {
    expect(errorsOf('version: 1\nrules:\n  - id: a\n    on: x.y\n    steps: [{ run: { builtin: notify } }]\n  - id: a\n    on: x.y\n    steps: [{ run: { builtin: notify } }]\n').join()).toMatch(/duplicate rule id a/)
    expect(errorsOf('version: 1\nrules: [\n').length).toBeGreaterThan(0)
  })
})

describe('templates', () => {
  const scope: TemplateScope = {
    event: event('teams.meeting.started', { payload: { title: 'Q3 / plan', n: 3 } }),
    run: { id: 'R1', dir: '/data/runs/R1' },
    rule: { id: 'rule' },
    steps: { capture: { status: 'ok', output: { recordPath: '/data/runs/R1/capture/record.md', lines: 12 }, files: [] } },
    now: '2026-10-09T00:00:00.000Z',
  }

  it('a whole-string template keeps the JSON type; mixed text interpolates', () => {
    expect(renderValue('${event.payload.n}', scope)).toBe(3)
    expect(renderValue('${steps.capture.output}', scope)).toEqual({ recordPath: '/data/runs/R1/capture/record.md', lines: 12 })
    expect(renderValue('n=${event.payload.n}', scope)).toBe('n=3')
    expect(renderValue('${event.payload.missing}', scope)).toBeNull()
    expect(renderJson({ a: ['${rule.id}', 1] }, scope)).toEqual({ a: ['rule', 1] })
  })

  it('event values in paths become single safe segments', () => {
    expect(sanitizeSegment('../../etc/passwd')).toBe('__.._etc_passwd')
    expect(renderPath('${run.dir}/${event.payload.title}.md', scope, '/tmp')).toBe('/data/runs/R1/Q3 _ plan.md')
    expect(renderPath('${steps.capture.output.recordPath}', scope, '/tmp')).toBe('/data/runs/R1/capture/record.md')
    expect(isInside('/data/runs/R1/x', ['/data'])).toBe(true)
    expect(isInside('/database/x', ['/data'])).toBe(false)
  })
})
