import { readFile } from 'node:fs/promises'
import { runInNewContext } from 'node:vm'
import { describe, expect, it, vi } from 'vitest'

describe('Reflex client locale', () => {
  it('registers complete English and Chinese dictionaries and the locale-aware slot', async () => {
    let plugin: any
    const source = await readFile(new URL('../src/client.js', import.meta.url), 'utf8')
    runInNewContext(source, { window: { __ModuleLoader__: { load: ({ factory }: any) => { plugin = factory(() => ({})) } } }, fetch: async () => ({ ok: true, json: async () => ({}) }), setTimeout, clearTimeout })
    let dictionaries: any, options: any
    const ctx = { locale: { register: (_name: string, data: any) => { dictionaries = data }, getSnapshot: () => ({ active: 'en' }), subscribe: () => () => {} }, effect: (f: () => void) => f(), slots: { inject: (_name: string, f: () => void) => f(), register: (o: any) => { options = o } } }
    plugin.apply(ctx)
    expect(plugin.inject).toContain('locale')
    expect(Object.keys(dictionaries.zh).sort()).toEqual(Object.keys(dictionaries.en).sort())
    expect(dictionaries.en.settingsConflict).toContain('Refresh')
    expect(dictionaries.zh.settingsConflict).toContain('刷新')
    expect(options).toMatchObject({ name: 'plugins.bundle.config', key: '@sincerity711/dsh-reflex', locale: 'dsh-reflex' })
  })

  it('retries locale sync after startup and propagates later changes', async () => {
    vi.useFakeTimers()
    try {
      let plugin: any, change: () => void = () => {}, language = 'zh', dispose: (() => void) | undefined
      const requests: string[] = []
      const fetch = vi.fn(async (_url: string, options: any) => {
        requests.push(JSON.parse(options.body).locale)
        if (requests.length === 1) throw new Error('server not ready')
        return { ok: true, json: async () => ({}) }
      })
      const source = await readFile(new URL('../src/client.js', import.meta.url), 'utf8')
      runInNewContext(source, { window: { __ModuleLoader__: { load: ({ factory }: any) => { plugin = factory(() => ({})) } } }, fetch, setTimeout, clearTimeout })
      const ctx = { locale: { register: () => {}, getSnapshot: () => ({ active: language }), subscribe: (f: () => void) => { change = f; return () => {} } }, effect: (f: () => any, name: string) => { const cleanup = f(); if (name === 'dsh-reflex: menu locale') dispose = cleanup }, slots: { inject: (_name: string, f: () => void) => f(), register: () => {} } }
      plugin.apply(ctx)
      await vi.advanceTimersByTimeAsync(2000)
      expect(requests).toEqual(['zh', 'zh'])
      language = 'en'; change()
      await vi.advanceTimersByTimeAsync(0)
      expect(requests).toEqual(['zh', 'zh', 'en'])
      dispose?.()
    } finally { vi.useRealTimers() }
  })
})
