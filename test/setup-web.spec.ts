import { Readable } from 'node:stream'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { expect, it, vi } from 'vitest'
import { makeReflexHandler } from '../src/control/web.js'
import type { ReflexCore } from '../src/core.js'

const openSettings = vi.hoisted(() => vi.fn())
vi.mock('../src/cli/exec.js', () => ({ capture: openSettings }))

it('requires host authorization and JSON before starting native installation', async () => {
  const start = vi.fn(), status = vi.fn(async () => ({ phase: 'checking' }))
  const core = { active: { setup: { start, status } }, o: { logger: { warn: vi.fn() } } } as unknown as ReflexCore
  async function request(rejection: number | undefined, contentType: string) {
    const req = Object.assign(Readable.from(['{}']), { url: '/dsh-reflex/api/setup/install', method: 'POST', headers: { 'content-type': contentType } }) as IncomingMessage
    let code = 0
    const res = { writeHead: (value: number) => { code = value }, end: vi.fn() } as unknown as ServerResponse
    await makeReflexHandler(core, () => rejection)(req, res)
    return code
  }
  expect(await request(401, 'application/json')).toBe(401)
  expect(start).not.toHaveBeenCalled()
  expect(await request(undefined, 'text/plain')).toBe(415)
  expect(start).not.toHaveBeenCalled()
  expect(await request(undefined, 'application/json')).toBe(202)
  expect(start).toHaveBeenCalledOnce()
})

it('returns the actual nested helper permission status to the setup client', async () => {
  const core = { active: { setup: { status: async () => ({ installed: true }) }, supervisor: { client: { request: async () => ({ helper: { axTrusted: true, version: '1' }, programs: [] }) } } } } as unknown as ReflexCore
  const req = Object.assign(Readable.from([]), { url: '/dsh-reflex/api/setup', method: 'GET', headers: {} }) as IncomingMessage
  let body = ''
  const res = { writeHead: vi.fn(), end: (value: string) => { body = value } } as unknown as ServerResponse
  await makeReflexHandler(core, () => undefined)(req, res)
  expect(JSON.parse(body).helper).toEqual({ axTrusted: true, version: '1' })
})

it('opens System Settings explicitly even when the helper is already authorized', async () => {
  openSettings.mockResolvedValue({ code: 0, stdout: '', stderr: '' })
  const request = vi.fn(async () => ({ trusted: true }))
  const core = { active: { supervisor: { client: { request } } } } as unknown as ReflexCore
  const req = Object.assign(Readable.from(['{}']), { url: '/dsh-reflex/api/setup/access', method: 'POST', headers: { 'content-type': 'application/json' } }) as IncomingMessage
  let code = 0, body = ''
  const res = { writeHead: (value: number) => { code = value }, end: (value: string) => { body = value } } as unknown as ServerResponse
  await makeReflexHandler(core, () => undefined)(req, res)
  expect(code).toBe(200)
  expect(JSON.parse(body).trusted).toBe(true)
  expect(request).toHaveBeenCalledWith('helper.requestAccess', { openSettings: false })
  expect(openSettings).toHaveBeenCalledWith('/usr/bin/open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'], { timeoutMs: 10000 })
})
