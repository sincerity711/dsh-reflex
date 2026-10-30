/** Tiny argv parser: positionals, `--flag value`, `--flag=value`, repeated flags, booleans. */

export interface ParsedArgs {
  readonly positionals: string[]
  readonly flags: Map<string, string[]>
}

const BOOLEAN_FLAGS = new Set(['json', 'all', 'debug', 'dev', 'force', 'help', 'no-install', 'follow', 'yes', 'no-redact', 'release', 'speak', 'auto', 'script-only'])

export function parseArgs(argv: readonly string[]): ParsedArgs {
  const positionals: string[] = []
  const flags = new Map<string, string[]>()
  const add = (k: string, v: string): void => {
    const list = flags.get(k) ?? []
    list.push(v)
    flags.set(k, list)
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!
    if (a === '--') {
      positionals.push(...argv.slice(i + 1))
      break
    }
    if (a.startsWith('--')) {
      const eq = a.indexOf('=')
      if (eq > 0) {
        add(a.slice(2, eq), a.slice(eq + 1))
        continue
      }
      const key = a.slice(2)
      const next = argv[i + 1]
      if (BOOLEAN_FLAGS.has(key) || next === undefined || next.startsWith('--')) {
        add(key, 'true')
      } else {
        add(key, next)
        i += 1
      }
      continue
    }
    positionals.push(a)
  }
  return { positionals, flags }
}

export function flag(args: ParsedArgs, name: string): string | undefined {
  const v = args.flags.get(name)
  return v === undefined ? undefined : v[v.length - 1]
}

export function flags(args: ParsedArgs, name: string): string[] {
  return args.flags.get(name) ?? []
}

export function bool(args: ParsedArgs, name: string): boolean {
  const v = flag(args, name)
  return v !== undefined && v !== 'false' && v !== '0'
}

export function num(args: ParsedArgs, name: string, fallback: number): number {
  const v = flag(args, name)
  if (v === undefined) return fallback
  const n = Number(v)
  if (!Number.isFinite(n)) throw new Error(`--${name} must be a number`)
  return n
}
