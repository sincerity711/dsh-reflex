import Foundation
import ReflexKit

/// Filesystem layout shared with the DSH plugin (see docs/PROTOCOL.md).
public struct HelperPaths: Sendable {
  public let dshHome: URL
  public let reflexRoot: URL

  public init(dshHome: URL) {
    self.dshHome = dshHome
    self.reflexRoot = dshHome.appendingPathComponent("reflex", isDirectory: true)
  }

  /// `$DSH_HOME`, else `~/.dsh`.
  public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let h = environment["DSH_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
  }

  public var runDir: URL { reflexRoot.appendingPathComponent("run", isDirectory: true) }
  public var tokenFile: URL { runDir.appendingPathComponent("helper.token") }
  public var infoFile: URL { runDir.appendingPathComponent("helper.json") }
  public var lockFile: URL { runDir.appendingPathComponent("helper.lock") }
  public var programsDir: URL { reflexRoot.appendingPathComponent("programs", isDirectory: true) }
  public var stateDir: URL { reflexRoot.appendingPathComponent("helper", isDirectory: true) }
  public var logsDir: URL { reflexRoot.appendingPathComponent("logs", isDirectory: true) }
  public var dataDir: URL { reflexRoot.appendingPathComponent("data", isDirectory: true) }
  public var devModeFile: URL { reflexRoot.appendingPathComponent("dev-mode") }
  public var configFile: URL { reflexRoot.appendingPathComponent("helper-config.json") }

  /// `<reflex>/run/helper.sock`, or a short path under the per-user temp dir when that is too long
  /// for `sun_path` (104 bytes on macOS).
  public var socketPath: String {
    let primary = runDir.appendingPathComponent("helper.sock").path
    if primary.utf8.count <= 100 { return primary }
    return HelperPaths.userTempDir()
      .appendingPathComponent("dsh-reflex-\(FNV1a64.hash(reflexRoot.path).prefix(12))", isDirectory: true)
      .appendingPathComponent("helper.sock").path
  }

  public static func userTempDir() -> URL {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
      return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  }

  /// Create private directories (0700).
  public func prepare() throws {
    for dir in [reflexRoot, runDir, programsDir, stateDir, logsDir, dataDir,
                URL(fileURLWithPath: socketPath).deletingLastPathComponent()]
    {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      chmod(dir.path, 0o700)
    }
  }

  /// Dev mode is on while `<reflex>/dev-mode` exists and its expiry (ISO date inside) is in the future.
  public var devModeActive: Bool {
    guard let text = try? String(contentsOf: devModeFile, encoding: .utf8) else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    guard let until = ISO8601.parse(trimmed) else { return true }
    return until > Date()
  }
}
