import { readFile } from 'node:fs/promises'
import { runInNewContext } from 'node:vm'
import { Window } from 'happy-dom'
import { afterEach, expect, it, vi } from 'vitest'

const disposers: (() => void)[] = []
afterEach(() => { for (const dispose of disposers.splice(0)) dispose(); vi.useRealTimers() })

async function client(trusted: boolean, accessFailure = false) {
  vi.useFakeTimers()
  const window = new Window()
  let plugin: any, App: any
  let response = { phase: 'idle', installed: true, dismissed: true, platform: 'darwin', helper: { axTrusted: trusted } }
  const fetch = vi.fn(async (url: string) => {
    if (url.endsWith('/setup/access')) return accessFailure
      ? { ok: false, json: async () => ({ code: 'settingsOpenFailed' }) }
      : { ok: true, json: async () => ({ trusted }) }
    return { ok: true, json: async () => response }
  })
  const React = {
    createElement: (type: any, props: any, ...children: any[]) => ({ type, props, children }),
    useEffect: () => {}, useState: (value: any) => [value, () => {}],
    useSyncExternalStore: () => ({ active: 'en' }),
  }
  const source = await readFile(new URL('../src/client.js', import.meta.url), 'utf8')
  runInNewContext(source, {
    document: window.document, window: { __ModuleLoader__: { load: ({ factory }: any) => { plugin = factory((name: string) => name === 'react' ? React : { Button: 'button' }) } } },
    fetch, setTimeout, clearTimeout,
  })
  const ctx = {
    locale: { getSnapshot: () => ({ active: 'en' }), subscribe: () => () => {}, register: () => {} },
    effect: (fn: () => any) => { const dispose = fn(); if (typeof dispose === 'function') disposers.push(dispose) },
    slots: { inject: (_: string, fn: () => void) => fn(), register: (_: any, component: any) => { App = component } },
  }
  plugin.apply(ctx)
  await vi.advanceTimersByTimeAsync(0)
  const tree = App({ t: (key: string) => key })
  const button = tree.children.find((node: any) => node?.children?.[0] === 'setupOpen')
  button.props.onClick()
  await vi.advanceTimersByTimeAsync(0)
  disposers.push(() => { void window.happyDOM.close() })
  return { document: window.document, fetch, setTrusted: (value: boolean) => { response = { ...response, helper: { axTrusted: value } } } }
}

it('opens the dialog from the real config button and reflects authorized helper status', async () => {
  const { document, fetch } = await client(true)
  const dialog = document.querySelector('dialog')!
  expect(dialog.open).toBe(true)
  expect(dialog.querySelector('[role="status"]')!.textContent).toContain('Helper ready')
  const primary = dialog.querySelector<HTMLButtonElement>('[data-part="primary"]')!
  expect(primary.textContent).toBe('Open Accessibility settings')
  primary.click()
  await vi.advanceTimersByTimeAsync(0)
  expect(fetch.mock.calls.some(([url]) => url.endsWith('/setup/access'))).toBe(true)
  expect(dialog.open).toBe(true)
})

it('keeps an action failure visible across subsequent status polling', async () => {
  const { document } = await client(false, true)
  document.querySelector<HTMLButtonElement>('[data-part="primary"]')!.click()
  await vi.advanceTimersByTimeAsync(0)
  expect(document.querySelector('[role="alert"]')!.textContent).toContain('Could not open System Settings')
  await vi.advanceTimersByTimeAsync(10000)
  expect(document.querySelector('[role="alert"]')!.textContent).toContain('Could not open System Settings')
})
