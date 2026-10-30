import { Readable } from 'node:stream'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { expect, it, vi } from 'vitest'
import { makeReflexHandler } from '../src/control/web.js'
import type { ReflexCore } from '../src/core.js'

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
