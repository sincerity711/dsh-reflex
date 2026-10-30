import Foundation

/// One line of an `ax record` fixture (JSONL).
public enum FixtureLine: Sendable {
  case meta(FixtureMeta)
  /// Running apps changed (launch / terminate).
  case apps(t: Double, apps: [AppInfo])
  /// Full bounded snapshot of one app: a synthetic AXApplication root whose children are windows.
  case tree(t: Double, pid: Int32, root: AXNode)
  case notice(t: Double, pid: Int32, name: String, element: AXNode?)
  /// Probe step label ("minimize the meeting window" …).
  case marker(t: Double, label: String)

  public var time: Double {
    switch self {
    case .meta: return 0
    case .apps(let t, _), .tree(let t, _, _), .notice(let t, _, _, _), .marker(let t, _): return t
    }
  }

  public func line() throws -> String {
    var o: [String: JSON]
    switch self {
    case .meta(let m):
      o = try JSON(encoding: EncodableBox(m)).object ?? [:]
      o["kind"] = "meta"
    case .apps(let t, let apps):
      o = ["kind": "apps", "t": JSON(t), "apps": try JSON(encoding: apps)]
    case .tree(let t, let pid, let root):
      o = ["kind": "tree", "t": JSON(t), "pid": JSON(Int(pid)), "root": try JSON(encoding: root)]
    case .notice(let t, let pid, let name, let element):
      o = ["kind": "notice", "t": JSON(t), "pid": JSON(Int(pid)), "name": .string(name)]
      if let element { o["element"] = try JSON(encoding: element) }
    case .marker(let t, let label):
      o = ["kind": "marker", "t": JSON(t), "label": .string(label)]
    }
    return JSON.object(o).serialized()
  }

  public static func parse(_ text: String) throws -> FixtureLine {
    let json = try JSON.parse(text)
    let t = json["t"]?.double ?? 0
    switch json["kind"]?.string {
    case "meta":
      return .meta(try JSONCoding.decoder.decode(FixtureMeta.self, from: Data(text.utf8)))
    case "apps":
      return .apps(t: t, apps: try (json["apps"] ?? .array([])).decode(as: [AppInfo].self))
    case "tree":
      return .tree(t: t, pid: Int32(json["pid"]?.int ?? 0), root: try (json["root"] ?? .null).decode(as: AXNode.self))
    case "notice":
      let element = try json["element"].map { try $0.decode(as: AXNode.self) }
      return .notice(t: t, pid: Int32(json["pid"]?.int ?? 0), name: json["name"]?.string ?? "", element: element)
    case "marker":
      return .marker(t: t, label: json["label"]?.string ?? "")
    default:
      throw WireError.malformed("unknown fixture line kind")
    }
  }
}

public struct FixtureMeta: Codable, Sendable, Hashable {
  public var version: Int
  public var bundleIds: [String]
  public var startedAt: Date
  public var redaction: RedactionMode
  public var limits: ReadLimits
  public var tool: String
  public var note: String?
  public var appVersions: [String: String]

  public init(bundleIds: [String], startedAt: Date, redaction: RedactionMode, limits: ReadLimits, tool: String, note: String? = nil, appVersions: [String: String] = [:]) {
    self.version = 1
    self.bundleIds = bundleIds
    self.startedAt = startedAt
    self.redaction = redaction
    self.limits = limits
    self.tool = tool
    self.note = note
    self.appVersions = appVersions
  }
}

public struct Fixture: Sendable {
  public var meta: FixtureMeta
  public var lines: [FixtureLine]

  public init(meta: FixtureMeta, lines: [FixtureLine]) {
    self.meta = meta
    self.lines = lines.sorted { $0.time < $1.time }
  }

  public static func load(_ url: URL) throws -> Fixture {
    let text = try String(contentsOf: url, encoding: .utf8)
    var meta: FixtureMeta?
    var lines: [FixtureLine] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = try FixtureLine.parse(String(raw))
      if case .meta(let m) = line { meta = m } else { lines.append(line) }
    }
    guard let meta else { throw WireError.malformed("fixture \(url.path) has no meta line") }
    return Fixture(meta: meta, lines: lines)
  }

  public var duration: Double { lines.last?.time ?? 0 }

  public var markers: [(t: Double, label: String)] {
    lines.compactMap { if case .marker(let t, let l) = $0 { return (t, l) } else { return nil } }
  }
}

/// Clock bound to a replay: sleeping advances the fixture.
final class ReplayClock: ReflexClock, @unchecked Sendable {
  private weak var replay: ReplayAX?
  private let fallback: VirtualClock

  init(_ replay: ReplayAX) {
    self.replay = replay
    self.fallback = replay.virtualClock
  }

  func now() -> Date { fallback.now() }
  var isVirtual: Bool { true }

  func sleep(until date: Date) async throws {
    try Task.checkCancellation()
    if let replay { replay.advance(to: date) } else { fallback.advance(to: date) }
  }
}

/// Replays a recorded fixture as an `AXSource` on virtual time.
///
/// The state at virtual time `t` is the latest `tree` line (per pid) and `apps` line with time <= t.
/// Notices are delivered to subscribers when `advance(to:)` passes their time.
public final class ReplayAX: AXSource, @unchecked Sendable {
  public let fixture: Fixture
  public let virtualClock: VirtualClock
  /// Clock whose `sleep` advances the replay (applies tree lines, delivers notices).
  public private(set) lazy var clock: ReflexClock = ReplayClock(self)
  private let state = Locked(ReplayState())
  /// Actions performed through this source, for assertions.
  public let performed = Locked([(at: Double, action: String, target: String)]())

  struct ReplayState {
    var cursor = 0
    var lastAdvance: Double = -1
    var trees: [Int32: AXNode] = [:]
    var apps: [AppInfo] = []
    var subscriptions: [UInt64: (pid: Int32, names: Set<String>, handler: @Sendable (AXNotice) -> Void)] = [:]
    var nextSub: UInt64 = 0
    var attributes: [Int32: [String: Bool]] = [:]
    var stats = AXStats()
  }

  public init(fixture: Fixture) {
    self.fixture = fixture
    self.virtualClock = VirtualClock(start: fixture.meta.startedAt)
    advance(to: fixture.meta.startedAt)
  }

  public convenience init(url: URL) throws {
    self.init(fixture: try Fixture.load(url))
  }

  public var startedAt: Date { fixture.meta.startedAt }
  public var endTime: Date { startedAt.addingTimeInterval(fixture.duration) }

  /// Seconds since the start of the recording.
  public var elapsed: Double { virtualClock.now().timeIntervalSince(startedAt) }

  public func date(at seconds: Double) -> Date { startedAt.addingTimeInterval(seconds) }

  /// Move virtual time forward, applying tree/app lines and delivering notices up to `date`.
  public func advance(to date: Date) {
    virtualClock.advance(to: date)
    let target = date.timeIntervalSince(startedAt)
    var deliveries: [(@Sendable (AXNotice) -> Void, AXNotice)] = []
    state.withLock { s in
      while s.cursor < fixture.lines.count, fixture.lines[s.cursor].time <= target {
        let line = fixture.lines[s.cursor]
        s.cursor += 1
        switch line {
        case .tree(_, let pid, let root): s.trees[pid] = root
        case .apps(_, let apps):
          s.apps = apps
          let live = Set(apps.map(\.pid))
          s.trees = s.trees.filter { live.contains($0.key) }
        case .notice(let t, let pid, let name, let element):
          for sub in s.subscriptions.values where sub.names.contains(name) && (sub.pid == pid || sub.pid == -1) {
            deliveries.append((sub.handler, AXNotice(name: name, pid: pid, at: startedAt.addingTimeInterval(t), element: element)))
          }
        case .marker, .meta: break
        }
      }
      s.lastAdvance = target
    }
    for (handler, notice) in deliveries { handler(notice) }
  }

  /// Time of the next notice for `pids` (nil = any) and `names` strictly after `date`.
  public func nextNotice(after date: Date, pids: Set<Int32>?, names: Set<String>) -> Date? {
    let after = date.timeIntervalSince(startedAt)
    for line in fixture.lines where line.time > after {
      if case .notice(let t, let pid, let name, _) = line, names.contains(name), pids?.contains(pid) ?? true {
        return startedAt.addingTimeInterval(t)
      }
    }
    return nil
  }

  /// Time of the next tree/apps change strictly after `date`.
  public func nextChange(after date: Date) -> Date? {
    let after = date.timeIntervalSince(startedAt)
    for line in fixture.lines where line.time > after {
      switch line {
      case .tree, .apps: return startedAt.addingTimeInterval(line.time)
      default: continue
      }
    }
    return nil
  }

  // MARK: AXSource

  public func isTrusted() -> Bool { true }

  public func runningApps(_ bundleIds: Set<String>) -> [AppInfo] {
    state.withLock { s in
      let apps = s.apps.isEmpty ? inferredApps(s) : s.apps
      return apps.filter { bundleIds.contains($0.bundleId) }
    }
  }

  private func inferredApps(_ s: ReplayState) -> [AppInfo] {
    // Fixtures without `apps` lines: every pid with a tree is a running app of the first bundle id.
    s.trees.keys.sorted().map { pid in
      AppInfo(pid: pid, bundleId: fixture.meta.bundleIds.first ?? "unknown", name: s.trees[pid]?.title ?? "app")
    }
  }

  public func appRef(_ app: AppInfo) -> AXRef { AXRef(replayPid: app.pid, path: [], key: nil) }

  public func windows(_ app: AppInfo) throws -> [AXRef] {
    count()
    guard let root = state.withLock({ $0.trees[app.pid] }) else { return [] }
    return root.children.enumerated().map { i, w in AXRef(replayPid: app.pid, path: [i], key: ReplayAX.key(w)) }
  }

  public func read(_ ref: AXRef, _ limits: ReadLimits) throws -> AXNode {
    count()
    guard let (node, path) = resolve(ref) else { throw ReflexError.elementGone }
    var remaining = max(1, limits.maxNodes)
    func copy(_ n: AXNode, path: [Int], depth: Int) -> AXNode {
      remaining -= 1
      var out = n
      out.ref = AXRef(replayPid: ref.pid, path: path, key: ReplayAX.key(n))
      out.title = n.title.map { truncate($0, limits.maxTextLength) }
      out.value = n.value.map { truncate($0, limits.maxTextLength) }
      out.desc = n.desc.map { truncate($0, limits.maxTextLength) }
      out.children = []
      if !n.children.isEmpty {
        if depth >= limits.maxDepth || remaining <= 0 {
          out.omittedChildren = n.children.count
        } else {
          let indices = limits.tailFirst == true ? Array(n.children.indices.reversed()) : Array(n.children.indices)
          for (visited, i) in indices.enumerated() {
            if remaining <= 0 {
              out.omittedChildren = n.children.count - visited
              break
            }
            out.children.append(copy(n.children[i], path: path + [i], depth: depth + 1))
          }
          if limits.tailFirst == true { out.children.reverse() }
        }
      }
      return out
    }
    return copy(node, path: path, depth: 0)
  }

  public func find(in ref: AXRef, _ query: AXQuery, _ limits: FindLimits) throws -> [AXNode] {
    count()
    guard let (root, rootPath) = resolve(ref) else { return [] }
    var out: [AXNode] = []
    var visited = 0
    func walk(_ n: AXNode, _ path: [Int], _ depth: Int) {
      guard out.count < limits.maxMatches, visited < limits.maxNodes else { return }
      visited += 1
      if query.matches(n) {
        var shallow = n
        shallow.children = []
        shallow.ref = AXRef(replayPid: ref.pid, path: path, key: ReplayAX.key(n))
        out.append(shallow)
      }
      guard depth < limits.maxDepth else { return }
      for (i, c) in n.children.enumerated() { walk(c, path + [i], depth + 1) }
    }
    walk(root, rootPath, 0)
    return out
  }

  public func parent(of ref: AXRef) throws -> AXRef? {
    count()
    guard let (_, path) = resolve(ref) else { throw ReflexError.elementGone }
    guard !path.isEmpty else { return nil }
    let parentPath = Array(path.dropLast())
    guard let root = state.withLock({ $0.trees[ref.pid] }) else { throw ReflexError.elementGone }
    var node = root
    for i in parentPath { node = node.children[i] }
    return AXRef(replayPid: ref.pid, path: parentPath, key: ReplayAX.key(node))
  }

  public func subscribe(pid: Int32, notifications: [String], handler: @escaping @Sendable (AXNotice) -> Void) throws -> AXSubscription {
    let id = state.withLock { s -> UInt64 in
      s.nextSub += 1
      s.subscriptions[s.nextSub] = (pid, Set(notifications), handler)
      return s.nextSub
    }
    return AXSubscription { [weak self] in
      self?.state.withLock { _ = $0.subscriptions.removeValue(forKey: id) }
    }
  }

  public func getBool(_ ref: AXRef, _ attribute: String) -> Bool? {
    state.withLock { $0.attributes[ref.pid]?[attribute] }
  }

  @discardableResult
  public func setBool(_ ref: AXRef, _ attribute: String, _ value: Bool) -> AXResult {
    state.withLock { $0.attributes[ref.pid, default: [:]][attribute] = value }
    return .success
  }

  public func perform(_ ref: AXRef, _ action: String) throws {
    let target = (try? read(ref, ReadLimits(maxDepth: 0, maxNodes: 1)))?.label ?? "\(ref)"
    performed.withLock { $0.append((elapsed, action, target)) }
  }

  public func stats() -> AXStats { state.withLock { $0.stats } }

  public func shutdown() {
    state.withLock { $0.subscriptions.removeAll() }
  }

  // MARK: helpers

  private func count() { state.withLock { $0.stats.calls += 1 } }

  private func truncate(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "…" : s
  }

  /// Identity key for a node: Chromium node id, else DOM id.
  static func key(_ n: AXNode) -> String? {
    if let c = n.chromeId { return "c:\(c)" }
    if let d = n.domId, !d.isEmpty { return "d:\(d)" }
    return nil
  }

  /// Find the node a ref points to in the current tree: by identity key first, then by path.
  private func resolve(_ ref: AXRef) -> (AXNode, [Int])? {
    guard let root = state.withLock({ $0.trees[ref.pid] }) else { return nil }
    let path = ref.replayPath ?? []
    if let key = ref.replayKey {
      var matches: [(AXNode, [Int])] = []
      func walk(_ n: AXNode, _ p: [Int]) {
        if ReplayAX.key(n) == key { matches.append((n, p)) }
        for (i, c) in n.children.enumerated() { walk(c, p + [i]) }
      }
      walk(root, [])
      if matches.count == 1 { return matches[0] }
      if let exact = matches.first(where: { $0.1 == path }) { return exact }
      if let first = matches.first { return first }
      return nil
    }
    var node = root
    for i in path {
      guard node.children.indices.contains(i) else { return nil }
      node = node.children[i]
    }
    return (node, path)
  }
}
