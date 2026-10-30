/** Small filesystem helpers (zero harness dependencies so the CLI runs standalone). */

import { randomBytes } from 'node:crypto'
import { constants as fsConstants } from 'node:fs'
import { appendFile, chmod, mkdir, open, readFile, readdir, rename, rm, stat, unlink } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'

/** `$DSH_HOME` (non-blank), else `~/.dsh`. */
export function resolveDshHome(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env['DSH_HOME']?.trim()
  return resolve(configured === undefined || configured === '' ? join(homedir(), '.dsh') : expandHome(configured))
}

export function expandHome(path: string): string {
  if (path === '~') return homedir()
  if (path.startsWith('~/')) return join(homedir(), path.slice(2))
  return path
}

/** Create a private directory tree (0700). */
export async function ensurePrivateDir(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 })
  try {
    await chmod(path, 0o700)
  } catch {
    // best effort
  }
}

/** Atomically replace `file` with `content` (temp sibling + rename). */
export async function writeFileAtomic(file: string, content: string | Uint8Array, mode = 0o600): Promise<void> {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`
  const handle = await open(tmp, fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL, mode)
  try {
    await handle.writeFile(content)
    await handle.sync()
  } finally {
    await handle.close()
  }
  try {
    await rename(tmp, file)
  } catch (error) {
    await unlink(tmp).catch(() => undefined)
    throw error
  }
}

export async function writeJsonAtomic(file: string, value: unknown, mode = 0o600): Promise<void> {
  await writeFileAtomic(file, `${JSON.stringify(value, null, 2)}\n`, mode)
}

export async function readJson<T>(file: string): Promise<T | undefined> {
  try {
    return JSON.parse(await readFile(file, 'utf8')) as T
  } catch (error) {
    if (isNotFound(error)) return undefined
    throw error
  }
}

export async function readText(file: string): Promise<string | undefined> {
  try {
    return await readFile(file, 'utf8')
  } catch (error) {
    if (isNotFound(error)) return undefined
    throw error
  }
}

export async function appendLine(file: string, line: string): Promise<void> {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 })
  await appendFile(file, `${line}\n`, { mode: 0o600 })
}

export async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

export async function listDir(path: string): Promise<string[]> {
  try {
    return await readdir(path)
  } catch (error) {
    if (isNotFound(error)) return []
    throw error
  }
}

export async function removePath(path: string): Promise<void> {
  await rm(path, { recursive: true, force: true })
}

export function isNotFound(error: unknown): boolean {
  return typeof error === 'object' && error !== null && (error as { code?: unknown }).code === 'ENOENT'
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}

/** Whether a process with this pid exists (signal 0). */
export function pidAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as { code?: string }).code === 'EPERM'
  }
}
