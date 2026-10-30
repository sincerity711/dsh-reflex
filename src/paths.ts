/** Filesystem layout under `$DSH_HOME/reflex` (mirrors swift/Sources/ReflexHelperCore/Paths.swift). */

import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { resolveDshHome } from './util/fs.js'

export interface ReflexPaths {
  readonly dshHome: string
  readonly root: string
  readonly runDir: string
  readonly helperInfo: string
  readonly helperToken: string
  readonly helperSocket: string
  readonly helperApp: string
  readonly programsDir: string
  readonly helperStateDir: string
  readonly logsDir: string
  readonly dataDir: string
  readonly runsDir: string
  readonly stateDir: string
  readonly rulesFile: string
  readonly devModeFile: string
  readonly helperConfigFile: string
  readonly controlSocket: string
  readonly leaderLock: string
}

/** FNV-1a 64-bit hex (same as the Swift side) used for the short socket fallback path. */
export function fnv1a64Hex(text: string): string {
  let hash = 0xcbf29ce484222325n
  const prime = 0x100000001b3n
  for (const byte of Buffer.from(text, 'utf8')) {
    hash ^= BigInt(byte)
    hash = (hash * prime) & 0xffffffffffffffffn
  }
  // Swift's combine(String) appends 0xff after the bytes.
  hash ^= 0xffn
  hash = (hash * prime) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, '0')
}

function socketPath(runDir: string, root: string, name: string): string {
  const primary = join(runDir, name)
  if (Buffer.byteLength(primary) <= 100) return primary
  return join(tmpdir(), `dsh-reflex-${fnv1a64Hex(root).slice(0, 12)}`, name)
}

export function reflexPaths(dshHome: string = resolveDshHome()): ReflexPaths {
  const root = join(dshHome, 'reflex')
  const runDir = join(root, 'run')
  const dataDir = join(root, 'data')
  return {
    dshHome,
    root,
    runDir,
    helperInfo: join(runDir, 'helper.json'),
    helperToken: join(runDir, 'helper.token'),
    helperSocket: socketPath(runDir, root, 'helper.sock'),
    helperApp: join(root, 'helper', 'DSH Reflex Helper.app'),
    programsDir: join(root, 'programs'),
    helperStateDir: join(root, 'helper'),
    logsDir: join(root, 'logs'),
    dataDir,
    runsDir: join(dataDir, 'runs'),
    stateDir: join(root, 'state'),
    rulesFile: join(root, 'rules.yaml'),
    devModeFile: join(root, 'dev-mode'),
    helperConfigFile: join(root, 'helper-config.json'),
    controlSocket: socketPath(runDir, root, 'control.sock'),
    leaderLock: join(runDir, 'leader.lock'),
  }
}

/** Stable digest of a JSON value (sorted keys). */
export function digestJson(value: unknown): string {
  return createHash('sha256').update(stableStringify(value)).digest('hex')
}

export function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${stableStringify(v)}`).join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}
