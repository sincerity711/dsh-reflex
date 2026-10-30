/** Loads rules.yaml, hot-reloads on change, keeps the last valid rules when an edit is invalid. */

import { watch, type FSWatcher } from 'node:fs'
import { stat } from 'node:fs/promises'
import { basename, dirname } from 'node:path'
import { parseDocument } from 'yaml'
import { errorMessage, readText } from '../util/fs.js'
import type { Logger } from '../util/misc.js'
import { RulesError, validateRules, type RulesDocument } from './schema.js'

export interface RulesStatus {
  readonly file: string
  readonly state: 'missing' | 'ok' | 'invalid'
  readonly ruleCount: number
  readonly errors: readonly string[]
  readonly loadedAt?: string
  readonly lastGoodAt?: string
}

const EMPTY: RulesDocument = { version: 1, rules: [], maxConcurrentRuns: 8 }

/** Parse and validate YAML text. */
export function parseRules(text: string): RulesDocument {
  const doc = parseDocument(text, { prettyErrors: true, uniqueKeys: true })
  if (doc.errors.length > 0) throw new RulesError(doc.errors.map((e) => e.message.split('\n')[0] ?? e.message))
  return validateRules(doc.toJS({ maxAliasCount: 50 }))
}

export async function validateRulesFile(file: string): Promise<{ ok: true; rules: number } | { ok: false; errors: string[] }> {
  const text = await readText(file)
  if (text === undefined) return { ok: false, errors: [`${file} does not exist`] }
  try {
    return { ok: true, rules: parseRules(text).rules.length }
  } catch (error) {
    return { ok: false, errors: error instanceof RulesError ? [...error.errors] : [errorMessage(error)] }
  }
}

export class RuleStore {
  private current: RulesDocument = EMPTY
  private _status: RulesStatus
  private watcher: FSWatcher | undefined
  private poll: NodeJS.Timeout | undefined
  private debounce: NodeJS.Timeout | undefined
  private lastMtime = 0
  private readonly listeners = new Set<(doc: RulesDocument) => void>()

  constructor(readonly file: string, private readonly logger: Logger) {
    this._status = { file, state: 'missing', ruleCount: 0, errors: [] }
  }

  get rules(): RulesDocument {
    return this.current
  }

  get status(): RulesStatus {
    return this._status
  }

  onChange(listener: (doc: RulesDocument) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  async load(): Promise<RulesStatus> {
    const now = new Date().toISOString()
    let text: string | undefined
    try {
      text = await readText(this.file)
      this.lastMtime = (await stat(this.file).catch(() => undefined))?.mtimeMs ?? 0
    } catch (error) {
      this._status = { ...this._status, state: 'invalid', errors: [errorMessage(error)], loadedAt: now }
      return this._status
    }
    if (text === undefined) {
      this.current = EMPTY
      this._status = { file: this.file, state: 'missing', ruleCount: 0, errors: [], loadedAt: now }
      this.emit()
      return this._status
    }
    try {
      this.current = parseRules(text)
      this._status = { file: this.file, state: 'ok', ruleCount: this.current.rules.length, errors: [], loadedAt: now, lastGoodAt: now }
      this.emit()
    } catch (error) {
      const errors = error instanceof RulesError ? [...error.errors] : [errorMessage(error)]
      this._status = { ...this._status, state: 'invalid', errors, loadedAt: now }
      this.logger.warn(`rules: ${this.file} is invalid; keeping the previous ${this.current.rules.length} rule(s):\n${errors.join('\n')}`)
    }
    return this._status
  }

  /** Watch the file (directory watch survives atomic replace) with a polling fallback. */
  watch(): void {
    const schedule = (): void => {
      if (this.debounce !== undefined) clearTimeout(this.debounce)
      this.debounce = setTimeout(() => {
        this.debounce = undefined
        void this.load().catch((error: unknown) => this.logger.warn(`rules reload failed: ${errorMessage(error)}`))
      }, 300)
    }
    try {
      this.watcher = watch(dirname(this.file), (_event, name) => {
        if (name === null || name === basename(this.file)) schedule()
      })
      this.watcher.on('error', () => undefined)
    } catch {
      // directory may not exist yet; polling covers it
    }
    this.poll = setInterval(() => {
      void stat(this.file).then(
        (st) => {
          if (st.mtimeMs !== this.lastMtime) schedule()
        },
        () => {
          if (this._status.state !== 'missing') schedule()
        },
      )
    }, 5000)
    this.poll.unref?.()
  }

  close(): void {
    this.watcher?.close()
    if (this.poll !== undefined) clearInterval(this.poll)
    if (this.debounce !== undefined) clearTimeout(this.debounce)
    this.listeners.clear()
  }

  private emit(): void {
    for (const l of this.listeners) {
      try {
        l(this.current)
      } catch (error) {
        this.logger.warn(`rules listener failed: ${errorMessage(error)}`)
      }
    }
  }
}
