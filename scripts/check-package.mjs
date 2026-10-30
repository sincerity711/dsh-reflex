// Check the real tarball, including files needed by SwiftPM and the DSH loader.
import { execFileSync } from 'node:child_process'
import assert from 'node:assert/strict'
const archive = process.argv[2]
assert(archive, 'Pass the npm tarball path')
const entries = execFileSync('tar', ['-tzf', archive], { encoding: 'utf8' }).trim().split('\n')
for (const path of [
  'lib/index.js', 'lib/index.d.ts', 'lib/client.js', 'lib/cli/dsh-reflex.js', 'lib/setup.js',
  'assets/Reflex.icns', 'cordis.patch.yml', 'scripts/build-helper.sh', 'scripts/bundle-app.sh', 'scripts/setup-local-signing.sh',
  'swift/Package.swift', 'swift/Sources/ReflexVirtualDisplayBridge/LICENSE.txt',
  'programs/teams/Sources/Teams/Program.swift', 'programs/browser/Sources/Browser/Program.swift',
  'programs/teams/Tests/TeamsTests/TeamsTests.swift', 'programs/browser/Tests/BrowserTests/BrowserTests.swift',
  'programs/teams/Package.swift', 'programs/browser/Package.swift', 'examples/rules/teams-meeting-summary.yaml',
]) assert(entries.includes(`package/${path}`), `Missing ${path}`)
assert(!entries.some(p => /\/(?:node_modules|\.build|\.codegraph)\//.test(p)), 'Private/build files in package')
const pkg = JSON.parse(execFileSync('tar', ['-xOzf', archive, 'package/package.json'], { encoding: 'utf8' }))
assert.equal(pkg.name, '@sincerity711/dsh-reflex')
assert.equal(pkg.dsh.bundle.patch, './cordis.patch.yml')
assert(pkg.keywords.includes('dsh-plugin'))
const patch = execFileSync('tar', ['-xOzf', archive, 'package/cordis.patch.yml'], { encoding: 'utf8' })
assert(patch.includes("name: '@sincerity711/dsh-reflex'"), 'Bundle must resolve the published package')
assert(!entries.some(p => /^package\/docs\/(?:superpowers\/|PLAN\.md$|VERIFIED\.md$|PERF\.md$)/.test(p)), 'Development records must not be published')
const contents = execFileSync('tar', ['-xOzf', archive], { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 })
assert(!/\/Users\/[A-Za-z0-9_.-]+\//.test(contents), 'A local user path leaked into the package')
console.log(`Validated ${pkg.name}@${pkg.version}: ${entries.length} package entries`)
