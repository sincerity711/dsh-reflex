import AppKit
import ApplicationServices
import Foundation
import ReflexKit

public struct HelperOptions: Sendable {
  public var dshHome: URL
  public var idleExitSec: Double = 600
  public var waitForLock = false

  public static func parse(_ args: [String]) -> HelperOptions {
    var o = HelperOptions(dshHome: HelperPaths.defaultHome())
    var i = 1
    while i < args.count {
      switch args[i] {
      case "--home":
        i += 1
        if i < args.count { o.dshHome = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath, isDirectory: true) }
      case "--idle-exit":
        i += 1
        if i < args.count, let v = Double(args[i]) { o.idleExitSec = v }
      case "--wait-lock":
        o.waitForLock = true
      default: break
      }
      i += 1
    }
    return o
  }
}

/// The helper: socket server, outbox, program supervision, permission and dev tools.
public final class HelperService: @unchecked Sendable {
  public static let version = "0.1.0"
  public static let protocolVersion = 1

  let options: HelperOptions
  let paths: HelperPaths
  let queue = DispatchQueue(label: "dev.dshreflex.helper")
  private var server: RPCServer!
  private var outbox: Outbox!
  private var programs: ProgramManager!
  private var token = ""
  private let startedAt = Date()
  private var lastActivity = Date()
  private var lockFd: Int32 = -1
  private var outboxConsumer: RPCConnection?
  private var idleTimer: DispatchSourceTimer?
  private var accessTimer: DispatchSourceTimer?
  private let ax = LiveAX()
  private var recorders: [String: AXRecorder] = [:]
  /// Connection that started each recording: a recording ends with its client.
  private var recordOwners: [String: RPCConnection] = [:]
  private var workspaceObservers: [NSObjectProtocol] = []
  private var shuttingDown = false
  private var desktopStatus: JSON = .null
  private var desktopLocale = "en"
  private let log: LineAppender
  private let cpu = CPUMeter()
  private lazy var backgroundMeeting: BackgroundMeeting = {
    let manager = BackgroundMeeting(environment: NativeBackgroundEnvironment())
    manager.log = { [weak self] message in self?.logLine("info", message) }
    return manager
  }()

  public init(options: HelperOptions) {
    self.options = options
    self.paths = HelperPaths(dshHome: options.dshHome)
    self.log = LineAppender(url: paths.logsDir.appendingPathComponent("helper.log"))
  }

  func logLine(_ level: String, _ text: String) {
    try? log.append("\(ISO8601.format(Date())) \(level.uppercased()) \(text)")
  }

  // MARK: lifecycle

  public func start() throws {
    try paths.prepare()
    try acquireLock()
    token = Self.randomToken()
    try AtomicFile.write(Data((token + "\n").utf8), to: paths.tokenFile, permissions: 0o600)
    outbox = try Outbox(directory: paths.stateDir)
    try queue.sync {
      programs = ProgramManager(paths: paths, queue: queue, outbox: outbox)
      programs.onOutbox = { [weak self] item in self?.pushOutbox(item) }
      programs.onLog = { [weak self] id, line in
        self?.server.broadcast("program.log", ["program": .string(id), "line": .string(line)], subscription: "logs")
        self?.server.broadcast("program.log", ["program": .string(id), "line": .string(line)], subscription: "logs:\(id)")
      }
      server = RPCServer(path: paths.socketPath, queue: queue)
      server.handler = { [weak self] conn, req, respond in self?.handle(conn, req, respond) }
      server.onDisconnect = { [weak self] conn in
        guard let self else { return }
        if self.outboxConsumer == conn {
          self.outboxConsumer = nil
          // A broken socket alone must not stop capture. If the owning host actually died,
          // allow a replacement leader time to reconnect before stopping the helper.
          if let pid = conn.clientInfo["pid"]?.int, pid > 1 {
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
              guard let self, self.outboxConsumer == nil, kill(Int32(pid), 0) != 0, errno == ESRCH else { return }
              self.programs.abandonTasks()
              self.shutdown(reason: "desktop process exited")
            }
          }
        }
        for (id, owner) in self.recordOwners where owner == conn {
          self.logLine("info", "client gone: stopping recording \(id)")
          self.recorders[id]?.stop()
        }
        self.lastActivity = Date()
      }
      try server.start()
      programs.start()
    }
    try writeInfo()
    startAppMonitor()
    startTimers()
    installSignalHandlers()
    logLine("info", "helper \(Self.version) started pid \(getpid()) socket \(paths.socketPath) trusted=\(AXIsProcessTrusted())")
  }

  private func acquireLock() throws {
    let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw RPCError.failed("cannot open lock file") }
    let deadline = Date().addingTimeInterval(options.waitForLock ? 15 : 0)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      if Date() >= deadline {
        close(fd)
        throw RPCError.failed("another helper instance is running")
      }
      usleep(200_000)
    }
    ftruncate(fd, 0)
    let pidText = "\(getpid())\n"
    _ = pidText.withCString { write(fd, $0, strlen($0)) }
    lockFd = fd
  }

  private func writeInfo() throws {
    let info: JSON = [
      "pid": JSON(Int(getpid())), "version": .string(Self.version), "protocol": JSON(Self.protocolVersion),
      "socket": .string(paths.socketPath), "startedAt": JSON(startedAt), "bundlePath": .string(Bundle.main.bundlePath),
      "executable": .string(Bundle.main.executablePath ?? CommandLine.arguments[0]),
    ]
    try AtomicFile.write(Data(info.serialized().utf8), to: paths.infoFile, permissions: 0o600)
  }

  static func randomToken() -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
  }

  private func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
      src.setEventHandler { [weak self] in self?.shutdown(reason: "signal \(sig)") }
      src.resume()
      signalSources.append(src)
    }
  }

  private var signalSources: [DispatchSourceSignal] = []

  private func startAppMonitor() {
    let center = NSWorkspace.shared.notificationCenter
    let update: () -> Void = { [weak self] in
      let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      self?.queue.async { self?.programs.setRunningApps(ids) }
    }
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in update() })
    }
    DispatchQueue.main.async(execute: update)
  }

  private func startTimers() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 30, repeating: 30)
    t.setEventHandler { [weak self] in self?.checkIdle() }
    t.resume()
    idleTimer = t
    let a = DispatchSource.makeTimerSource(queue: queue)
    a.schedule(deadline: .now() + 5, repeating: 5)
    a.setEventHandler { [weak self] in self?.checkAccess() }
    a.resume()
    accessTimer = a
  }

  private func checkIdle() {
    cpu.update(pid: getpid())
    reconcileBackgroundMeeting()
    guard !backgroundMeeting.isActive else { return }
    guard options.idleExitSec > 0, server.connections.isEmpty, !programs.hasActiveTasks, recorders.isEmpty else { return }
    if Date().timeIntervalSince(lastActivity) >= options.idleExitSec {
      shutdown(reason: "idle: no clients and no tasks for \(Int(options.idleExitSec))s")
    }
  }

  /// AXIsProcessTrusted() is cached per process: when it says no, ask a fresh child process;
  /// if the child is trusted, relaunch so this process sees the grant too.
  private func checkAccess() {
    guard !AXIsProcessTrusted(), !server.connections.isEmpty else { return }
    DispatchQueue.global().async { [weak self] in
      guard let self, let result = self.runAXCheck(executable: self.bundledAXCheck, bundleIds: []).first,
            result["trusted"]?.bool == true
      else { return }
      self.queue.async {
        self.logLine("info", "accessibility granted; relaunching to refresh the cached permission state")
        self.relaunch()
      }
    }
  }

  func relaunch() {
    let bundle = Bundle.main.bundleURL
    shutdown(reason: "relaunch") {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      p.arguments = ["-n", "-g", "-j", bundle.path, "--args", "--home", self.paths.dshHome.path, "--wait-lock"]
      try? p.run()
    }
  }

  public func shutdown(reason: String, then: (() -> Void)? = nil) {
    guard !shuttingDown else { return }
    shuttingDown = true
    logLine("info", "shutting down: \(reason)")
    backgroundMeeting.shutdown()
    for r in recorders.values { r.stop() }
    server.broadcast("helper.exiting", ["reason": .string(reason)], subscription: "outbox")
    programs.shutdownAll { [self] in
      server.stop()
      try? FileManager.default.removeItem(at: paths.infoFile)
      if lockFd >= 0 { flock(lockFd, LOCK_UN); close(lockFd) }
      ax.shutdown()
      log.sync()
      then?()
      DispatchQueue.main.async { exit(0) }
    }
  }

  /// A snapshot for the local menu bar; caption contents remain in the existing task directory.
  public func menuSnapshot(_ completion: @escaping (JSON) -> Void) {
    queue.async { [self] in
      reconcileBackgroundMeeting()
      let programStatus = programs.statusJSON()
      let correlation = programStatus.array?.first(where: { $0["id"]?.string == "teams" })?["status"]?["correlationId"]?.string
      let selected = MenuCaptureSnapshot.read(tasks: programs.taskList().array ?? [], runId: desktopStatus["runId"]?.string, correlationId: correlation, runCorrelationId: desktopStatus["correlationId"]?.string)
      let snapshot: JSON = ["connected": JSON(outboxConsumer != nil && outboxConsumer?.closed == false), "axTrusted": JSON(AXIsProcessTrusted()),
                            "desktop": desktopStatus, "locale": .string(desktopLocale),
                            "capture": selected.capture, "checkpoint": selected.checkpoint, "captureStatus": selected.status,
                            "programs": programStatus, "backgroundMeeting": backgroundMeeting.snapshot]
      DispatchQueue.main.async { completion(snapshot) }
    }
  }

  private func reconcileBackgroundMeeting() {
    guard backgroundMeeting.isActive else { return }
    let status = programs.statusJSON().array?.first(where: { $0["id"]?.string == "teams" })?["status"]
    backgroundMeeting.reconcile(currentCorrelation: status?["correlationId"]?.string,
                                meetingEnded: ["idle", "suppressed"].contains(status?["meeting"]?.string ?? ""))
  }

  /// Local menu-only action. Serialized with shutdown and status refresh; never emits meeting events.
  public func backgroundMeetingCommand(_ action: String, correlation: String?, completion: @escaping (String?) -> Void) {
    queue.async { [self] in
      var failure: String?
      do {
        guard !shuttingDown else { throw BackgroundMeetingError.windowNotReady }
        if action == "bringBack" {
          if let session = backgroundMeeting.session, correlation != session.correlation {
            throw BackgroundMeetingError.staleMeeting
          }
          try backgroundMeeting.bringBack()
        } else if action == "park" {
          let status = programs.statusJSON().array?.first(where: { $0["id"]?.string == "teams" })?["status"]
          guard let correlation, status?["correlationId"]?.string == correlation,
                ["in_meeting", "leave_pending"].contains(status?["meeting"]?.string ?? "") else {
            throw BackgroundMeetingError.staleMeeting
          }
          try backgroundMeeting.park(correlation: correlation)
        } else { throw BackgroundMeetingError.unsupported }
      } catch {
        failure = (error as? BackgroundMeetingError)?.rawValue ?? "window_unavailable"
        logLine("warn", "background command=\(action) error=\(failure!)")
      }
      DispatchQueue.main.async { completion(failure) }
    }
  }

  /// In-process menu actions use the same supervised child pipe as authenticated RPC clients.
  public func meetingCommand(_ command: ProgramCommand, completion: @escaping (ProgramCommandResult) -> Void) {
    queue.async { [self] in
      programs.command(program: "teams", command: command) { result in
        DispatchQueue.main.async { completion(result) }
      }
    }
  }

  // MARK: outbox

  private func pushOutbox(_ item: OutboxItem) {
    guard let c = outboxConsumer, !c.closed else { return }
    c.notify("outbox.item", item.json)
  }

  // MARK: RPC

  private func handle(_ conn: RPCConnection, _ req: RPCRequest, _ respond: @escaping (Result<JSON, RPCError>) -> Void) {
    lastActivity = Date()
    if !conn.authenticated {
      guard req.method == "hello" else {
        respond(.failure(.unauthorized("hello required")))
        conn.close()
        return
      }
      guard req.params["token"]?.string == token else {
        respond(.failure(.unauthorized("bad token")))
        conn.close()
        return
      }
      let proto = req.params["protocol"]?.int ?? 0
      guard proto == Self.protocolVersion else {
        respond(.failure(RPCError(-32002, "protocol mismatch: helper \(Self.protocolVersion), client \(proto)",
                                  data: ["helperVersion": .string(Self.version), "helperProtocol": JSON(Self.protocolVersion)])))
        return
      }
      conn.authenticated = true
      conn.clientInfo = req.params["client"] ?? .null
      respond(.success(helperInfo()))
      return
    }
    do {
      if let result = try dispatch(conn, req, respond) { respond(.success(result)) }
    } catch let e as RPCError {
      respond(.failure(e))
    } catch {
      respond(.failure(.failed("\(error)")))
    }
  }

  private func helperInfo() -> JSON {
    [
      "version": .string(Self.version), "protocol": JSON(Self.protocolVersion), "pid": JSON(Int(getpid())),
      "startedAt": JSON(startedAt), "bundlePath": .string(Bundle.main.bundlePath),
      "axTrusted": JSON(AXIsProcessTrusted()), "devMode": JSON(paths.devModeActive), "signing": signingInfo(),
    ]
  }

  private func signingInfo() -> JSON {
    // Read our own signature (identity name or ad-hoc).
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return .null }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let dict = info as? [String: Any] ?? [:]
    let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    let name = certs.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    return ["identity": JSON(name), "adhoc": JSON(name == nil)]
  }

  /// Returns a result now, or nil when `respond` will be called later.
  private func dispatch(_ conn: RPCConnection, _ req: RPCRequest, _ respond: @escaping (Result<JSON, RPCError>) -> Void) throws -> JSON? {
    let p = req.params
    switch req.method {
    case "helper.status":
      return status()
    case "helper.menuStatus":
      // Diagnose the actual menu selection without returning caption text or task input.
      menuSnapshot { snapshot in
        let meeting = snapshot["programs"]?.array?.first { $0["id"]?.string == "teams" }
        respond(.success([
          "programState": meeting?["state"] ?? .null,
          "meeting": meeting?["status"]?["meeting"] ?? .null,
          "correlationId": meeting?["status"]?["correlationId"] ?? .null,
          "commandsSupported": meeting?["status"]?["commandsSupported"] ?? .null,
          "axTrusted": snapshot["axTrusted"] ?? .null,
          "runId": snapshot["desktop"]?["runId"] ?? .null,
          "captureTaskId": snapshot["capture"]?["taskId"] ?? .null,
          "captureCorrelationId": snapshot["capture"]?["correlationId"] ?? .null,
          "captionLines": JSON(snapshot["checkpoint"]?["capture"]?["assembler"]?["lines"]?.array?.count ?? 0),
          "captureStartedAt": snapshot["checkpoint"]?["capture"]?["startedAt"] ?? snapshot["capture"]?["startedAt"] ?? .null,
          "participantNamesSaved": JSON(snapshot["checkpoint"]?["capture"]?["participants"]?["observedNames"]?.array?.count ?? 0),
          "participantsState": snapshot["checkpoint"]?["capture"]?["participants"]?["state"] ?? .null,
          "reportedParticipants": snapshot["checkpoint"]?["capture"]?["participants"]?["snapshots"]?.array?.last?["reportedCount"] ?? .null,
          "openGap": snapshot["captureStatus"]?["openGap"] ?? .null,
          "backgroundMeeting": snapshot["backgroundMeeting"] ?? .null,
        ]))
      }
      return nil
    case "helper.requestAccess":
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      let trusted = AXIsProcessTrustedWithOptions(opts)
      if p["openSettings"]?.bool ?? true,
         let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
      }
      return ["trusted": JSON(trusted)]
    case "helper.checkAccess":
      DispatchQueue.global().async { [self] in
        let child = runAXCheck(executable: bundledAXCheck, bundleIds: [])
        respond(.success(["inProcess": JSON(AXIsProcessTrusted()), "child": child.first ?? .null]))
      }
      return nil
    case "helper.shutdown":
      queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.shutdown(reason: "requested by client") }
      return ["ok": true]
    case "desktop.status":
      guard outboxConsumer == conn else { throw RPCError.notAllowed("only the active desktop can update status") }
      desktopStatus = p["status"] ?? .null
      if let locale = p["locale"]?.string { desktopLocale = locale }
      return ["ok": true]
    case "desktop.shutdown":
      guard outboxConsumer == conn else { throw RPCError.notAllowed("only the active desktop can stop the helper") }
      queue.asyncAfter(deadline: .now() + 0.2) { [weak self, weak conn] in
        guard let self, let conn, self.outboxConsumer == conn else { return }
        self.programs.abandonTasks()
        self.shutdown(reason: "desktop stopped")
      }
      return ["ok": true]
    case "helper.relaunch":
      queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.relaunch() }
      return ["ok": true]

    case "programs.list":
      return programs.installedManifests()
    case "programs.rescan":
      programs.rescan()
      return programs.installedManifests()
    case "programs.configure":
      let list = try (p["programs"] ?? .array([])).decode(as: [ProgramDesired].self)
      programs.configure(list, replaceAll: p["replaceAll"]?.bool ?? false)
      return programs.statusJSON()
    case "programs.command":
      let command = try JSONCoding.decoder.decode(ProgramCommand.self, from: Data((p["command"] ?? .null).serialized().utf8))
      programs.command(program: try requireString(p, "id"), command: command) { result in
        respond(.success((try? JSON(encoding: result)) ?? .null))
      }
      return nil
    case "programs.restart":
      programs.restart(try requireString(p, "id"))
      return ["ok": true]
    case "programs.devRun":
      try requireDev()
      let id = try requireString(p, "id")
      programs.setDevRun(id, p["on"]?.bool ?? true)
      conn.subscriptions.insert("logs:\(id)")
      return ["ok": true]

    case "tasks.start":
      return try programs.startTask(
        taskId: try requireString(p, "taskId"), program: try requireString(p, "program"), task: try requireString(p, "task"),
        input: p["input"] ?? .object([:]), dir: p["dir"]?.string ?? "", resumable: p["resumable"]?.bool ?? false)
    case "tasks.stop":
      let reason = StopReason(rawValue: p["reason"]?.string ?? "") ?? .cancel
      try programs.stopTask(taskId: try requireString(p, "taskId"), reason: reason, grace: p["graceMs"]?.double.map { $0 / 1000 })
      return ["ok": true]
    case "tasks.list":
      return programs.taskList()

    case "outbox.subscribe":
      if let current = outboxConsumer, current != conn, !current.closed, p["takeover"]?.bool != true {
        throw RPCError.notAllowed("another consumer is subscribed (client \(current.clientInfo.serialized()))")
      }
      outboxConsumer?.subscriptions.remove("outbox")
      outboxConsumer = conn
      conn.subscriptions.insert("outbox")
      let after = p["after"]?.int ?? 0
      let pending = outbox.pending(after: after)
      // The response is written asynchronously on this queue; queue the backlog after it so the
      // client knows how many items to expect before they arrive.
      respond(.success(["lastSeq": JSON(outbox.lastSeq), "pending": JSON(pending.count)]))
      queue.async { [weak conn] in
        guard let conn else { return }
        for item in pending { conn.notify("outbox.item", item.json) }
      }
      return nil
    case "outbox.ack":
      try outbox.ack(upTo: p["upTo"]?.int ?? 0)
      return ["depth": JSON(outbox.depth)]

    case "logs.subscribe":
      if let id = p["program"]?.string { conn.subscriptions.insert("logs:\(id)") } else { conn.subscriptions.insert("logs") }
      return ["ok": true]

    case "selftest":
      let bundleIds = p["bundleIds"]?.array?.compactMap(\.string) ?? ["com.microsoft.teams2"]
      DispatchQueue.global().async { [self] in
        var children: [JSON] = []
        children += runAXCheck(executable: bundledAXCheck, bundleIds: bundleIds)
        let external = paths.programsDir.appendingPathComponent("_axcheck/reflex-axcheck")
        if FileManager.default.isExecutableFile(atPath: external.path) {
          children += runAXCheck(executable: external, bundleIds: bundleIds)
        }
        respond(.success(["helper": ["pid": JSON(Int(getpid())), "trusted": JSON(AXIsProcessTrusted())], "children": .array(children)]))
      }
      return nil

    case "ax.inspect":
      try requireDev()
      let bundleId = try requireString(p, "bundleId")
      try requireWhitelisted(bundleId)
      var limits = ReadLimits.inspect
      if let d = p["maxDepth"]?.int { limits.maxDepth = d }
      if let n = p["maxNodes"]?.int { limits.maxNodes = n }
      if let t = p["maxTextLength"]?.int { limits.maxTextLength = t }
      if p["frames"]?.bool == true { limits.includeFrames = true }
      let redaction = RedactionMode(rawValue: p["redaction"]?.string ?? "ui") ?? .ui
      guard AXIsProcessTrusted() else { throw RPCError.notAllowed("helper has no accessibility permission") }
      DispatchQueue.global().async { [self] in
        do {
          let apps = try AXInspector.inspect(source: ax, bundleId: bundleId, limits: limits, redaction: redaction)
          respond(.success(["apps": try JSON(encoding: apps)]))
        } catch {
          respond(.failure(.failed("\(error)")))
        }
      }
      return nil

    case "ax.prepareWeb":
      try requireDev()
      let bundleId = try requireString(p, "bundleId")
      try requireWhitelisted(bundleId)
      var out: [JSON] = []
      for app in ax.runningApps([bundleId]) {
        let root = ax.appRef(app)
        let a = ax.setBool(root, AXAttr.enhancedUserInterface, true)
        let b = ax.setBool(root, AXAttr.manualAccessibility, true)
        out.append(["pid": JSON(Int(app.pid)), "enhancedUserInterface": .string(a.rawValue), "manualAccessibility": .string(b.rawValue)])
      }
      return .array(out)

    case "ax.record":
      try requireDev()
      let bundleIds = try p["bundleIds"]?.array?.compactMap(\.string) ?? [requireString(p, "bundleId")]
      for b in bundleIds { try requireWhitelisted(b) }
      guard AXIsProcessTrusted() else { throw RPCError.notAllowed("helper has no accessibility permission") }
      let out = try requireString(p, "out")
      var options = RecordOptions(bundleIds: bundleIds, duration: p["durationSec"]?.double ?? 60)
      if let i = p["intervalSec"]?.double { options.interval = i }
      if let r = p["redaction"]?.string.flatMap(RedactionMode.init(rawValue:)) { options.redaction = r }
      if let n = p["maxNodes"]?.int { options.limits.maxNodes = n }
      options.note = p["note"]?.string
      if let keep = p["keep"]?.array?.compactMap(\.string) { options.keep = try keep.map { try AXQuery.parse($0) } }
      if let k = p["keyframeSec"]?.double { options.keyframeEvery = k }
      if let words = p["keepWords"]?.array?.compactMap(\.string) { options.keepWords = words }
      let recordId = p["recordId"]?.string ?? ULID.make()
      let recorder = AXRecorder(source: ax, options: options, out: URL(fileURLWithPath: out))
      recorders[recordId] = recorder
      recordOwners[recordId] = conn
      Task.detached { [self] in
        do {
          let summary = try await recorder.run()
          queue.async {
            self.recorders.removeValue(forKey: recordId)
            self.recordOwners.removeValue(forKey: recordId)
          }
          respond(.success(["recordId": .string(recordId), "summary": try JSON(encoding: summary)]))
        } catch {
          queue.async {
            self.recorders.removeValue(forKey: recordId)
            self.recordOwners.removeValue(forKey: recordId)
          }
          respond(.failure(.failed("\(error)")))
        }
      }
      conn.notify("ax.record.started", ["recordId": .string(recordId)])
      return nil
    case "ax.record.mark":
      guard let r = recorders[try requireString(p, "recordId")] else { throw RPCError.invalidParams("no such recording") }
      r.mark(try requireString(p, "label"))
      return ["ok": true]
    case "ax.record.stop":
      guard let r = recorders[try requireString(p, "recordId")] else { throw RPCError.invalidParams("no such recording") }
      r.stop()
      return ["ok": true]

    case "sim.emit":
      try requireDev()
      let program = p["program"]?.string ?? "sim"
      let ev = p["event"] ?? .object([:])
      let event = ProgramEvent(
        try requireString(ev, "eventType"), resourceId: ev["resourceId"]?.string ?? "sim",
        correlationId: ev["correlationId"]?.string, identity: IdentityQuality(rawValue: ev["identity"]?.string ?? "") ?? .stable,
        payload: ev["payload"]?.object ?? [:], observedAt: Date(), origin: .simulated, dedupeKey: ev["dedupeKey"]?.string)
      let item = try programs.simulate(event, program: program)
      return item.json

    default:
      throw RPCError.methodNotFound(req.method)
    }
  }

  private func status() -> JSON {
    cpu.update(pid: getpid())
    return [
      "helper": helperInfo().merging([
        "uptimeSec": JSON(Date().timeIntervalSince(startedAt).rounded()),
        "rssBytes": JSON(Double(cpu.latest?.rssBytes ?? 0)),
        "footprintBytes": JSON(Double(cpu.latest?.footprintBytes ?? 0)),
        "cpuPercent": JSON((cpu.percent * 10).rounded() / 10),
        "idleExitSec": JSON(options.idleExitSec),
        "socket": .string(paths.socketPath),
      ]),
      "programs": programs.statusJSON(),
      "tasks": programs.taskList(),
      "outbox": ["depth": JSON(outbox.depth), "lastSeq": JSON(outbox.lastSeq), "consumer": JSON(outboxConsumer != nil)],
      "menu": ["locale": .string(desktopLocale)],
      "connections": .array(server.connections.map { $0.clientInfo }),
      "recordings": JSON(Array(recorders.keys)),
    ]
  }

  // MARK: helpers

  private func requireString(_ p: JSON, _ key: String) throws -> String {
    guard let v = p[key]?.string, !v.isEmpty else { throw RPCError.invalidParams("missing \(key)") }
    return v
  }

  private func requireDev() throws {
    guard paths.devModeActive else {
      throw RPCError.notAllowed("dev mode is off (run `dsh-reflex dev on` to enable dev tools for a while)")
    }
  }

  private func requireWhitelisted(_ bundleId: String) throws {
    var allowed: Set<String> = ["com.microsoft.teams2", "com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari"]
    if let list = programs.installedManifests().array {
      for m in list { for a in m["apps"]?.array ?? [] { if let s = a.string { allowed.insert(s) } } }
    }
    if let cfg = try? JSON.parse(Data(contentsOf: paths.configFile)), let extra = cfg["devApps"]?.array {
      for a in extra { if let s = a.string { allowed.insert(s) } }
    }
    guard allowed.contains(bundleId) else {
      throw RPCError.notAllowed("\(bundleId) is not whitelisted (add it to \(paths.configFile.path) devApps)")
    }
  }

  var bundledAXCheck: URL {
    URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent("Contents/MacOS/reflex-axcheck")
  }

  /// Spawn the diagnostic child and parse its JSON output.
  func runAXCheck(executable: URL, bundleIds: [String]) -> [JSON] {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      return [["executable": .string(executable.path), "error": "not found"]]
    }
    let p = Process()
    p.executableURL = executable
    p.arguments = bundleIds
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [["executable": .string(executable.path), "error": .string("\(error)")]] }
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSON.parse(data) else {
      return [["executable": .string(executable.path), "error": "unparseable output", "status": JSON(Int(p.terminationStatus))]]
    }
    return [json]
  }
}
