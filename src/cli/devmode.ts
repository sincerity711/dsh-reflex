/** Dev mode: `$DSH_HOME/reflex/dev-mode` holds an expiry date; dev tools refuse to run without it. */

import type { ReflexPaths } from '../paths.js'
import { readText } from '../util/fs.js'

export async function devModeUntil(paths: ReflexPaths): Promise<Date | 'manual' | undefined> {
  const raw = (await readText(paths.devModeFile))?.trim()
  if (raw === undefined) return undefined
  if (raw === '') return 'manual'
  const until = new Date(raw)
  if (Number.isNaN(until.getTime())) return 'manual'
  return until > new Date() ? until : undefined
}

export async function ensureDev(paths: ReflexPaths): Promise<void> {
  if ((await devModeUntil(paths)) === undefined) throw new Error('dev 模式未开启：先运行 dsh-reflex dev on')
}
