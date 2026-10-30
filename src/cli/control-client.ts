/** CLI side of the plugin control socket (status, pause/resume, runs, rules, sim). */

import { connect } from 'node:net'
import { resolve } from 'node:path'
import type { ReflexPaths } from '../paths.js'
import { readText } from '../util/fs.js'
import type { JsonValue } from '../util/misc.js'
import { bool, flag, num, type ParsedArgs } from './args.js'
import { connectHelper } from '../helper/connect.js'
import { formatStatus } from '../control/format.js'
import { validateRulesFile } from '../rules/loader.js'

export async function controlRequest(paths: ReflexPaths, method: string, params: JsonValue = {}, timeoutMs = 15000): Promise<JsonValue> {
  const token = (await readText(`${paths.controlSocket}.token`))?.trim()
  if (token === undefined) throw new Error('DSH 插件没有在运行（没有找到控制 socket）。在 DSH Desktop 或 dsh web 中挂载 dsh-reflex 后再试。')
  return new Promise((resolvePromise, reject) => {
    const socket = connect(paths.controlSocket)
    let buffer = ''
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error(`control request ${method} timed out`))
    }, timeoutMs)
    socket.setEncoding('utf8')
    socket.on('connect', () => socket.write(`${JSON.stringify({ id: 1, token, method, params })}\n`))
    socket.on('data', (chunk: string) => {
      buffer += chunk
      const nl = buffer.indexOf('\n')
      if (nl < 0) return
      clearTimeout(timer)
      socket.end()
      try {
        const msg = JSON.parse(buffer.slice(0, nl)) as { result?: JsonValue; error?: { message?: string } }
        if (msg.error !== undefined) reject(new Error(msg.error.message ?? 'control error'))
        else resolvePromise(msg.result ?? null)
      } catch (error) {
        reject(error)
      }
    })
    socket.on('error', (error) => {
      clearTimeout(timer)
      reject(new Error(`cannot reach the DSH plugin control socket (${error.message}). Is dsh-reflex mounted and leader?`))
    })
  })
}

export async function controlCommand(paths: ReflexPaths, args: ParsedArgs): Promise<number> {
  const [cmd, sub, third] = args.positionals
  const json = bool(args, 'json')
  const print = (v: JsonValue): void => {
    process.stdout.write(typeof v === 'string' ? `${v}\n` : `${JSON.stringify(v, null, 2)}\n`)
  }
  switch (cmd) {
    case 'status': {
      try {
        const status = await controlRequest(paths, 'status')
        process.stdout.write(json ? `${JSON.stringify(status, null, 2)}\n` : formatStatus(status))
        return 0
      } catch (error) {
        process.stderr.write(`${(error as Error).message}\n(falling back to helper status)\n`)
        const client = await connectHelper(paths)
        const status = await client.request('helper.status', {})
        client.close()
        process.stdout.write(json ? `${JSON.stringify(status, null, 2)}\n` : formatStatus({ helper: status }))
        return 0
      }
    }
    case 'pause':
      print(await controlRequest(paths, 'pause', { all: bool(args, 'all') }))
      return 0
    case 'resume':
      print(await controlRequest(paths, 'resume'))
      return 0
    case 'runs':
      print(await controlRequest(paths, 'runs.list', { limit: num(args, 'limit', 20) }))
      return 0
    case 'run':
      if (sub === undefined) throw new Error('usage: dsh-reflex run <runId>')
      print(await controlRequest(paths, 'runs.get', { runId: sub }))
      return 0
    case 'cancel':
      if (sub === undefined) throw new Error('usage: dsh-reflex cancel <runId>')
      print(await controlRequest(paths, 'runs.cancel', { runId: sub }))
      return 0
    case 'rules':
      if (sub === 'path') {
        process.stdout.write(`${paths.rulesFile}\n`)
        return 0
      }
      if (sub === 'validate') {
        const file = resolve(third ?? paths.rulesFile)
        const r = await validateRulesFile(file)
        if (r.ok) {
          process.stdout.write(`${file}: ${r.rules} rule(s) OK\n`)
          return 0
        }
        process.stdout.write(`${file}: invalid\n${r.errors.map((e) => `  - ${e}`).join('\n')}\n`)
        return 1
      }
      if (sub === 'reload') {
        print(await controlRequest(paths, 'rules.reload'))
        return 0
      }
      throw new Error('usage: dsh-reflex rules validate [file] | path | reload')
    case 'sim': {
      const file = flag(args, 'file')
      if (file !== undefined) {
        // Replay a sequence: one event JSON per line, `--delay` between them.
        const { readFile } = await import('node:fs/promises')
        const { parseDuration, sleep } = await import('../util/misc.js')
        const delay = parseDuration(flag(args, 'delay') ?? '2s')
        const lines = (await readFile(resolve(file), 'utf8')).split('\n').filter((l) => l.trim() !== '')
        for (const [i, line] of lines.entries()) {
          if (i > 0) await sleep(delay)
          print(await controlRequest(paths, 'sim.emit', { event: JSON.parse(line) as JsonValue }))
        }
        return 0
      }
      if (sub === undefined) throw new Error('usage: dsh-reflex sim <eventType> [--payload json] [--correlation id] [--resource id] [--via plugin|helper] | sim --file events.jsonl [--delay 2s]')
      const payload = flag(args, 'payload')
      const event: Record<string, JsonValue> = {
        eventType: sub,
        resourceId: flag(args, 'resource') ?? 'sim',
        payload: payload === undefined ? {} : (JSON.parse(payload) as JsonValue),
      }
      const correlation = flag(args, 'correlation')
      if (correlation !== undefined) event['correlationId'] = correlation
      const dedupe = flag(args, 'dedupe')
      if (dedupe !== undefined) event['dedupeKey'] = dedupe
      if ((flag(args, 'via') ?? 'plugin') === 'helper') {
        const client = await connectHelper(paths)
        print(await client.request('sim.emit', { program: 'sim', event }))
        client.close()
      } else {
        print(await controlRequest(paths, 'sim.emit', { event }))
      }
      return 0
    }
    default:
      throw new Error(`unknown command ${cmd}`)
  }
}
