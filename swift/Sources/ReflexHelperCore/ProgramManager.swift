import Foundation
import ReflexKit
import CryptoKit

/// A program installed under `<reflex>/programs/<id>/` (executable + manifest.json).
public struct InstalledProgram: Sendable {
  public let id: String
  public let dir: URL
  public let executable: URL
  public let manifest: Manifest
  public let binarySize: Int
  public let binaryDigest: String

  public static func scan(_ root: URL) -> [String: InstalledProgram] {
    var out: [String: InstalledProgram] = [:]
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return out }
    for dir in entries where !dir.lastPathComponent.hasPrefix(".") && !dir.lastPathComponent.hasPrefix("_") {
      let manifestURL = dir.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONCoding.decoder.decode(Manifest.self, from: data),
            manifest.id == dir.lastPathComponent
      else { continue }
      let exe = dir.appendingPathComponent(manifest.id)
      guard fm.isExecutableFile(atPath: exe.path) else { continue }
      let size = (try? fm.attributesOfItem(atPath: exe.path)[.size] as? Int) ?? 0
      guard let binary = try? Data(contentsOf: exe, options: .mappedIfSafe) else { continue }
      let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
      out[manifest.id] = InstalledProgram(id: manifest.id, dir: dir, executable: exe, manifest: manifest, binarySize: size, binaryDigest: digest)
    }
    return out
  }
}

/// What the plugin wants for a program (persisted so the helper can keep running tasks alone).
public struct ProgramDesired: Codable, Sendable, Hashable {
  public var id: String
  public var enabled: Bool
  /// Referenced by at least one enabled rule.
  public var required: Bool
  public var config: [String: JSON]
  public var grantedActions: [String]

  public init(id: String, enabled: Bool, required: Bool, config: [String: JSON] = [:], grantedActions: [String] = []) {
    self.id = id
    self.enabled = enabled
    self.required = required
    self.config = config
    self.grantedActions = grantedActions
  }
}

struct TaskRecord: Codable, Sendable {
  var taskId: String
  var program: String
  var task: String
  var input: JSON
  var dir: String
  var resumable: Bool
  var startedAt: Date
  /// running | stopping | interrupted
  var state: String
  var stopReason: String?
  var stopDeadline: Date?
  /// How many times the task was delivered to a program process.
  var deliveries: Int
  /// pid of the process the task was last delivered to (not persisted meaningfully across restarts).
  var deliveredPid: Int32?
}

/// Supervises program processes: on-demand start/stop, heartbeats, restart with backoff,
/// auto-disable after repeated failures, task routing and resumption. All methods run on `queue`.
public final class ProgramManager: @unchecked Sendable {
  final class Slot {
    let id: String
    var installed: InstalledProgram?
    var desired: ProgramDesired?
    var process: ProgramProcess?
    var loadedDigest: String?
    var loadedVersion: String?
    var state = "stopped"
    var lastError: String?
    var failures: [Date] = []
    var backoffUntil: Date?
    var restarts = 0
    var lastPongAt: Date?
    var lastPingAt: Date?
    var pingSeq = 0
    var metrics: ProgramMetrics?
    var status: [String: JSON] = [:]
    var stallStrikes = 0
    var appsGoneSince: Date?
    var devRun = false
    var startedAt: Date?
    let cpu = CPUMeter()
    var killReason: String?

    init(id: String) { self.id = id }
  }

  private var pendingCommands: [String: (token: UUID, program: String, pid: Int32, command: ProgramCommand, completion: (ProgramCommandResult) -> Void)] = [:]

  public func command(program: String, command: ProgramCommand, completion: @escaping (ProgramCommandResult) -> Void) {
    guard pendingCommands[command.requestId] == nil else {
      completion(ProgramCommandResult(requestId: command.requestId, error: "request_in_progress")); return
    }
    guard let slot = slots[program], let process = slot.process, process.ready, slot.state == "running" else {
      completion(ProgramCommandResult(requestId: command.requestId, error: "program_unavailable")); return
    }
    let token = UUID()
    pendingCommands[command.requestId] = (token, program, process.pid, command, completion)
    process.send(try? InboundMessage.command(command).line())
    queue.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard self?.pendingCommands[command.requestId]?.token == token,
            let pending = self?.pendingCommands.removeValue(forKey: command.requestId) else { return }
      pending.completion(ProgramCommandResult(requestId: command.requestId, error: "response_timeout"))
    }
  }

  public struct Config: Sendable {
    public var pingInterval: Double = 5
    public var pongTimeout: Double = 15
    public var maxFailures = 5
    public var failureWindow: Double = 600
    public var maxBackoff: Double = 60
    public var defaultStopGrace: Double = 10

    public init() {}
  }

  let paths: HelperPaths
  let queue: DispatchQueue
  let outbox: Outbox
  var config = Config()
  private var slots: [String: Slot] = [:]
  private var tasks: [String: TaskRecord] = [:]
  private(set) var runningBundleIds = Set<String>()
  private var shuttingDown = false
  private var timer: DispatchSourceTimer?
  private let logs: ProgramLogs
  /// Called with each new outbox item (to push to subscribers) and with dev log lines.
  var onOutbox: ((OutboxItem) -> Void)?
  var onLog: ((String, String) -> Void)?
  var onChange: (() -> Void)?

  public init(paths: HelperPaths, queue: DispatchQueue, outbox: Outbox) {
    self.paths = paths
    self.queue = queue
    self.outbox = outbox
    self.logs = ProgramLogs(dir: paths.logsDir.appendingPathComponent("programs", isDirectory: true))
    loadState()
    rescan()
  }

  // MARK: state persistence

  private var desiredURL: URL { paths.stateDir.appendingPathComponent("desired.json") }
  private var tasksURL: URL { paths.stateDir.appendingPathComponent("tasks.json") }

  private func loadState() {
    if let desired = try? AtomicFile.readJSON([ProgramDesired].self, from: desiredURL) {
      for d in desired { slot(d.id).desired = d }
    }
    if let saved = try? AtomicFile.readJSON([TaskRecord].self, from: tasksURL) {
      for var t in saved {
        // Whatever was running when the helper went away is interrupted now.
        t.state = t.state == "stopping" ? "stopping" : "interrupted"
        t.deliveredPid = nil
        tasks[t.taskId] = t
      }
    }
  }

  private func saveDesired() {
    let all = slots.values.compactMap(\.desired).sorted { $0.id < $1.id }
    try? AtomicFile.writeJSON(all, to: desiredURL)
  }

  private func saveTasks() {
    try? AtomicFile.writeJSON(tasks.values.sorted { $0.startedAt < $1.startedAt }, to: tasksURL)
  }

  private func slot(_ id: String) -> Slot {
    if let s = slots[id] { return s }
    let s = Slot(id: id)
    slots[id] = s
    return s
  }

  // MARK: public API (call on queue)

  public func start() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    timer = t
    reconcile()
  }

  public func rescan() {
    let found = InstalledProgram.scan(paths.programsDir)
    for (id, p) in found { slot(id).installed = p }
    for (id, s) in slots where found[id] == nil { s.installed = nil }
    reconcile()
  }

  public func setRunningApps(_ ids: Set<String>) {
    guard ids != runningBundleIds else { return }
    runningBundleIds = ids
    reconcile()
  }

  /// Apply the plugin's desired state. Programs not listed keep their previous desire.
  public func configure(_ desired: [ProgramDesired], replaceAll: Bool) {
    if replaceAll {
      let ids = Set(desired.map(\.id))
      for (id, s) in slots where !ids.contains(id) && s.desired != nil {
        s.desired?.enabled = false
        s.desired?.required = false
      }
    }
    for d in desired {
      let s = slot(d.id)
      let configChanged = s.desired?.config != d.config
      let wasEnabled = s.desired?.enabled == true
      s.desired = d
      if d.enabled && !wasEnabled && s.state == "failed" {
        // Re-enabling is an explicit user decision: clear the failure history.
        s.failures.removeAll()
        s.backoffUntil = nil
        s.state = "stopped"
      }
      if configChanged, let p = s.process, p.ready {
        let merged = (s.installed?.manifest.config ?? [:]).merging(d.config) { _, n in n }
        p.send(try? InboundMessage.config(merged).line())
      }
    }
    saveDesired()
    reconcile()
  }

  /// Clear a failed state and try again (`/reflex program restart`).
  public func restart(_ id: String) {
    let s = slot(id)
    s.failures.removeAll()
    s.backoffUntil = nil
    s.lastError = nil
    if s.state == "failed" { s.state = "stopped" }
    if let p = s.process { stopProcess(s, p, reason: "restart requested", kill: false) } else { reconcile() }
  }

  public func setDevRun(_ id: String, _ on: Bool) {
    slot(id).devRun = on
    reconcile()
  }

  public func shutdownAll(completion: @escaping () -> Void) {
    shuttingDown = true
    timer?.cancel()
    let running = slots.values.compactMap { s -> ProgramProcess? in s.process }
    if running.isEmpty { saveTasks(); completion(); return }
    let group = DispatchGroup()
    for s in slots.values {
      guard let p = s.process else { continue }
      group.enter()
      p.onExitExtra = { group.leave() }
      p.expectedExit = true
      p.send(try? InboundMessage.shutdown.line())
      p.terminate(after: 4)
    }
    group.notify(queue: queue) { [weak self] in
      self?.saveTasks()
      completion()
    }
  }

  public var hasActiveTasks: Bool { !tasks.isEmpty }

  /// Desktop shutdown deliberately abandons captures: do not resume them on the next launch.
  func abandonTasks() {
    tasks.removeAll()
    saveTasks()
  }

  // MARK: tasks

  public func startTask(taskId: String, program: String, task: String, input: JSON, dir: String, resumable: Bool) throws -> JSON {
    if let existing = tasks[taskId] {
      return ["accepted": true, "existing": true, "state": .string(existing.state)]
    }
    let s = slot(program)
    guard let installed = s.installed else { throw RPCError.failed("program \(program) is not installed") }
    guard s.desired?.enabled == true else { throw RPCError.notAllowed("program \(program) is not enabled") }
    guard installed.manifest.tasks.contains(task) else { throw RPCError.invalidParams("program \(program) has no task \(task)") }
    guard s.state != "failed" else { throw RPCError.failed("program \(program) is disabled after repeated failures: \(s.lastError ?? "")") }
    let taskDir = dir.isEmpty ? paths.dataDir.appendingPathComponent("tasks/\(taskId)").path : dir
    try FileManager.default.createDirectory(atPath: taskDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    tasks[taskId] = TaskRecord(taskId: taskId, program: program, task: task, input: input, dir: taskDir, resumable: resumable,
                               startedAt: Date(), state: "running", stopReason: nil, stopDeadline: nil, deliveries: 0, deliveredPid: nil)
    saveTasks()
    if let p = s.process, p.ready { deliver(taskId, to: p) }
    reconcile()
    return ["accepted": true, "existing": false, "dir": .string(taskDir)]
  }

  public func stopTask(taskId: String, reason: StopReason, grace: Double?) throws {
    guard var t = tasks[taskId] else { throw RPCError.invalidParams("unknown task \(taskId)") }
    t.state = "stopping"
    t.stopReason = reason.rawValue
    t.stopDeadline = Date().addingTimeInterval(grace ?? config.defaultStopGrace)
    tasks[taskId] = t
    saveTasks()
    let s = slot(t.program)
    if let p = s.process, p.ready, t.deliveredPid == p.pid {
      p.send(try? InboundMessage.taskStop(taskId: taskId, reason: reason).line())
    } else if s.state == "failed" || s.installed == nil {
      publishResult(t, TaskResult(status: reason == .timeout ? TaskStatusCode.timedOut : TaskStatusCode.cancelled,
                                  error: "program \(t.program) unavailable: \(s.lastError ?? "not running")"))
    }
    // Otherwise the program is (re)starting: the stop is sent right after the resume delivery.
    reconcile()
  }

  public func taskList() -> JSON {
    .array(tasks.values.sorted { $0.startedAt < $1.startedAt }.map { t in
      ["taskId": .string(t.taskId), "program": .string(t.program), "task": .string(t.task), "state": .string(t.state),
       "correlationId": t.input["correlationId"] ?? .null,
       "startedAt": JSON(t.startedAt), "dir": .string(t.dir), "deliveries": JSON(t.deliveries),
       "stopReason": JSON(t.stopReason), "resumable": JSON(t.resumable)]
    })
  }

  private func deliver(_ taskId: String, to p: ProgramProcess) {
    guard var t = tasks[taskId] else { return }
    let resume = t.deliveries > 0
    let start = TaskStartMessage(taskId: t.taskId, task: t.task, input: t.input, dir: t.dir, resume: resume)
    p.send(try? InboundMessage.taskStart(start).line())
    t.deliveries += 1
    t.deliveredPid = p.pid
    if t.state == "interrupted" { t.state = "running" }
    tasks[taskId] = t
    if t.state == "stopping", let r = t.stopReason.flatMap(StopReason.init(rawValue:)) {
      p.send(try? InboundMessage.taskStop(taskId: taskId, reason: r).line())
    }
    saveTasks()
  }

  private func publishResult(_ t: TaskRecord, _ result: TaskResult) {
    tasks.removeValue(forKey: t.taskId)
    saveTasks()
    var data: [String: JSON] = [
      "taskId": .string(t.taskId), "program": .string(t.program), "task": .string(t.task),
      "status": .string(result.status), "output": result.output, "files": JSON(result.files),
      "startedAt": JSON(t.startedAt), "endedAt": JSON(Date()), "deliveries": JSON(t.deliveries),
    ]
    if let e = result.error { data["error"] = .string(e) }
    if let r = t.stopReason { data["stopReason"] = .string(r) }
    if let item = try? outbox.append(kind: "task.result", id: "result:\(t.taskId)", data: .object(data)) {
      onOutbox?(item)
    }
    reconcile()
  }

  // MARK: reconcile & supervision

  private func appRunning(_ s: Slot) -> Bool {
    guard let apps = s.installed?.manifest.apps else { return false }
    return apps.contains { runningBundleIds.contains($0) }
  }

  private func activeTasks(_ id: String) -> [TaskRecord] { tasks.values.filter { $0.program == id } }

  func reconcile() {
    guard !shuttingDown else { return }
    let now = Date()
    for s in slots.values {
      guard let installed = s.installed else {
        if let p = s.process { stopProcess(s, p, reason: "uninstalled", kill: false) }
        s.state = s.process == nil ? "notInstalled" : s.state
        continue
      }
      let enabled = s.desired?.enabled == true
      let hasTasks = !activeTasks(s.id).isEmpty
      let appUp = appRunning(s)
      if appUp { s.appsGoneSince = nil } else if s.appsGoneSince == nil { s.appsGoneSince = now }
      let wanted = enabled && ((s.desired?.required == true && appUp) || s.devRun) || (enabled && hasTasks)

      if !enabled, hasTasks {
        // Disabled while tasks run: cancel them; the process stops when they are done.
        for t in activeTasks(s.id) where t.state != "stopping" { try? stopTask(taskId: t.taskId, reason: .cancel, grace: nil) }
      }

      if let p = s.process {
        if p.stopping { continue }
        if s.loadedDigest != installed.binaryDigest, activeTasks(s.id).allSatisfy(\.resumable) {
          stopProcess(s, p, reason: "installed binary updated", kill: false)
          continue
        }
        if wanted { continue }
        if hasTasks { continue }
        let lingering = enabled && s.desired?.required == true && !appUp
          && now.timeIntervalSince(s.appsGoneSince ?? now) < Double(installed.manifest.lingerSec)
        if lingering { continue }
        stopProcess(s, p, reason: enabled ? "apps not running" : "disabled", kill: false)
        continue
      }
      if s.state == "failed" { continue }
      if wanted {
        if let until = s.backoffUntil, now < until { s.state = "backoff"; continue }
        launch(s, installed)
      } else {
        s.state = enabled ? "idle" : "disabled"
      }
    }
    onChange?()
  }

  private func launch(_ s: Slot, _ installed: InstalledProgram) {
    let dataDir = paths.dataDir.appendingPathComponent("programs/\(s.id)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let config = installed.manifest.config.merging(s.desired?.config ?? [:]) { _, n in n }
    let initMsg = InitMessage(programId: s.id, config: config, dataDir: dataDir.path,
                              grantedActions: s.desired?.grantedActions ?? [], dev: s.devRun || paths.devModeActive)
    do {
      let p = try ProgramProcess(
        executable: installed.executable, programId: s.id, dataDir: dataDir, logs: logs, queue: queue,
        onLine: { [weak self, weak s] proc, line in
          guard let self, let s else { return }
          self.handleLine(s, proc, line)
        },
        onExit: { [weak self, weak s] proc, status in
          guard let self, let s else { return }
          self.handleExit(s, proc, status)
        })
      s.process = p
      s.loadedDigest = installed.binaryDigest
      s.loadedVersion = installed.manifest.version
      s.status = [:]
      s.state = "starting"
      s.startedAt = Date()
      s.lastPongAt = Date()
      s.lastPingAt = nil
      s.stallStrikes = 0
      s.killReason = nil
      s.cpu.reset()
      p.send(try? InboundMessage.initialize(initMsg).line(), force: true)
      logs.write(s.id, "info", "started pid \(p.pid)")
    } catch {
      s.lastError = "launch failed: \(error)"
      recordFailure(s)
    }
  }

  private func handleLine(_ s: Slot, _ p: ProgramProcess, _ line: String) {
    guard s.process === p else { return }
    let message: OutboundMessage
    do { message = try OutboundMessage.parse(line) } catch {
      logs.write(s.id, "warn", "bad line from program: \(line.prefix(200))")
      return
    }
    switch message {
    case .commandResult(let result):
      guard let pending = pendingCommands[result.requestId], pending.program == s.id, pending.pid == p.pid else { return }
      pendingCommands.removeValue(forKey: result.requestId)
      s.status = result.status.isEmpty ? s.status : result.status
      pending.completion(result)
      onChange?()
    case .ready(let id, let version, _, _):
      s.loadedVersion = version
      p.ready = true
      s.state = "running"
      p.flushQueued()
      logs.write(s.id, "info", "ready \(id) \(version)")
      for t in activeTasks(s.id) where t.deliveredPid != p.pid { deliver(t.taskId, to: p) }
      onChange?()
    case .event(let e):
      publishEvent(s, e)
    case .taskResult(let taskId, let result):
      guard let t = tasks[taskId] else { return }
      if shuttingDown, t.resumable, t.stopReason == nil { return }
      if result.output["stopReason"]?.string == StopReason.shutdown.rawValue, t.resumable, t.stopReason == nil {
        // The program is going away (not our request for this task): resume later.
        var r = t
        r.state = "interrupted"
        tasks[taskId] = r
        saveTasks()
        return
      }
      publishResult(t, result)
    case .taskProgress(let taskId, let progress):
      logs.write(s.id, "debug", "progress \(taskId): \(progress.serialized().prefix(300))")
    case .log(let level, let msg, let fields):
      let text = fields.isEmpty ? msg : "\(msg) \(JSON.object(fields).serialized())"
      logs.write(s.id, level, text)
      onLog?(s.id, "[\(level)] \(text)")
    case .status(let status):
      s.status = status
      onChange?()
    case .pong(_, let metrics):
      s.lastPongAt = Date()
      s.metrics = metrics
      let stallLimit = Double(s.installed?.manifest.stallTimeoutSec ?? 90)
      if let stalled = metrics.loops.first(where: { $0.stalledSec > stallLimit }) {
        s.stallStrikes += 1
        if s.stallStrikes >= 2 {
          stopProcess(s, p, reason: "loop \(stalled.name) stalled for \(Int(stalled.stalledSec))s", kill: true)
        }
      } else {
        s.stallStrikes = 0
      }
    }
  }

  private func publishEvent(_ s: Slot, _ e: ProgramEvent) {
    let eventId = ULID.make()
    var data: [String: JSON] = [
      "eventId": .string(eventId), "eventType": .string(e.eventType), "timestamp": JSON(Date()),
      "observedAt": JSON(e.observedAt),
      "app": ["bundleId": .string(s.installed?.manifest.apps.first ?? ""), "program": .string(s.id),
              "pid": s.process.map { JSON(Int($0.pid)) } ?? .null],
      "resourceId": .string(e.resourceId), "origin": .string(e.origin.rawValue),
      "identity": .string(e.identity.rawValue), "payload": .object(e.payload),
    ]
    if let c = e.correlationId { data["correlationId"] = .string(c) }
    if let d = e.dedupeKey { data["dedupeKey"] = .string(d) }
    do {
      let item = try outbox.append(kind: "event", id: eventId, data: .object(data))
      onOutbox?(item)
    } catch {
      logs.write(s.id, "error", "outbox append failed: \(error)")
    }
  }

  /// Inject a simulated event (dev mode `sim.emit`).
  func simulate(_ e: ProgramEvent, program: String) throws -> OutboxItem {
    let eventId = ULID.make()
    var data: [String: JSON] = [
      "eventId": .string(eventId), "eventType": .string(e.eventType), "timestamp": JSON(Date()),
      "observedAt": JSON(e.observedAt), "app": ["bundleId": "simulated", "program": .string(program), "pid": .null],
      "resourceId": .string(e.resourceId), "origin": "simulated", "identity": .string(e.identity.rawValue),
      "payload": .object(e.payload),
    ]
    if let c = e.correlationId { data["correlationId"] = .string(c) }
    if let d = e.dedupeKey { data["dedupeKey"] = .string(d) }
    let item = try outbox.append(kind: "event", id: eventId, data: .object(data))
    onOutbox?(item)
    return item
  }

  private func handleExit(_ s: Slot, _ p: ProgramProcess, _ status: Int32) {
    guard s.process === p else { return }
    s.process = nil
    s.cpu.reset()
    let expected = p.expectedExit && s.killReason == nil
    logs.write(s.id, expected ? "info" : "warn", "exited status \(status)\(s.killReason.map { " (\($0))" } ?? "")")
    // Decide restart policy first so reconcile() (triggered by results below) honours the backoff.
    if expected {
      s.state = "stopped"
    } else {
      s.lastError = s.killReason ?? "exited with status \(status)"
      recordFailure(s)
    }
    for t in activeTasks(s.id) where t.deliveredPid == p.pid {
      if t.state == "stopping", p.killedForTask == t.taskId || (t.stopDeadline.map { Date() >= $0 } ?? false) {
        let code = t.stopReason == StopReason.timeout.rawValue ? TaskStatusCode.timedOut : TaskStatusCode.cancelled
        publishResult(t, TaskResult(status: code, error: "task did not stop within the grace period; program was killed"))
      } else if t.resumable && !(t.state == "stopping" && t.stopReason == StopReason.cancel.rawValue) && s.state != "failed" {
        var r = t
        r.state = t.state == "stopping" ? "stopping" : "interrupted"
        r.deliveredPid = nil
        tasks[t.taskId] = r
      } else if t.state == "stopping" {
        publishResult(t, TaskResult(status: TaskStatusCode.cancelled, error: "program exited while stopping"))
      } else if s.state != "failed" {
        publishResult(t, TaskResult(status: TaskStatusCode.error, error: "program exited unexpectedly (status \(status))"))
      }
    }
    saveTasks()
    reconcile()
  }

  private func recordFailure(_ s: Slot) {
    let now = Date()
    s.failures.append(now)
    s.failures.removeAll { now.timeIntervalSince($0) > config.failureWindow }
    s.restarts += 1
    if s.failures.count >= config.maxFailures {
      s.state = "failed"
      s.lastError = "disabled after \(s.failures.count) failures in \(Int(config.failureWindow / 60)) min; last: \(s.lastError ?? "?")"
      logs.write(s.id, "error", s.lastError ?? "")
      for t in activeTasks(s.id) {
        publishResult(t, TaskResult(status: TaskStatusCode.error, error: s.lastError))
      }
      return
    }
    let delay = min(config.maxBackoff, pow(2, Double(s.failures.count - 1)))
    s.backoffUntil = now.addingTimeInterval(delay)
    s.state = "backoff"
  }

  private func stopProcess(_ s: Slot, _ p: ProgramProcess, reason: String, kill: Bool) {
    guard !p.stopping else { return }
    p.stopping = true
    if kill {
      s.killReason = reason
      p.expectedExit = false
      logs.write(s.id, "warn", "killing: \(reason)")
      p.terminate(after: 0)
    } else {
      p.expectedExit = true
      s.state = "stopping"
      logs.write(s.id, "info", "stopping: \(reason)")
      p.send(try? InboundMessage.shutdown.line())
      p.terminate(after: 5)
    }
  }

  private func tick() {
    let now = Date()
    for s in slots.values {
      guard let p = s.process else { continue }
      s.cpu.update(pid: p.pid)
      if p.ready, now.timeIntervalSince(s.lastPingAt ?? .distantPast) >= config.pingInterval {
        s.pingSeq += 1
        s.lastPingAt = now
        p.send(try? InboundMessage.ping(seq: s.pingSeq).line())
      }
      if !p.stopping, now.timeIntervalSince(s.lastPongAt ?? now) > config.pongTimeout + (p.ready ? 0 : 15) {
        stopProcess(s, p, reason: "heartbeat timeout", kill: true)
      }
    }
    // Stop deadlines.
    for t in tasks.values where t.state == "stopping" {
      guard let deadline = t.stopDeadline, now >= deadline else { continue }
      let s = slot(t.program)
      if let p = s.process, !p.stopping {
        p.killedForTask = t.taskId
        stopProcess(s, p, reason: "task \(t.taskId) did not stop within grace", kill: true)
      } else if s.process == nil {
        let status = t.stopReason == StopReason.timeout.rawValue ? TaskStatusCode.timedOut : TaskStatusCode.cancelled
        publishResult(t, TaskResult(status: status, error: "program not running"))
      }
    }
    reconcile()
  }

  // MARK: status

  public func statusJSON() -> JSON {
    .array(slots.values.sorted { $0.id < $1.id }.map { s in
      var o: [String: JSON] = [
        "id": .string(s.id), "installed": JSON(s.installed != nil), "state": .string(s.state),
        "enabled": JSON(s.desired?.enabled ?? false), "required": JSON(s.desired?.required ?? false),
        "restarts": JSON(s.restarts), "recentFailures": JSON(s.failures.count), "devRun": JSON(s.devRun),
        "appRunning": JSON(appRunning(s)),
        "tasks": JSON(activeTasks(s.id).map(\.taskId)),
      ]
      if let m = s.installed?.manifest {
        o["version"] = .string(s.process != nil ? (s.loadedVersion ?? m.version) : m.version)
        o["installedVersion"] = .string(m.version)
        o["apps"] = JSON(m.apps)
        o["capabilities"] = JSON(m.capabilities.map(\.rawValue))
        o["emits"] = JSON(m.emits)
        o["taskNames"] = JSON(m.tasks)
      }
      if let p = s.process {
        o["pid"] = JSON(Int(p.pid))
        o["startedAt"] = s.startedAt.map(JSON.init) ?? .null
        o["cpuPercent"] = JSON((s.cpu.percent * 10).rounded() / 10)
        o["rssBytes"] = JSON(Double(s.cpu.latest?.rssBytes ?? 0))
        o["footprintBytes"] = JSON(Double(s.cpu.latest?.footprintBytes ?? 0))
      }
      if let e = s.lastError { o["lastError"] = .string(e) }
      if let m = s.metrics, let j = try? JSON(encoding: m) { o["metrics"] = j }
      if !s.status.isEmpty { o["status"] = .object(s.status) }
      return .object(o)
    })
  }

  public func installedManifests() -> JSON {
    .array(slots.values.compactMap(\.installed).sorted { $0.id < $1.id }.compactMap { p in
      guard var j = try? JSON(encoding: p.manifest).object else { return nil }
      j["binarySize"] = JSON(p.binarySize)
      j["dir"] = .string(p.dir.path)
      return .object(j)
    })
  }

  public func runningProcessCount() -> Int { slots.values.filter { $0.process != nil }.count }
}

/// Program log files with simple size-based rotation.
final class ProgramLogs: @unchecked Sendable {
  let dir: URL
  private var appenders: [String: LineAppender] = [:]
  private let lock = NSLock()
  private let maxBytes = 5 * 1024 * 1024

  init(dir: URL) {
    self.dir = dir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).log") }

  func write(_ id: String, _ level: String, _ text: String) {
    lock.lock(); defer { lock.unlock() }
    let u = url(id)
    if let size = try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int, size > maxBytes {
      appenders[id]?.close()
      appenders[id] = nil
      try? FileManager.default.removeItem(at: u.appendingPathExtension("1"))
      try? FileManager.default.moveItem(at: u, to: u.appendingPathExtension("1"))
    }
    let a = appenders[id] ?? LineAppender(url: u)
    appenders[id] = a
    try? a.append("\(ISO8601.format(Date())) \(level.uppercased()) \(text)")
  }
}

/// One running program process with JSON-lines stdio.
final class ProgramProcess: @unchecked Sendable {
  let process = Process()
  private(set) var pid: Int32 = 0
  private let stdinHandle: FileHandle
  private var buffer = Data()
  private var queued: [String] = []
  var ready = false
  var stopping = false
  var expectedExit = false
  var killedForTask: String?
  var onExitExtra: (() -> Void)?
  private var killTimer: DispatchWorkItem?
  private let queue: DispatchQueue

  init(executable: URL, programId: String, dataDir: URL, logs: ProgramLogs, queue: DispatchQueue,
       onLine: @escaping (ProgramProcess, String) -> Void, onExit: @escaping (ProgramProcess, Int32) -> Void) throws
  {
    self.queue = queue
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    stdinHandle = stdin.fileHandleForWriting
    process.executableURL = executable
    process.arguments = ["--reflex-child"]
    process.currentDirectoryURL = dataDir
    var env: [String: String] = [:]
    let inherited = ProcessInfo.processInfo.environment
    for key in ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"] { env[key] = inherited[key] }
    env["REFLEX_PROGRAM_ID"] = programId
    env["REFLEX_DATA_DIR"] = dataDir.path
    process.environment = env
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      if data.isEmpty { h.readabilityHandler = nil }
      queue.async {
        guard let me = self, !data.isEmpty else { return }
        me.buffer.append(data)
        while let nl = me.buffer.firstIndex(of: 0x0A) {
          let lineData = me.buffer.subdata(in: me.buffer.startIndex..<nl)
          me.buffer.removeSubrange(me.buffer.startIndex...nl)
          if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(me, line) }
        }
      }
    }
    stderr.fileHandleForReading.readabilityHandler = { h in
      let data = h.availableData
      if data.isEmpty { h.readabilityHandler = nil; return }
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
      if !text.isEmpty { logs.write(programId, "stderr", text) }
    }
    process.terminationHandler = { [weak self] proc in
      // Let pending stdout lines be processed first (same serial queue, enqueued earlier).
      queue.async {
        guard let me = self else { return }
        me.killTimer?.cancel()
        onExit(me, proc.terminationStatus)
        me.onExitExtra?()
      }
    }
    try process.run()
    pid = process.processIdentifier
  }

  /// Send a line; before `ready`, only forced lines (init) go out, the rest is queued.
  func send(_ line: String?, force: Bool = false) {
    guard let line else { return }
    if !ready && !force {
      queued.append(line)
      return
    }
    try? stdinHandle.write(contentsOf: Data((line + "\n").utf8))
  }

  func flushQueued() {
    let q = queued
    queued.removeAll()
    for l in q { send(l) }
  }

  /// SIGTERM after `after` seconds (0 = now), SIGKILL 3 s later.
  func terminate(after: Double) {
    let pid = self.pid
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.process.isRunning else { return }
      kill(pid, SIGTERM)
      self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self, self.process.isRunning else { return }
        kill(pid, SIGKILL)
      }
    }
    killTimer?.cancel()
    killTimer = item
    queue.asyncAfter(deadline: .now() + after, execute: item)
    if after == 0 { try? stdinHandle.close() }
  }
}
