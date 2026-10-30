import { EventEmitter } from 'node:events'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { tempDir, waitFor } from './helpers.js'
import { reflexPaths } from '../src/paths.js'

const mocks = vi.hoisted(() => ({ capture: vi.fn(), spawn: vi.fn() }))
vi.mock('../src/cli/exec.js', () => ({ capture: mocks.capture }))
vi.mock('node:child_process', () => ({ spawn: mocks.spawn }))
import { ReflexSetup } from '../src/setup.js'

afterEach(() => vi.clearAllMocks())

async function installer(existing?: string) {
  const paths = reflexPaths(await tempDir('reflex-setup-'))
  const rules = join(paths.dshHome, 'rules.yaml')
  if (existing) await writeFile(rules, existing)
  mocks.capture.mockResolvedValue({ code: 0, stdout: 'Apple Swift version 6.0.1', stderr: '' })
  mocks.spawn.mockImplementation(() => {
    const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), stderr: new EventEmitter(), kill: vi.fn() })
    queueMicrotask(() => child.emit('close', 0))
    return child
  })
  const reconnect = vi.fn()
  return { setup: new ReflexSetup(paths, process.cwd(), rules, reconnect), paths, rules, reconnect }
}

describe('first-run installation', () => {
  it('requires an explicit start, deduplicates starts, and preserves existing rules', async () => {
    const { setup, rules, reconnect } = await installer('version: 1\nrules: []\n')
    expect((await setup.status()).phase).toBe('idle')
    expect(mocks.spawn).not.toHaveBeenCalled()
    setup.start(); setup.start()
    await waitFor(async () => (await setup.status()).phase === 'installed', 3000)
    expect(mocks.spawn).toHaveBeenCalledTimes(2)
    expect(await readFile(rules, 'utf8')).toBe('version: 1\nrules: []\n')
    expect(reconnect).toHaveBeenCalledOnce()
    await setup.stop()
  })

  it('copies initial rules and persists Later without starting the installer', async () => {
    const { setup, rules, paths } = await installer()
    await setup.dismiss()
    expect(JSON.parse(await readFile(join(paths.stateDir, 'setup.json'), 'utf8')).dismissed).toBe(true)
    expect(mocks.spawn).not.toHaveBeenCalled()
    setup.start()
    await waitFor(async () => (await setup.status()).phase === 'installed', 3000)
    expect(await readFile(rules, 'utf8')).toContain('teams.meeting.started')
    await setup.stop()
  })

  it('stops after a signing failure and permits a retry', async () => {
    const { setup } = await installer()
    mocks.spawn.mockImplementationOnce(() => {
      const child = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), stderr: new EventEmitter() })
      queueMicrotask(() => { child.stderr.emit('data', Buffer.from('Signing declined')); child.emit('close', 1) })
      return child
    })
    setup.start()
    await waitFor(async () => (await setup.status()).phase === 'failed', 3000)
    expect(mocks.spawn).toHaveBeenCalledTimes(1)
    expect((await setup.status()).error).toContain('Signing declined')
    setup.start()
    await waitFor(async () => (await setup.status()).phase === 'installed', 3000)
    await setup.stop()
  })

  it('offers the system developer tools installer before signing or compiling', async () => {
    const { setup } = await installer()
    mocks.capture.mockResolvedValue({ code: 1, stdout: '', stderr: 'missing tools' })
    setup.start()
    await waitFor(async () => (await setup.status()).phase === 'tools', 3000)
    expect(mocks.spawn).toHaveBeenCalledWith('/usr/bin/xcode-select', ['--install'], expect.anything())
    expect(mocks.spawn).toHaveBeenCalledTimes(1)
    await setup.stop()
  })
})
