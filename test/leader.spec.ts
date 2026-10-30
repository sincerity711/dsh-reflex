import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { LeaderLock } from '../src/control/leader.js'
import { writeJsonAtomic } from '../src/util/fs.js'
import { silentLogger } from '../src/util/misc.js'
import { tempDir } from './helpers.js'

const hooks = { onLeader: () => undefined, onPassive: () => undefined }

describe('leader lock', () => {
  it('only one of two hosts becomes leader', async () => {
    const dir = await tempDir()
    const file = join(dir, 'leader.lock')
    const a = new LeaderLock(file, 'desktop', silentLogger, hooks)
    const b = new LeaderLock(file, 'web', silentLogger, hooks)
    expect(await a.tryAcquire()).toBe(true)
    // Pretend host A lives in another (alive) process.
    const { readJson } = await import('../src/util/fs.js')
    const held = (await readJson<Record<string, unknown>>(file))!
    await writeJsonAtomic(file, { ...held, pid: process.ppid })
    expect(await b.tryAcquire()).toBe(false)
    expect(b.state).toMatchObject({ state: 'passive' })
    await a.stop()
    expect(await b.tryAcquire()).toBe(true)
  })

  it('takes over a lock whose holder is dead or whose heartbeat is stale', async () => {
    const dir = await tempDir()
    const file = join(dir, 'leader.lock')
    await writeJsonAtomic(file, { pid: 999999, host: 'ghost', token: 't', startedAt: new Date().toISOString(), heartbeatAt: new Date().toISOString() })
    const a = new LeaderLock(file, 'desktop', silentLogger, hooks)
    expect(await a.tryAcquire()).toBe(true)
    await writeJsonAtomic(file, { pid: process.ppid, host: 'stale', token: 't2', startedAt: '2020-01-01T00:00:00Z', heartbeatAt: '2020-01-01T00:00:00Z' })
    const b = new LeaderLock(file, 'web', silentLogger, hooks)
    expect(await b.tryAcquire()).toBe(true)
  })
})
