import Foundation

/// What a program may do. ReflexKit refuses calls that the manifest does not declare.
public enum Capability: String, Codable, Hashable, Sendable, CaseIterable {
  /// Read AX trees and subscribe to AX notifications of the declared apps.
  case read
  /// Switch on Chromium/WebView accessibility (AXEnhancedUserInterface / AXManualAccessibility).
  case prepareWeb
  /// Perform AX actions. Only the actions listed in `Manifest.actions` and confirmed by the user.
  case perform
}

/// A UI action a program wants to perform. Declared in the manifest, confirmed by the user, audited.
public struct ActionDecl: Codable, Hashable, Sendable {
  public var id: String
  public var description: String

  public init(_ id: String, _ description: String) {
    self.id = id
    self.description = description
  }
}

/// Static description of a program. Exported with `<binary> --manifest` at install time.
public struct Manifest: Codable, Hashable, Sendable {
  public var id: String
  public var version: String
  public var description: String
  /// Bundle identifiers the program reads. The helper only starts it while one of them runs.
  public var apps: [String]
  public var capabilities: [Capability]
  public var actions: [ActionDecl]
  /// Event types the program emits (dotted names, e.g. `teams.meeting.started`).
  public var emits: [String]
  /// Task names the program implements.
  public var tasks: [String]
  /// Default config; the user's config is merged over it.
  public var config: [String: JSON]
  /// Protocol version of the ReflexKit runtime the program was built with.
  public var protocolVersion: Int
  /// Seconds without loop progress after which the helper considers the program stuck.
  public var stallTimeoutSec: Int
  /// Seconds the program keeps running after its apps quit (so it can emit "ended" events).
  public var lingerSec: Int

  public init(
    id: String,
    version: String = "0.1.0",
    description: String = "",
    apps: [String],
    capabilities: [Capability] = [.read],
    actions: [ActionDecl] = [],
    emits: [String] = [],
    tasks: [String] = [],
    config: [String: JSON] = [:],
    stallTimeoutSec: Int = 90,
    lingerSec: Int = 30
  ) {
    self.id = id
    self.version = version
    self.description = description
    self.apps = apps
    self.capabilities = capabilities
    self.actions = actions
    self.emits = emits
    self.tasks = tasks
    self.config = config
    self.protocolVersion = ReflexProtocol.version
    self.stallTimeoutSec = stallTimeoutSec
    self.lingerSec = lingerSec
  }

  enum CodingKeys: String, CodingKey {
    case id, version, description, apps, capabilities, actions, emits, tasks, config, protocolVersion, stallTimeoutSec, lingerSec
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
    description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
    capabilities = try c.decodeIfPresent([Capability].self, forKey: .capabilities) ?? []
    actions = try c.decodeIfPresent([ActionDecl].self, forKey: .actions) ?? []
    emits = try c.decodeIfPresent([String].self, forKey: .emits) ?? []
    tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
    config = try c.decodeIfPresent([String: JSON].self, forKey: .config) ?? [:]
    protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
    stallTimeoutSec = try c.decodeIfPresent(Int.self, forKey: .stallTimeoutSec) ?? 90
    lingerSec = try c.decodeIfPresent(Int.self, forKey: .lingerSec) ?? 30
  }

  /// Validate the manifest shape; returns human-readable problems.
  public func problems() -> [String] {
    var out: [String] = []
    let idPattern = #"^[a-z][a-z0-9-]{0,39}$"#
    if id.range(of: idPattern, options: .regularExpression) == nil {
      out.append("id must match \(idPattern)")
    }
    if apps.isEmpty { out.append("apps must list at least one bundle id") }
    for e in emits where e.range(of: #"^[a-z][a-z0-9_-]*(\.[a-z0-9_-]+)+$"#, options: .regularExpression) == nil {
      out.append("event type \(e) must be dotted lowercase (e.g. app.thing.happened)")
    }
    for e in emits where !e.hasPrefix(id + ".") {
      out.append("event type \(e) must start with \(id).")
    }
    if !actions.isEmpty && !capabilities.contains(.perform) {
      out.append("actions are declared but capability .perform is missing")
    }
    if Set(tasks).count != tasks.count { out.append("duplicate task names") }
    return out
  }
}

public enum ReflexProtocol {
  /// Version of the helper <-> program JSON-lines protocol.
  public static let version = 1
}
