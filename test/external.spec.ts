import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { startExternal } from '../src/dispatch/external.js'
import { pidAlive } from '../src/util/fs.js'
import { tempDir } from './helpers.js'

async function script(dir: string, body: string): Promise<string> {
  const file = join(dir, 'prog.mjs')
  await writeFile(file, body)
  return file
}

describe('run steps (external programs)', () => {
  it('passes input via REFLEX_INPUT and reads result.json', async () => {
    const dir = await tempDir()
    const prog = await script(dir, `
import { readFileSync, writeFileSync } from 'node:fs'
const input = JSON.parse(readFileSync(process.env.REFLEX_INPUT, 'utf8'))
writeFileSync(process.env.REFLEX_RESULT, JSON.stringify({ status: 'partial', output: { echo: input.msg }, files: ['/x'] }))
console.log('hello log')
`)
    const h = await startExternal({ argv: [process.execPath, prog], input: { msg: 'hi; rm -rf /' }, runDir: dir, stepDir: join(dir, 's') })
    const r = await h.done
    expect(r).toMatchObject({ status: 'partial', output: { echo: 'hi; rm -rf /' }, files: ['/x'] })
    expect(await readFile(join(dir, 's', 'output.log'), 'utf8')).toContain('hello log')
  })

  it('without result.json: exit 0 → ok, non-zero → error', async () => {
    const dir = await tempDir()
    const ok = await startExternal({ argv: ['/usr/bin/true'], input: {}, runDir: dir, stepDir: join(dir, 'a') })
    expect((await ok.done).status).toBe('ok')
    const bad = await startExternal({ argv: ['/usr/bin/false'], input: {}, runDir: dir, stepDir: join(dir, 'b') })
    expect((await bad.done).status).toBe('error')
  })

  it('timeout: stop message, SIGTERM, then SIGKILL for a program that ignores SIGTERM; nothing left running', async () => {
    const dir = await tempDir()
    const prog = await script(dir, `
process.on('SIGTERM', () => {})
process.stdin.on('data', () => {})
setInterval(() => {}, 1000)
`)
    const h = await startExternal({ argv: [process.execPath, prog], input: {}, runDir: dir, stepDir: join(dir, 's'), timeoutMs: 200, graceMs: 300 })
    const r = await h.done
    expect(r.status).toBe('timed_out')
    expect(r.signal).toBe('SIGKILL')
    expect(pidAlive(h.pid!)).toBe(false)
  })

  it('cancel stops the program', async () => {
    const dir = await tempDir()
    const prog = await script(dir, 'setInterval(() => {}, 1000)')
    const h = await startExternal({ argv: [process.execPath, prog], input: {}, runDir: dir, stepDir: join(dir, 's') })
    setTimeout(() => h.stop('cancel'), 100)
    const r = await h.done
    expect(r.status).toBe('cancelled')
    expect(pidAlive(h.pid!)).toBe(false)
  })

  it('missing executable is an error, not a crash', async () => {
    const dir = await tempDir()
    const h = await startExternal({ argv: ['/nonexistent/prog'], input: {}, runDir: dir, stepDir: join(dir, 's') })
    const r = await h.done
    expect(r.status).toBe('error')
  })
})
