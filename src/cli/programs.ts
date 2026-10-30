/** `dsh-reflex program …`: scaffold, build, lint, test, install, list, dev-run ReflexKit programs. */

import { copyFile, chmod, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'
import { connectHelper, helperRunning } from '../helper/connect.js'
import type { ProgramManifest } from '../helper/protocol.js'
import type { ReflexPaths } from '../paths.js'
import { ensurePrivateDir, exists, listDir, readJson, writeJsonAtomic } from '../util/fs.js'
import { sha256 } from '../util/misc.js'
import { bool, flag, flags, type ParsedArgs } from './args.js'
import { ensureDev } from './devmode.js'
import { capture, run } from './exec.js'

export function programName(id: string): string {
  return id.split('-').map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('')
}

export async function programCommand(paths: ReflexPaths, packageRoot: string, args: ParsedArgs): Promise<number> {
  const sub = args.positionals[1]
  const target = args.positionals[2]
  switch (sub) {
    case 'new':
      return newProgram(packageRoot, target, args)
    case 'build': {
      const dir = resolve(target ?? '.')
      const r = await buildProgram(dir, { release: true })
      await printLint(dir)
      process.stdout.write(`built ${r.binary}\nmanifest: ${r.manifest.id} ${r.manifest.version} apps=${r.manifest.apps.join(',')} capabilities=${r.manifest.capabilities.join(',')}\n`)
      return 0
    }
    case 'lint':
      return (await printLint(resolve(target ?? '.'))) > 0 ? 1 : 0
    case 'test':
      return run('swift', ['test'], { cwd: resolve(target ?? '.') })
    case 'install': {
      const ok = await buildAndInstall(paths, packageRoot, resolve(target ?? '.'), { quiet: false })
      return ok ? 0 : 1
    }
    case 'list':
      return listPrograms(paths, bool(args, 'json'))
    case 'run':
      return devRun(paths, target, args)
    default:
      process.stderr.write('usage: dsh-reflex program new|build|lint|test|install|list|run …\n')
      return 64
  }
}

async function newProgram(packageRoot: string, id: string | undefined, args: ParsedArgs): Promise<number> {
  if (id === undefined || !/^[a-z][a-z0-9-]{0,39}$/.test(id)) throw new Error('usage: dsh-reflex program new <id> --app <bundleId> (id: lowercase, digits, dashes)')
  const apps = flags(args, 'app')
  if (apps.length === 0) throw new Error('--app <bundleId> is required (repeatable)')
  const dest = resolve(flag(args, 'dir') ?? join(process.cwd(), id))
  if (await exists(dest)) throw new Error(`${dest} already exists`)
  const name = programName(id)
  const template = join(packageRoot, 'programs', 'template')
  const swiftPkg = join(packageRoot, 'swift')
  const replace = (text: string): string => text
    .replaceAll('__ID__', id)
    .replaceAll('__NAME__', name)
    .replaceAll('__APPS__', apps.map((a) => JSON.stringify(a)).join(', '))
    .replaceAll('__REFLEXKIT_PATH__', relative(dest, swiftPkg) || '.')
  const copyTree = async (src: string, dst: string): Promise<void> => {
    await mkdir(dst, { recursive: true })
    for (const entry of await readdir(src)) {
      const from = join(src, entry)
      const to = join(dst, replace(entry))
      if ((await stat(from)).isDirectory()) await copyTree(from, to)
      else await writeFile(to, replace(await readFile(from, 'utf8')))
    }
  }
  await copyTree(template, dest)
  process.stdout.write(`created ${dest}
next:
  1. dsh-reflex ax inspect --app ${apps[0]}        # find selectors
  2. dsh-reflex ax record --app ${apps[0]} --duration 60s --out ${join(dest, 'Fixtures', 'sample.jsonl')}
  3. edit Sources/${name}/Program.swift and Tests/, then: dsh-reflex program test ${dest}
  4. dsh-reflex program install ${dest}             # installed disabled; the user enables it with /reflex program enable ${id}
`)
  return 0
}

export interface BuildResult {
  readonly binary: string
  readonly manifest: ProgramManifest
}

export async function buildProgram(dir: string, options: { release: boolean; quiet?: boolean }): Promise<BuildResult> {
  if (!(await exists(join(dir, 'Package.swift')))) throw new Error(`${dir} is not a SwiftPM package`)
  const config = options.release ? 'release' : 'debug'
  const code = options.quiet
    ? (await capture('swift', ['build', '-c', config], { cwd: dir })).code
    : await run('swift', ['build', '-c', config], { cwd: dir })
  if (code !== 0) {
    if (options.quiet) {
      const r = await capture('swift', ['build', '-c', config], { cwd: dir })
      throw new Error(`swift build failed:\n${r.stderr.slice(-4000)}${r.stdout.slice(-4000)}`)
    }
    throw new Error('swift build failed')
  }
  const binPath = (await capture('swift', ['build', '-c', config, '--show-bin-path'], { cwd: dir })).stdout.trim()
  const manifestJSON = await readProductManifest(dir, binPath)
  return { binary: join(binPath, manifestJSON.id), manifest: manifestJSON }
}

async function readProductManifest(dir: string, binPath: string): Promise<ProgramManifest> {
  // The executable product name is the program id; find it by asking each executable for --manifest.
  const candidates = (await listDir(binPath)).filter((f) => !f.includes('.') && !f.endsWith('Tests'))
  for (const c of candidates) {
    const full = join(binPath, c)
    try {
      if (!(await stat(full)).isFile()) continue
    } catch {
      continue
    }
    const r = await capture(full, ['--manifest'], { timeoutMs: 10_000 })
    if (r.code === 2) throw new Error(`${c}: ${r.stderr.trim()}`)
    if (r.code !== 0) continue
    try {
      const m = JSON.parse(r.stdout) as ProgramManifest
      if (m.id === c) return m
    } catch {
      // not a ReflexKit program
    }
  }
  throw new Error(`no ReflexKit program executable found in ${binPath} (product name must equal the manifest id)`)
}

/** Report direct system calls that bypass ReflexKit's guardrails. Returns the number of findings. */
export async function lintProgram(dir: string): Promise<{ file: string; line: number; rule: string; text: string }[]> {
  const rules: [RegExp, string][] = [
    [/\bAXUIElement\w*\s*\(/, 'direct AX API call (use ctx.ax)'],
    [/\bAXObserver\w*\s*\(/, 'direct AXObserver (use ctx.ticks / ctx.watch)'],
    [/\bProcess\s*\(\s*\)|\bposix_spawn|\bNSTask\b|\bsystem\s*\(|\bpopen\s*\(/, 'starts a process'],
    [/\bURLSession\b|\bNWConnection\b|\bNWListener\b|\bsocket\s*\(|\bCFSocket|\bCFStream/, 'network access'],
    [/\bNSAppleScript\b|\bOSAScript\b/, 'AppleScript'],
    [/\bdlopen\s*\(|\bBundle\s*\(\s*path.*\.load\(/, 'dynamic loading'],
    [/\bCGEvent\w*\s*\(/, 'synthesized input events'],
    [/\bprint\s*\(/, 'print() goes to stderr in child mode; prefer ctx.log'],
  ]
  const out: { file: string; line: number; rule: string; text: string }[] = []
  const walkDir = async (d: string): Promise<void> => {
    for (const entry of await listDir(d)) {
      const full = join(d, entry)
      const st = await stat(full)
      if (st.isDirectory()) await walkDir(full)
      else if (entry.endsWith('.swift')) {
        const lines = (await readFile(full, 'utf8')).split('\n')
        lines.forEach((text, i) => {
          if (text.trim().startsWith('//')) return
          for (const [re, rule] of rules) if (re.test(text)) out.push({ file: relative(dir, full), line: i + 1, rule, text: text.trim() })
        })
      }
    }
  }
  await walkDir(join(dir, 'Sources'))
  return out
}

async function printLint(dir: string): Promise<number> {
  const findings = await lintProgram(dir)
  if (findings.length === 0) {
    process.stdout.write('lint: no direct system calls found\n')
    return 0
  }
  process.stdout.write(`lint: ${findings.length} finding(s) — these bypass ReflexKit's guardrails; review before enabling:\n`)
  for (const f of findings) process.stdout.write(`  ${f.file}:${f.line}  [${f.rule}]  ${f.text}\n`)
  return findings.length
}

/** Build (release) and install into `$DSH_HOME/reflex/programs/<id>`. Installed programs start disabled. */
export async function buildAndInstall(paths: ReflexPaths, _packageRoot: string, dir: string, options: { quiet: boolean }): Promise<boolean> {
  if (!(await exists(join(dir, 'Package.swift')))) return false
  const built = await buildProgram(dir, { release: true, quiet: options.quiet })
  const id = built.manifest.id
  const dest = join(paths.programsDir, id)
  await ensurePrivateDir(dest)
  const exe = join(dest, id)
  const staged = `${exe}.${process.pid}.new`
  await copyFile(built.binary, staged)
  await chmod(staged, 0o755)
  await capture('codesign', ['--force', '--timestamp=none', '--sign', '-', staged])
  const { rename } = await import('node:fs/promises')
  await rename(staged, exe)
  await writeJsonAtomic(join(dest, 'manifest.json'), built.manifest)
  const findings = await lintProgram(dir)
  await writeJsonAtomic(join(dest, 'install.json'), {
    source: dir,
    installedAt: new Date().toISOString(),
    sha256: sha256((await readFile(exe)).toString('base64')),
    lint: findings,
  })
  if (!options.quiet) {
    if (findings.length > 0) await printLint(dir)
    process.stdout.write(`installed ${id} ${built.manifest.version} → ${dest}\n默认未启用。在 DSH 里执行 /reflex program enable ${id} 查看并确认它申请的 App 和能力。\n`)
  }
  if ((await helperRunning(paths)) !== undefined) {
    try {
      const client = await connectHelper(paths)
      await client.request('programs.rescan', {})
      client.close()
    } catch {
      // the helper rescans on next start
    }
  }
  return true
}

async function listPrograms(paths: ReflexPaths, json: boolean): Promise<number> {
  let manifests: ProgramManifest[] = []
  if ((await helperRunning(paths)) !== undefined) {
    const client = await connectHelper(paths)
    manifests = (await client.request('programs.list', {})) as unknown as ProgramManifest[]
    client.close()
  } else {
    for (const id of await listDir(paths.programsDir)) {
      if (id.startsWith('_') || id.startsWith('.')) continue
      const m = await readJson<ProgramManifest>(join(paths.programsDir, id, 'manifest.json'))
      if (m !== undefined) manifests.push(m)
    }
  }
  if (json) {
    process.stdout.write(`${JSON.stringify(manifests, null, 2)}\n`)
    return 0
  }
  if (manifests.length === 0) process.stdout.write(`no programs installed in ${paths.programsDir}\n`)
  for (const m of manifests) {
    process.stdout.write(`${m.id} ${m.version} · apps ${m.apps.join(', ')} · capabilities ${m.capabilities.join(', ')} · emits ${m.emits.join(', ') || '-'} · tasks ${m.tasks.join(', ') || '-'}\n`)
  }
  return 0
}

async function devRun(paths: ReflexPaths, id: string | undefined, args: ParsedArgs): Promise<number> {
  if (id === undefined) throw new Error('usage: dsh-reflex program run <id> --dev')
  if (!bool(args, 'dev')) throw new Error('only --dev runs are supported from the CLI')
  await ensureDev(paths)
  const client = await connectHelper(paths, { launch: true })
  client.on('notification', (method, params) => {
    if (method !== 'program.log') return
    const p = params as { program?: string; line?: string }
    if (p.program === id) process.stdout.write(`${p.line}\n`)
  })
  await client.request('programs.devRun', { id, on: true })
  await client.request('logs.subscribe', { program: id })
  process.stdout.write(`dev run ${id}: streaming logs (Ctrl-C to stop). The program must be enabled (/reflex program enable ${id}).\n`)
  await new Promise<void>((resolveStop) => {
    process.once('SIGINT', () => resolveStop())
    client.once('close', () => resolveStop())
  })
  await client.request('programs.devRun', { id, on: false }).catch(() => undefined)
  client.close()
  return 0
}
