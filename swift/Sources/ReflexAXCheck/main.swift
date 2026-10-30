import ApplicationServices
import Foundation
import ReflexKit

// Diagnostic child: started by the helper (posix_spawn, not LaunchServices) to check whether a
// child process inherits the helper's Accessibility grant, and to re-check the grant without the
// in-process cache that AXIsProcessTrusted() has in long-running processes.
//
// usage: reflex-axcheck [bundleId ...]

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

func responsiblePid(_ pid: pid_t) -> pid_t? {
  guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
  let fn = unsafeBitCast(sym, to: ResponsibleFn.self)
  let r = fn(pid)
  return r > 0 ? r : nil
}

let bundleIds = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["com.microsoft.teams2"]
var result = ProgramRuntime.selftest(Manifest(id: "axcheck", apps: bundleIds)).object ?? [:]
result["responsiblePid"] = responsiblePid(getpid()).map { JSON(Int($0)) } ?? .null
result["executable"] = .string(CommandLine.arguments[0])
print(JSON.object(result).serialized())
