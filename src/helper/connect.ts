/** One-shot helper connection for the CLI (launches the helper when needed). */

import type { ReflexPaths } from '../paths.js'
import { exists, pidAlive, readJson, readText } from '../util/fs.js'
import { sleep } from '../util/misc.js'
import { HelperClient } from './client.js'
import { launchHelper } from './supervisor.js'

const CLIENT = { name: 'dsh-reflex-cli', version: '0.1.0' }

async function tryConnect(paths: ReflexPaths): Promise<HelperClient> {
  const info = await readJson<{ socket?: string }>(paths.helperInfo)
  const token = (await readText(paths.helperToken))?.trim()
  if (token === undefined || token === '') throw new Error('helper is not running')
  return HelperClient.connect(info?.socket ?? paths.helperSocket, token, CLIENT)
}

export async function helperRunning(paths: ReflexPaths): Promise<number | undefined> {
  const info = await readJson<{ pid?: number }>(paths.helperInfo)
  return info?.pid !== undefined && pidAlive(info.pid) ? info.pid : undefined
}

export async function connectHelper(paths: ReflexPaths, options: { launch?: boolean; idleExitSec?: number } = {}): Promise<HelperClient> {
  try {
    return await tryConnect(paths)
  } catch (error) {
    if (options.launch !== true) throw error
  }
  if (!(await exists(paths.helperApp))) {
    throw new Error(`helper app is not installed at ${paths.helperApp}\nrun: dsh-reflex helper install`)
  }
  if ((await helperRunning(paths)) === undefined) await launchHelper(paths, options.idleExitSec)
  const deadline = Date.now() + 15_000
  let last: unknown
  while (Date.now() < deadline) {
    await sleep(300)
    try {
      return await tryConnect(paths)
    } catch (error) {
      last = error
    }
  }
  throw new Error(`helper did not come up: ${String(last)}`)
}
