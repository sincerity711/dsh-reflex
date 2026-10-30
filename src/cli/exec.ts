/** Child-process helpers for the CLI (argv only, no shell). */

import { spawn } from 'node:child_process'

/** Run a command with inherited stdio; resolves with the exit code. */
export function run(command: string, argv: string[], options: { env?: Record<string, string>; cwd?: string } = {}): Promise<number> {
  return new Promise((resolve) => {
    const child = spawn(command, argv, {
      stdio: 'inherit',
      env: { ...process.env, ...(options.env ?? {}) },
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    })
    child.on('exit', (code) => resolve(code ?? 1))
    child.on('error', (error) => {
      process.stderr.write(`${command}: ${error.message}\n`)
      resolve(1)
    })
  })
}

/** Run a command and capture stdout/stderr. */
export function capture(command: string, argv: string[], options: { cwd?: string; env?: Record<string, string>; timeoutMs?: number } = {}): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(command, argv, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, ...(options.env ?? {}) },
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    })
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8').on('data', (d: string) => { stdout += d })
    child.stderr.setEncoding('utf8').on('data', (d: string) => { stderr += d })
    const timer = options.timeoutMs === undefined ? undefined : setTimeout(() => child.kill('SIGKILL'), options.timeoutMs)
    child.on('exit', (code) => {
      if (timer !== undefined) clearTimeout(timer)
      resolve({ code: code ?? 1, stdout, stderr })
    })
    child.on('error', (error) => {
      if (timer !== undefined) clearTimeout(timer)
      resolve({ code: 1, stdout, stderr: stderr + error.message })
    })
  })
}
