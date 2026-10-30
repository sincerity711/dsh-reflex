/**
 * Plugin-side program state: which programs the user enabled and exactly which apps/capabilities/
 * actions they confirmed. A manifest asking for more than was confirmed is not run until the user
 * confirms again. Enabling happens only through the `/reflex` slash command (user input).
 */

import { join } from 'node:path'
import type { RulesDocument } from '../rules/schema.js'
import { programsReferenced } from '../rules/schema.js'
import { readJson, writeJsonAtomic } from '../util/fs.js'
import { shortHash, type JsonObject } from '../util/misc.js'
import type { ProgramDesired, ProgramManifest } from './protocol.js'

export interface Confirmation {
  readonly apps: readonly string[]
  readonly capabilities: readonly string[]
  readonly actions: readonly string[]
  readonly version: string
  readonly confirmedAt: string
}

export interface ProgramState {
  enabled: boolean
  confirmed?: Confirmation
  grantedActions: string[]
  config: JsonObject
  updatedAt: string
}

interface StateFile {
  programs: Record<string, ProgramState>
}

export interface ProgramView {
  readonly id: string
  readonly installed: boolean
  readonly version?: string
  readonly enabled: boolean
  readonly needsConfirm: boolean
  readonly required: boolean
  readonly apps: readonly string[]
  readonly capabilities: readonly string[]
  readonly reason?: string
}

export class ProgramsState {
  private state: StateFile = { programs: {} }
  private readonly pending = new Map<string, { code: string; expires: number }>()

  constructor(private readonly stateDir: string, private readonly configOverrides: () => Record<string, JsonObject>) {}

  private get file(): string {
    return join(this.stateDir, 'programs.json')
  }

  async load(): Promise<void> {
    this.state = (await readJson<StateFile>(this.file)) ?? { programs: {} }
    this.state.programs ??= {}
  }

  private async save(): Promise<void> {
    await writeJsonAtomic(this.file, this.state)
  }

  get(id: string): ProgramState | undefined {
    return this.state.programs[id]
  }

  /** What the manifest asks for beyond the confirmation (empty = covered). */
  static expansion(m: ProgramManifest, c: Confirmation | undefined): string[] {
    if (c === undefined) return ['not confirmed']
    const out: string[] = []
    for (const a of m.apps) if (!c.apps.includes(a)) out.push(`app ${a}`)
    for (const cap of m.capabilities) if (!c.capabilities.includes(cap)) out.push(`capability ${cap}`)
    for (const act of m.actions.map((a) => a.id)) if (!c.actions.includes(act)) out.push(`action ${act}`)
    return out
  }

  /** Desired state for the helper (enabled only when the confirmation covers the manifest). */
  desired(installed: readonly ProgramManifest[], rules: RulesDocument): ProgramDesired[] {
    const required = new Set<string>()
    for (const r of rules.rules) if (r.enabled) for (const p of programsReferenced(r)) required.add(p)
    const overrides = this.configOverrides()
    return installed.map((m) => {
      const st = this.state.programs[m.id]
      const covered = ProgramsState.expansion(m, st?.confirmed).length === 0
      return {
        id: m.id,
        enabled: st?.enabled === true && covered,
        required: required.has(m.id),
        config: { ...(overrides[m.id] ?? {}), ...(st?.config ?? {}) },
        grantedActions: (st?.grantedActions ?? []).filter((a) => m.actions.some((d) => d.id === a)),
      }
    })
  }

  views(installed: readonly ProgramManifest[], rules: RulesDocument): ProgramView[] {
    const desired = new Map(this.desired(installed, rules).map((d) => [d.id, d]))
    return installed.map((m) => {
      const st = this.state.programs[m.id]
      const expansion = ProgramsState.expansion(m, st?.confirmed)
      const d = desired.get(m.id)
      return {
        id: m.id, installed: true, version: m.version, enabled: d?.enabled === true,
        needsConfirm: st?.enabled === true && expansion.length > 0,
        required: d?.required === true, apps: m.apps, capabilities: m.capabilities,
        ...(st?.enabled === true && expansion.length > 0 ? { reason: `manifest asks for more than confirmed: ${expansion.join(', ')}` } : {}),
      }
    })
  }

  /**
   * First call: describe what the program asks for and return a confirmation code.
   * Second call with the code: enable. Codes expire after 10 minutes and are bound to the manifest.
   */
  async enable(m: ProgramManifest, code: string | undefined, now = Date.now()): Promise<{ enabled: boolean; text: string }> {
    const fingerprint = shortHash(JSON.stringify({ id: m.id, version: m.version, apps: m.apps, capabilities: m.capabilities, actions: m.actions.map((a) => a.id), size: m.binarySize ?? 0 }), 8)
    const pending = this.pending.get(m.id)
    if (code !== undefined && pending !== undefined && pending.code === code && pending.expires > now) {
      this.pending.delete(m.id)
      const prev = this.state.programs[m.id]
      this.state.programs[m.id] = {
        enabled: true,
        confirmed: { apps: [...m.apps], capabilities: [...m.capabilities], actions: m.actions.map((a) => a.id), version: m.version, confirmedAt: new Date(now).toISOString() },
        grantedActions: m.actions.map((a) => a.id),
        config: prev?.config ?? {},
        updatedAt: new Date(now).toISOString(),
      }
      await this.save()
      return { enabled: true, text: `已启用 ${m.id} ${m.version}。` }
    }
    const fresh = `${fingerprint.slice(0, 3)}${Math.floor(Math.random() * 900 + 100)}`
    this.pending.set(m.id, { code: fresh, expires: now + 600_000 })
    const lines = [
      `程序 ${m.id} ${m.version} 申请：`,
      `- 读取的 App：${m.apps.join(', ')}`,
      `- 能力：${m.capabilities.join(', ')}`,
      `- 动作：${m.actions.length === 0 ? '无' : m.actions.map((a) => `${a.id}（${a.description}）`).join('；')}`,
      `- 事件：${m.emits.join(', ') || '无'}；任务：${m.tasks.join(', ') || '无'}`,
      '原生程序不是沙箱：启用即信任这段代码（构建时的检查结果见 dsh-reflex program lint）。',
      `确认启用请在 10 分钟内输入：/reflex program enable ${m.id} --confirm ${fresh}`,
    ]
    if (code !== undefined) lines.unshift('确认码不对或已过期，重新确认：')
    return { enabled: false, text: lines.join('\n') }
  }

  async disable(id: string): Promise<void> {
    const st = this.state.programs[id]
    if (st === undefined) return
    st.enabled = false
    st.updatedAt = new Date().toISOString()
    await this.save()
  }
}
