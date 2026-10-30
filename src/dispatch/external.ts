/**
 * `run` steps: local programs started with argv (never a shell).
 *
 * Contract: env REFLEX_INPUT (input JSON file), REFLEX_RESULT (where to write result.json),
 * REFLEX_RUN_DIR / REFLEX_STEP_DIR; stdin is a JSON-lines control channel ({"type":"stop"});
 * stdout/stderr go to the step log; missing result.json → exit 0 = ok, else error;
 * timeout/cancel → stop message, SIGTERM, then SIGKILL after a grace period.
 */

import { spawn } from 'node:child_process'
import { createWriteStream } from 'node:fs'
import { join } from 'node:path'
import { ensurePrivateDir, readJson, writeJsonAtomic } from '../util/fs.js'
import { isRecord, type JsonObject, type JsonValue } from '../util/misc.js'

export interface ExternalSpec {
  readonly argv: readonly string[]
  readonly cwd?: string
  readonly env?: Readonly<Record<string, string>>
  readonly input: JsonValue
  readonly runDir: string
  readonly stepDir: string
  readonly timeoutMs?: number
  readonly graceMs?: number
}

export interface ExternalResult {
  readonly status: string
  readonly output: JsonObject
  readonly files: string[]
  readonly error?: string
  readonly exitCode: number | null
  readonly signal: string | null
}

export interface ExternalHandle {
  readonly pid: number | undefined
  readonly done: Promise<ExternalResult>
  /** Ask the program to stop; escalates to SIGTERM/SIGKILL. */
  stop(reason: 'cancel' | 'timeout'): void
}

const PASSTHROUGH_ENV = ['PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'TMPDIR', 'SHELL', 'DSH_HOME']

export async function startExternal(spec: ExternalSpec): Promise<ExternalHandle> {
  await ensurePrivateDir(spec.stepDir)
  const inputFile = join(spec.stepDir, 'input.json')
  const resultFile = join(spec.stepDir, 'result.json')
  await writeJsonAtomic(inputFile, spec.input ?? {})
  const env: Record<string, string> = {}
  for (const k of PASSTHROUGH_ENV) {
    const v = process.env[k]
    if (v !== undefined) env[k] = v
  }
  Object.assign(env, spec.env ?? {}, {
    REFLEX_INPUT: inputFile,
    REFLEX_RESULT: resultFile,
    REFLEX_RUN_DIR: spec.runDir,
    REFLEX_STEP_DIR: spec.stepDir,
  })
  const log = createWriteStream(join(spec.stepDir, 'output.log'), { flags: 'a', mode: 0o600 })
  log.on('error', () => undefined)
  const [command, ...args] = spec.argv
  if (command === undefined) throw new Error('empty argv')
  const child = spawn(command, args, {
    cwd: spec.cwd ?? spec.stepDir,
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
    shell: false,
    detached: false,
  })
  child.stdout.on('data', (d: Buffer) => log.write(d))
  child.stderr.on('data', (d: Buffer) => log.write(d))
  child.stdin.on('error', () => undefined)
  let stopReason: 'cancel' | 'timeout' | undefined
  let killTimer: NodeJS.Timeout | undefined
  let timeoutTimer: NodeJS.Timeout | undefined
  let spawnError: Error | undefined
  const grace = spec.graceMs ?? 5000

  const stop = (reason: 'cancel' | 'timeout'): void => {
    if (stopReason !== undefined || child.exitCode !== null) return
    stopReason = reason
    try {
      child.stdin.write(`${JSON.stringify({ type: 'stop', reason })}\n`)
      child.stdin.end()
    } catch {
      // ignore
    }
    child.kill('SIGTERM')
    killTimer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    }, grace)
  }
  if (spec.timeoutMs !== undefined && spec.timeoutMs > 0) timeoutTimer = setTimeout(() => stop('timeout'), spec.timeoutMs)

  const done = new Promise<ExternalResult>((resolve) => {
    child.on('error', (error) => {
      spawnError = error
    })
    child.on('close', (code, signal) => {
      if (killTimer !== undefined) clearTimeout(killTimer)
      if (timeoutTimer !== undefined) clearTimeout(timeoutTimer)
      log.end()
      void (async () => {
        const base = { exitCode: code, signal: signal ?? null }
        if (spawnError !== undefined) {
          resolve({ ...base, status: 'error', output: {}, files: [], error: `cannot start ${command}: ${spawnError.message}` })
          return
        }
        if (stopReason !== undefined) {
          resolve({ ...base, status: stopReason === 'timeout' ? 'timed_out' : 'cancelled', output: {}, files: [], error: `stopped (${stopReason})` })
          return
        }
        const written = await readJson<unknown>(resultFile).catch(() => undefined)
        if (isRecord(written) && typeof written['status'] === 'string') {
          resolve({
            ...base,
            status: written['status'],
            output: isRecord(written['output']) ? (written['output'] as JsonObject) : {},
            files: Array.isArray(written['files']) ? written['files'].filter((f): f is string => typeof f === 'string') : [],
            ...(typeof written['error'] === 'string' ? { error: written['error'] } : {}),
          })
          return
        }
        resolve({ ...base, status: code === 0 ? 'ok' : 'error', output: {}, files: [], ...(code === 0 ? {} : { error: `exit code ${code}${signal ? ` (${signal})` : ''}` }) })
      })()
    })
  })
  return { pid: child.pid, done, stop }
}
