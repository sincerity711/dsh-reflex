#!/usr/bin/env node
/**
 * Built-in `notify` step: a macOS notification. Runs as an external program (process.execPath with
 * ELECTRON_RUN_AS_NODE=1 under Desktop). Text is passed to osascript as argv, never as script source.
 * input: { title?: string, subtitle?: string, message: string, sound?: string }
 */

import { execFile } from 'node:child_process'
import { readFile, writeFile } from 'node:fs/promises'

const SCRIPT = [
  'on run argv',
  'set t to item 1 of argv',
  'set m to item 2 of argv',
  'set s to item 3 of argv',
  'if s is "" then',
  'display notification m with title t',
  'else',
  'display notification m with title t subtitle s',
  'end if',
  'end run',
]

async function main(): Promise<void> {
  const inputPath = process.env['REFLEX_INPUT']
  const resultPath = process.env['REFLEX_RESULT']
  const input = inputPath ? (JSON.parse(await readFile(inputPath, 'utf8')) as Record<string, unknown>) : {}
  const clip = (v: unknown, n: number): string => (typeof v === 'string' ? v : v === undefined || v === null ? '' : JSON.stringify(v)).slice(0, n)
  const title = clip(input['title'] ?? 'dsh-reflex', 120)
  const message = clip(input['message'] ?? '', 400)
  const subtitle = clip(input['subtitle'] ?? '', 120)
  const args = SCRIPT.flatMap((line) => ['-e', line]).concat([title, message, subtitle])
  const ok = await new Promise<boolean>((resolve) => execFile('/usr/bin/osascript', args, (error) => resolve(error === null)))
  if (resultPath) {
    await writeFile(resultPath, JSON.stringify(ok ? { status: 'ok', output: { delivered: true } } : { status: 'error', output: {}, error: 'osascript failed' }))
  }
  process.exitCode = ok ? 0 : 1
}

main().catch((error: unknown) => {
  process.stderr.write(`notify: ${String(error)}\n`)
  process.exitCode = 1
})
