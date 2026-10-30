import Foundation

/// Where a program's messages go: the helper (stdout JSON lines) or a test collector.
public protocol ProgramSink: AnyObject, Sendable {
  func send(_ message: OutboundMessage)
}

/// Stop request shared by a context and the sequences created from it.
public final class StopController: @unchecked Sendable {
  private let lock = NSLock()
  private var _reason: StopReason?
  private var signals: [WeakSignal] = []
  private let parent: StopController?

  private struct WeakSignal { weak var signal: WakeSignal? }

  init(parent: StopController? = nil) { self.parent = parent }

  public var reason: StopReason? {
    lock.lock(); defer { lock.unlock() }
    return _reason ?? parent?.reason
  }

  public var isStopped: Bool { reason != nil }

  public func request(_ reason: StopReason) {
    lock.lock()
    if _reason == nil { _reason = reason }
    let targets = signals.compactMap(\.signal)
    lock.unlock()
    for s in targets { s.fire() }
  }

  func register(_ signal: WakeSignal) {
    lock.lock()
    signals.removeAll { $0.signal == nil }
    signals.append(WeakSignal(signal: signal))
    lock.unlock()
    parent?.register(signal)
  }
}

/// Small persistent key/value store (atomic JSON file).
public final class Checkpoint: @unchecked Sendable {
  public let url: URL
  private let values: Locked<[String: JSON]>

  init(url: URL) {
    self.url = url
    let loaded = (try? JSON.parse(Data(contentsOf: url)))?.object ?? [:]
    self.values = Locked(loaded)
  }

  public subscript(key: String) -> JSON? {
    get { values.withLock { $0[key] } }
    set { values.withLock { $0[key] = newValue } }
  }

  public var isEmpty: Bool { values.withLock { $0.isEmpty } }

  /// Persist the current values.
  public func save() throws {
    let snapshot = values.current
    try AtomicFile.write(Data(JSON.object(snapshot).serialized().utf8), to: url)
  }

  /// Store a Codable value under `key` and persist.
  public func save<T: Encodable>(_ value: T, as key: String = "state") throws {
    let data = try JSONCoding.encoder.encode(value)
    values.withLock { $0[key] = try? JSON.parse(data) }
    try save()
  }

  public func load<T: Decodable>(_ type: T.Type, from key: String = "state") -> T? {
    guard let json = self[key] else { return nil }
    return try? JSONCoding.decoder.decode(T.self, from: Data(json.serialized().utf8))
  }
}

/// Health of one tick loop, reported in pongs so the helper can detect stalls.
final class LoopTracker: @unchecked Sendable {
  let name: String
  let interval: Double
  private let lock = NSLock()
  private var ticks = 0
  private var lastTickAt: Date?
  private var waiting = true
  private var handlerStart: Date?
  private var totalHandler: Double = 0
  private var maxHandler: Double = 0

  init(name: String, interval: Double) {
    self.name = name
    self.interval = interval
  }

  /// Called when the consumer asks for the next tick (handler finished).
  func beginWait() {
    lock.lock(); defer { lock.unlock() }
    if let s = handlerStart {
      let d = Date().timeIntervalSince(s) * 1000
      totalHandler += d
      maxHandler = max(maxHandler, d)
      handlerStart = nil
    }
    waiting = true
  }

  /// Called when a tick is delivered to the consumer.
  func delivered(at: Date) {
    lock.lock(); defer { lock.unlock() }
    ticks += 1
    lastTickAt = at
    waiting = false
    handlerStart = Date()
  }

  func health() -> LoopHealth {
    lock.lock(); defer { lock.unlock() }
    let stalled = waiting ? 0 : Date().timeIntervalSince(handlerStart ?? Date())
    return LoopHealth(name: name, ticks: ticks, lastTickAt: lastTickAt, stalledSec: stalled,
                      avgHandlerMs: ticks > 0 ? totalHandler / Double(ticks) : 0, maxHandlerMs: maxHandler)
  }
}

/// Shared runtime state of one program process.
final class RuntimeCore: @unchecked Sendable {
  let manifest: Manifest
  let source: AXSource
  let sink: ProgramSink
  let config: Locked<[String: JSON]>
  let grantedActions: Set<String>
  let commands = Locked([ProgramCommand]())
  let shutdown = StopController()
  let loops = Locked([String: LoopTracker]())
  let knownPids = Locked(Set<Int32>())
  let webLedger = Locked([Int32: Date]())
  let eventStats = Locked((count: 0, latencyMs: 0.0))
  let dev: Bool

  init(manifest: Manifest, source: AXSource, sink: ProgramSink, config: [String: JSON], grantedActions: Set<String>, dev: Bool) {
    self.manifest = manifest
    self.source = source
    self.sink = sink
    self.config = Locked(manifest.config.merging(config) { _, new in new })
    self.grantedActions = grantedActions
    self.dev = dev
  }

  func tracker(_ name: String, interval: Double) -> LoopTracker {
    loops.withLock { map in
      if let t = map[name] { return t }
      let t = LoopTracker(name: name, interval: interval)
      map[name] = t
      return t
    }
  }

  func metrics() -> ProgramMetrics {
    let ax = source.stats()
    let ev = eventStats.current
    let loops = self.loops.withLock { $0.values.map { $0.health() } }.sorted { $0.name < $1.name }
    return ProgramMetrics(axCalls: ax.calls, axMillis: ax.millis, axErrors: ax.errors, eventsEmitted: ev.count,
                          avgEventLatencyMs: ev.count > 0 ? ev.latencyMs / Double(ev.count) : 0, loops: loops)
  }
}

/// Context of the resident `watch` loop. Tasks get a `TaskContext` (a subclass).
public class ProgramContext: @unchecked Sendable {
  let core: RuntimeCore
  let stop: StopController
  /// Virtual time at which sequences end (replay tests only).
  var stopAt: Date?
  var stopAtReason: StopReason = .stopOn

  public let ax: GuardedAX
  public let dataDir: URL
  public let log: ProgramLog
  public private(set) lazy var checkpoint = Checkpoint(url: checkpointURL)

  var checkpointURL: URL { dataDir.appendingPathComponent("checkpoint.json") }

  init(core: RuntimeCore, dataDir: URL, stop: StopController) {
    self.core = core
    self.dataDir = dataDir
    self.stop = stop
    self.ax = GuardedAX(core: core)
    self.log = ProgramLog(sink: core.sink)
  }

  public var manifest: Manifest { core.manifest }
  public var clock: ReflexClock { core.source.clock }
  public var now: Date { core.source.clock.now() }
  public var config: [String: JSON] { core.config.current }
  public var isStopping: Bool { stop.isStopped }
  public var stopReason: StopReason? { stop.reason }
  public var isDev: Bool { core.dev }

  public func int(_ key: String, _ fallback: Int) -> Int { config[key]?.int ?? fallback }
  public func double(_ key: String, _ fallback: Double) -> Double { config[key]?.double ?? fallback }
  public func string(_ key: String, _ fallback: String) -> String { config[key]?.string ?? fallback }
  public func bool(_ key: String, _ fallback: Bool) -> Bool { config[key]?.bool ?? fallback }
  public func strings(_ key: String, _ fallback: [String]) -> [String] {
    config[key]?.array?.compactMap(\.string) ?? fallback
  }

  /// Emit a business event. The type must be declared in `manifest.emits`.
  public func emit(_ event: ProgramEvent) throws {
    guard manifest.emits.contains(event.eventType) else { throw ReflexError.eventNotDeclared(event.eventType) }
    let latency = max(0, now.timeIntervalSince(event.observedAt) * 1000)
    core.eventStats.withLock {
      $0.count += 1
      $0.latencyMs += latency
    }
    core.sink.send(.event(event))
  }

  /// Drain on the resident loop so commands and scans share one state writer.
  public func takeCommands() -> [ProgramCommand] {
    core.commands.withLock { items in defer { items.removeAll() }; return items }
  }
  public func reply(_ result: ProgramCommandResult) { core.sink.send(.commandResult(result)) }

  /// Publish program status (shown by `/reflex status`). Keep it small.
  public func setStatus(_ status: [String: JSON]) {
    core.sink.send(.status(status))
  }

  /// Sleep on the program clock (virtual in replay tests). Returns early when stopping.
  public func sleep(for duration: Duration) async throws {
    if stop.isStopped { return }
    if clock.isVirtual {
      try await clock.sleep(for: duration)
      return
    }
    let signal = WakeSignal()
    stop.register(signal)
    _ = await signal.wait(until: Date().addingTimeInterval(duration.seconds))
  }

  /// A tick loop: fires every `every`, immediately (after `debounce`) on any of `notifications`
  /// from the declared apps' processes, and when a declared app launches or quits.
  public func ticks(_ name: String, every: Duration, notifications: [String] = [], debounce: Duration = .milliseconds(200)) -> Ticks {
    Ticks(ctx: self, name: name, interval: every.seconds, notifications: Set(notifications), debounce: debounce.seconds)
  }

  /// Watch a located subtree: yields when its content hash changes (or presence changes),
  /// and every `idleEvery` without change (so callers can time out stable state).
  public func watch(
    _ name: String, every: Duration, notifications: [String] = [], debounce: Duration = .milliseconds(150),
    idleEvery: Duration? = nil, locate: @escaping () throws -> AXNode?
  ) -> Watch {
    Watch(ticks: ticks(name, every: every, notifications: notifications, debounce: debounce),
          idleEvery: idleEvery?.seconds, locate: locate)
  }
}

/// Context of one task run.
public final class TaskContext: ProgramContext, @unchecked Sendable {
  public let taskId: String
  public let task: String
  public let input: JSON
  /// The task directory (raw data, checkpoints, results). Program may write only here and in dataDir.
  public let dir: URL
  /// True when the task is restarted after a program/helper restart: load the checkpoint, record a gap.
  public let isResume: Bool

  init(core: RuntimeCore, dataDir: URL, start: TaskStartMessage, stop: StopController) {
    self.taskId = start.taskId
    self.task = start.task
    self.input = start.input
    self.dir = URL(fileURLWithPath: start.dir, isDirectory: true)
    self.isResume = start.resume
    super.init(core: core, dataDir: dataDir, stop: stop)
  }

  override var checkpointURL: URL { dir.appendingPathComponent("checkpoint.json") }

  public func progress(_ progress: JSON) {
    core.sink.send(.taskProgress(taskId: taskId, progress: progress))
  }

  /// URL of a file inside the task directory. Rejects paths escaping it.
  public func file(_ name: String) throws -> URL {
    let url = dir.appendingPathComponent(name).standardizedFileURL
    guard url.path.hasPrefix(dir.standardizedFileURL.path + "/") else { throw ReflexError.pathOutsideAllowedDirs(name) }
    return url
  }

  public func write(_ name: String, _ text: String) throws {
    try AtomicFile.write(Data(text.utf8), to: try file(name))
  }

  public func writeJSON<T: Encodable>(_ name: String, _ value: T) throws {
    try AtomicFile.writeJSON(value, to: try file(name))
  }

  private var appenders: [String: LineAppender] = [:]
  private let appendLock = NSLock()

  /// Append one line to a file in the task directory (JSONL logs).
  public func append(_ name: String, line: String) throws {
    let url = try file(name)
    appendLock.lock()
    let appender = appenders[name] ?? LineAppender(url: url)
    appenders[name] = appender
    appendLock.unlock()
    try appender.append(line)
  }

  func closeFiles() {
    appendLock.lock()
    for a in appenders.values { a.close() }
    appenders.removeAll()
    appendLock.unlock()
  }
}

/// Logging to the helper (never print to stdout in a program).
public final class ProgramLog: @unchecked Sendable {
  private let sink: ProgramSink

  init(sink: ProgramSink) { self.sink = sink }

  public func debug(_ message: String, _ fields: [String: JSON] = [:]) { sink.send(.log(level: "debug", message: message, fields: fields)) }
  public func info(_ message: String, _ fields: [String: JSON] = [:]) { sink.send(.log(level: "info", message: message, fields: fields)) }
  public func warn(_ message: String, _ fields: [String: JSON] = [:]) { sink.send(.log(level: "warn", message: message, fields: fields)) }
  public func error(_ message: String, _ fields: [String: JSON] = [:]) { sink.send(.log(level: "error", message: message, fields: fields)) }
}

public enum PrepareWebResult: String, Sendable, Codable {
  /// DOM ids are visible: web content is in the AX tree.
  case awake
  /// Switches were set but no DOM id appeared within the verification window.
  case notAwake
  /// Skipped: the pid was poked recently (TTL) and is still not awake.
  case coolingDown
}

/// The program's view of Accessibility: only declared apps, declared capabilities, granted actions.
public final class GuardedAX: @unchecked Sendable {
  let core: RuntimeCore

  init(core: RuntimeCore) { self.core = core }

  var source: AXSource { core.source }

  public var isTrusted: Bool { source.isTrusted() }

  /// Running instances of the manifest's apps.
  public func apps() -> [AppInfo] { source.runningApps(Set(core.manifest.apps)) }

  public func appRef(_ app: AppInfo) throws -> AXRef {
    try requireApp(app)
    return source.appRef(app)
  }

  public func windows(_ app: AppInfo) throws -> [AXRef] {
    try requireApp(app)
    return try source.windows(app)
  }

  /// Shallow window snapshots: role, subrole, title, minimized.
  public func windowNodes(_ app: AppInfo) throws -> [AXNode] {
    try requireApp(app)
    return try source.windowList(app)
  }

  public func read(_ ref: AXRef, _ limits: ReadLimits = ReadLimits()) throws -> AXNode {
    try requireRead()
    let node = try source.read(ref, limits)
    notePids(node)
    return node
  }

  /// Bounded snapshot of all windows of an app.
  public func readApp(_ app: AppInfo, _ limits: ReadLimits = ReadLimits()) throws -> AXNode {
    try requireApp(app)
    try requireRead()
    let node = try source.readApp(app, limits)
    notePids(node)
    return node
  }

  public func find(_ query: AXQuery, in ref: AXRef, _ limits: FindLimits = .first) throws -> AXNode? {
    try requireRead()
    return try source.find(in: ref, query, limits).first
  }

  public func findAll(_ query: AXQuery, in ref: AXRef, _ limits: FindLimits = .all()) throws -> [AXNode] {
    try requireRead()
    return try source.find(in: ref, query, limits)
  }

  public func parent(of ref: AXRef) throws -> AXRef? {
    try requireRead()
    return try source.parent(of: ref)
  }

  /// Switch on web accessibility for a Chromium/WebView app, at most once per `ttl` per pid,
  /// then wait up to `verifyWithin` for DOM ids to appear. Return codes of the setters are ignored
  /// on purpose: Chromium wakes on the attempt even when it reports failure.
  public func prepareWeb(_ app: AppInfo, ttl: Duration = .seconds(60), verifyWithin: Duration = .seconds(3)) async throws -> PrepareWebResult {
    try requireApp(app)
    guard core.manifest.capabilities.contains(.prepareWeb) else { throw ReflexError.capabilityMissing(.prepareWeb) }
    let root = source.appRef(app)
    if try source.find(in: root, .hasDomId, FindLimits(maxNodes: 4000, timeBudget: 1.0)).first != nil { return .awake }
    let now = source.clock.now()
    let allowed = core.webLedger.withLock { ledger -> Bool in
      if let last = ledger[app.pid], now.timeIntervalSince(last) < ttl.seconds { return false }
      ledger[app.pid] = now
      return true
    }
    guard allowed else { return .coolingDown }
    source.setBool(root, AXAttr.enhancedUserInterface, true)
    source.setBool(root, AXAttr.manualAccessibility, true)
    let deadline = now.addingTimeInterval(verifyWithin.seconds)
    while source.clock.now() < deadline {
      try await source.clock.sleep(for: .milliseconds(250))
      if try source.find(in: root, .hasDomId, FindLimits(maxNodes: 4000, timeBudget: 1.0)).first != nil { return .awake }
    }
    return .notAwake
  }

  /// Perform a declared, user-confirmed action. Every call is audited in the helper log.
  public func perform(_ action: String, on ref: AXRef, axAction: String = "AXPress") throws {
    guard core.manifest.capabilities.contains(.perform),
          core.manifest.actions.contains(where: { $0.id == action }),
          core.grantedActions.contains(action)
    else { throw ReflexError.actionNotGranted(action) }
    core.sink.send(.log(level: "audit", message: "perform \(action)", fields: ["axAction": .string(axAction), "pid": JSON(Int(ref.pid))]))
    try source.perform(ref, axAction)
  }

  /// Pids seen in snapshots (e.g. WebView child processes) – tick loops subscribe to them too.
  var knownPids: Set<Int32> { core.knownPids.current }

  private func notePids(_ node: AXNode) {
    var pids = Set<Int32>()
    func walk(_ n: AXNode) {
      if let p = n.pid { pids.insert(p) }
      for c in n.children { walk(c) }
    }
    walk(node)
    if !pids.isEmpty { core.knownPids.withLock { $0.formUnion(pids) } }
  }

  private func requireApp(_ app: AppInfo) throws {
    guard core.manifest.apps.contains(app.bundleId) else { throw ReflexError.appNotDeclared(app.bundleId) }
  }

  private func requireRead() throws {
    guard core.manifest.capabilities.contains(.read) else { throw ReflexError.capabilityMissing(.read) }
  }
}
