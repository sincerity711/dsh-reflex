import { capture } from '../cli/exec.js'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { open, realpath } from 'node:fs/promises'
import { join, relative, isAbsolute } from 'node:path'
import type { ReflexCore } from '../core.js'
import type { TeamsSettings } from '../teams-settings.js'

const ERROR_CODES: Record<string, string> = {
  '请求过大': 'requestTooLarge', '当前实例不是主实例': 'notLeader', '需要 JSON 请求': 'jsonRequired',
  '请求格式无效': 'invalidRequest', '记录不存在': 'runNotFound', '接口不存在': 'endpointNotFound',
  '设置已在其他页面更改，请刷新后重试': 'settingsConflict', '请输入不超过 50000 字符的总结提示词': 'invalidPrompt',
  '工作目录必须是绝对路径': 'absoluteWorkspace', '工作目录不存在或不是文件夹': 'missingWorkspace',
  '回看时间必须是 0–60 分钟': 'invalidLookback', unauthorized: 'unauthorized',
  helperConnecting: 'helperConnecting', settingsOpenFailed: 'settingsOpenFailed',
  '请选择有效的任务模型': 'invalidModel', '归档目录必须是绝对路径或留空': 'invalidArchiveDirectory',
}
const errorResponse = (message: string) => ({ error: message, code: ERROR_CODES[message] ?? 'unknownError' })

const PREFIX = '/dsh-reflex/api'
const FILES = { transcript: 'capture/record.md', raw: 'capture/raw.jsonl', live: 'capture/checkpoint.json', gaps: 'capture/gaps.json', summary: 'summary.md', prompt: 'summarize/prompt.md' } as const

async function boundedFile(root: string, name: string): Promise<string | null> {
  try {
    const base = await realpath(root)
    const target = await realpath(join(root, name))
    const path = relative(base, target)
    if (path.startsWith('..') || isAbsolute(path)) return null
    const file = await open(target, 'r')
    try {
      const buf = Buffer.alloc(200_000)
      const { bytesRead } = await file.read(buf, 0, buf.length, 0)
      return buf.subarray(0, bytesRead).toString('utf8')
    } finally { await file.close() }
  } catch { return null }
}

async function requestBody(req: IncomingMessage): Promise<unknown> {
  let size = 0
  const chunks: Buffer[] = []
  for await (const chunk of req) {
    const b = Buffer.from(chunk as Uint8Array)
    size += b.length
    if (size > 100_000) throw new Error('请求过大')
    chunks.push(b)
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
}

export function makeReflexHandler(core: ReflexCore, reject: (req: IncomingMessage) => number | undefined) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const send = (status: number, data: unknown): void => { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(data)) }
    const rejection = reject(req)
    if (rejection !== undefined) { send(rejection, errorResponse('unauthorized')); return }
    try {
      const active = core.active
      if (!active) { send(503, errorResponse('当前实例不是主实例')); return }
      const path = new URL(req.url ?? '/', 'http://localhost').pathname.slice(PREFIX.length)
      if (req.method === 'GET' && path === '/setup') {
        const helper = await active.supervisor.client?.request('helper.status', {}, 3000).catch(() => null)
        const helperInfo = helper && typeof helper === 'object' && !Array.isArray(helper) ? helper['helper'] ?? null : null
        send(200, { ...await active.setup.status(), helper: helperInfo }); return
      }
      if (req.method === 'POST' && path.startsWith('/setup/')) {
        if (!String(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) { send(415, errorResponse('需要 JSON 请求')); return }
        await requestBody(req)
        if (path === '/setup/install') { active.setup.start(); send(202, await active.setup.status()); return }
        if (path === '/setup/dismiss') { await active.setup.dismiss(); send(200, { ok: true }); return }
        if (path === '/setup/access') {
          const client = active.supervisor.client
          if (!client) { active.supervisor.reset(); send(409, errorResponse('helperConnecting')); return }
          const access = await client.request('helper.requestAccess', { openSettings: false })
          // Explicit navigation must also work with already-authorized and older helpers.
          const opened = await capture('/usr/bin/open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'], { timeoutMs: 10000 })
          if (opened.code !== 0) throw new Error('settingsOpenFailed')
          send(200, access); return
        }
      }
      if (req.method === 'POST' && path === '/locale') {
        if (!String(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) { send(415, errorResponse('需要 JSON 请求')); return }
        const body = await requestBody(req) as { locale?: unknown }
        if (typeof body?.locale !== 'string' || !/^[a-zA-Z0-9-]{1,35}$/.test(body.locale)) throw new Error('请求格式无效')
        active.menuLocale = body.locale
        await active.updateMenu()
        send(200, { ok: true }); return
      }
      if (req.method === 'GET' && path === '/settings') { send(200, await active.teamsSettings.snapshot()); return }
      if (req.method === 'GET' && path === '/models') { send(200, await core.o.bridge.modelCatalog?.() ?? { current: null, models: [], unavailableProviders: [] }); return }
      if (req.method === 'PUT' && path === '/settings') {
        if (!String(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) { send(415, errorResponse('需要 JSON 请求')); return }
        const body = await requestBody(req) as { settings: TeamsSettings; revision: string }
        if (!body || typeof body.revision !== 'string' || !body.settings) throw new Error('请求格式无效')
        send(200, await active.teamsSettings.saveChecked(body.settings, body.revision)); return
      }
      if (req.method === 'GET' && path === '/runs') {
        const items = active.store.list(200).filter(r => r.eventType === 'teams.meeting.started')
        const runs = await Promise.all(items.map(async item => {
          const run = await active.store.get(item.runId)
          return { ...item, title: run?.event.payload?.['title'] ?? null, captureStatus: run?.steps['capture']?.status ?? null }
        }))
        send(200, { runs }); return
      }
      const match = /^\/runs\/([0-9A-HJKMNP-TV-Z]{26})$/.exec(path)
      if (req.method === 'GET' && match) {
        const id = match[1]!
        const run = await active.store.get(id)
        if (!run || run.event.eventType !== 'teams.meeting.started') { send(404, errorResponse('记录不存在')); return }
        const contents = Object.fromEntries(await Promise.all(Object.entries(FILES).map(async ([key, name]) => [key, await boundedFile(active.store.runDir(id), name)])))
        send(200, { run, contents }); return
      }
      send(404, errorResponse('接口不存在'))
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      if (!ERROR_CODES[message]) core.o.logger.warn(`reflex: web request failed: ${message}`)
      send(400, errorResponse(message))
    }
  }
}

export { PREFIX as REFLEX_API_PREFIX }
