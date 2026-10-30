import AppKit
import ApplicationServices
import Foundation

/// A ReflexKit program: a small Swift executable the helper launches and supervises.
///
/// ```swift
/// @main
/// struct Teams: ReflexProgram {
///   static let manifest = Manifest(id: "teams", apps: ["com.microsoft.teams2"], …)
///   func watch(_ ctx: ProgramContext) async throws { … ctx.emit(…) }
///   func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult { … }
/// }
/// ```
public protocol ReflexProgram {
  static var manifest: Manifest { get }
  init()
  /// Resident loop: detect state, emit business events. Return when `ctx` stops.
  func watch(_ ctx: ProgramContext) async throws
  /// A task started by a rule. Runs until done or until `ctx.isStopping`; returns a structured result.
  func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult
}

extension ReflexProgram {
  public func watch(_ ctx: ProgramContext) async throws {}

  public func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult {
    throw ReflexError.unknownTask(task)
  }

  public static func main() {
    ProgramRuntime.main(Self.self)
  }
}

/// Writes protocol lines to a private copy of the original stdout; stray `print` goes to stderr.
final class StdioSink: ProgramSink, @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()

  init(fd: Int32) { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false) }

  func send(_ message: OutboundMessage) {
    guard let line = try? message.line() else { return }
    lock.lock(); defer { lock.unlock() }
    try? handle.write(contentsOf: Data((line + "\n").utf8))
  }
}

/// Collects messages in memory (tests, replay CLI).
public final class CollectingSink: ProgramSink, @unchecked Sendable {
  private let messages = Locked([OutboundMessage]())
  private let echo: ((OutboundMessage) -> Void)?

  public init(echo: ((OutboundMessage) -> Void)? = nil) { self.echo = echo }

  public func send(_ message: OutboundMessage) {
    messages.withLock { $0.append(message) }
    echo?(message)
  }

  public var all: [OutboundMessage] { messages.current }

  public var events: [ProgramEvent] {
    all.compactMap { if case .event(let e) = $0 { return e } else { return nil } }
  }

  public var logs: [(level: String, message: String)] {
    all.compactMap { if case .log(let l, let m, _) = $0 { return (l, m) } else { return nil } }
  }

  public var statuses: [[String: JSON]] {
    all.compactMap { if case .status(let s) = $0 { return s } else { return nil } }
  }
}

/// Process entry point and helper protocol loop.
public enum ProgramRuntime {
  nonisolated(unsafe) static var retained: AnyObject?

  public static func main<P: ReflexProgram>(_ type: P.Type) {
    var args = Array(CommandLine.arguments.dropFirst())
    let mode = args.first ?? ""
    if !args.isEmpty { args.removeFirst() }
    switch mode {
    case "--manifest":
      let problems = P.manifest.problems()
      if !problems.isEmpty {
        FileHandle.standardError.write(Data(("manifest problems:\n- " + problems.joined(separator: "\n- ") + "\n").utf8))
        exit(2)
      }
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      FileHandle.standardOutput.write((try? enc.encode(P.manifest)) ?? Data())
      FileHandle.standardOutput.write(Data("\n".utf8))
      exit(0)
    case "--selftest":
      print(selftest(P.manifest).serialized())
      exit(0)
    case "--reflex-child":
      // Keep a strong reference for the process lifetime (closures inside hold it weakly).
      let runtime = ChildRuntime<P>()
      retained = runtime
      runtime.run()
    case "--replay":
      ReplayCLI<P>.run(args)
    default:
      let usage = """
        \(P.manifest.id) \(P.manifest.version) — ReflexKit program
        usage:
          \(CommandLine.arguments.first ?? P.manifest.id) --manifest            print the manifest
          … --selftest                                  check AX permission and app visibility
          … --replay <fixture.jsonl> [--task <name> [--input <json>] [--stop-at <sec>]] [--config <json>]
          … --reflex-child                              (started by DSH Reflex Helper)

        """
      FileHandle.standardError.write(Data(usage.utf8))
      exit(mode == "--help" || mode == "-h" ? 0 : 64)
    }
  }

  /// Whether this process can read the declared apps (used for the TCC inheritance check).
  public static func selftest(_ manifest: Manifest) -> JSON {
    let ax = LiveAX()
    let apps = ax.runningApps(Set(manifest.apps))
    var windows: [JSON] = []
    var failure: String?
    if let app = apps.first {
      do {
        windows = try ax.windowList(app).map { w in
          ["role": JSON(w.role), "subrole": JSON(w.subrole), "titleLength": JSON(w.title?.count ?? 0)]
        }
      } catch { failure = "\(error)" }
    }
    return [
      "program": .string(manifest.id),
      "pid": JSON(Int(getpid())),
      "ppid": JSON(Int(getppid())),
      "trusted": JSON(AXIsProcessTrusted()),
      "apps": .array(apps.map { ["pid": JSON(Int($0.pid)), "bundleId": .string($0.bundleId)] }),
      "windows": .array(windows),
      "error": JSON(failure),
    ]
  }
}

/// The `--reflex-child` loop: JSON lines on stdin/stdout with the helper.
final class ChildRuntime<P: ReflexProgram>: @unchecked Sendable {
  private var sink: StdioSink!
  private var core: RuntimeCore?
  private var watchContext: ProgramContext?
  private var watchTask: Task<Void, Never>?
  private let tasks = Locked([String: (ctx: TaskContext, handle: Task<Void, Never>)]())
  private let program = P()
  private var signalSources: [DispatchSourceSignal] = []
  private let shuttingDown = Locked(false)
  private var dataDir = URL(fileURLWithPath: NSTemporaryDirectory())

  func run() -> Never {
    // Keep protocol output on a private fd; anything printed by program code goes to stderr.
    let protoFd = dup(STDOUT_FILENO)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    sink = StdioSink(fd: protoFd)
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      src.setEventHandler { [weak self] in self?.shutdown(exitCode: 0) }
      src.resume()
      signalSources.append(src)
    }
    let reader = Thread { [weak self] in self?.readLoop() }
    reader.name = "ReflexKit.stdin"
    reader.start()
    RunLoop.main.run()
    exit(0)
  }

  private func readLoop() {
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      do {
        handle(try InboundMessage.parse(line))
      } catch {
        sink.send(.log(level: "warn", message: "bad message from helper: \(error)", fields: [:]))
      }
    }
    // stdin closed: the helper is gone. Stop tasks (they checkpoint) and exit.
    shutdown(exitCode: 0)
  }

  private func handle(_ message: InboundMessage) {
    switch message {
    case .command(let command):
      guard let core else {
        sink.send(.commandResult(ProgramCommandResult(requestId: command.requestId, error: "not_initialized")))
        return
      }
      let accepted = core.commands.withLock { queue in
        guard queue.count < 64 else { return false }; queue.append(command); return true
      }
      if !accepted { sink.send(.commandResult(ProgramCommandResult(requestId: command.requestId, error: "busy"))) }
    case .initialize(let m):
      guard core == nil else { return }
      start(m)
    case .taskStart(let m):
      startTask(m)
    case .taskStop(let id, let reason):
      tasks.withLock { $0[id] }?.ctx.stop.request(reason)
    case .ping(let seq):
      sink.send(.pong(seq: seq, metrics: core?.metrics() ?? ProgramMetrics()))
    case .config(let c):
      core?.config.withLock { cfg in for (k, v) in c { cfg[k] = v } }
    case .shutdown:
      shutdown(exitCode: 0)
    }
  }

  private func start(_ m: InitMessage) {
    dataDir = URL(fileURLWithPath: m.dataDir, isDirectory: true)
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let core = RuntimeCore(manifest: P.manifest, source: LiveAX(), sink: sink, config: m.config,
                           grantedActions: Set(m.grantedActions), dev: m.dev)
    self.core = core
    let ctx = ProgramContext(core: core, dataDir: dataDir, stop: core.shutdown)
    watchContext = ctx
    sink.send(.ready(programId: P.manifest.id, version: P.manifest.version, protocolVersion: ReflexProtocol.version, pid: getpid()))
    let program = self.program
    watchTask = Task.detached { [weak self] in
      do {
        try await program.watch(ctx)
      } catch {
        self?.sink.send(.log(level: "error", message: "watch failed: \(error)", fields: [:]))
        // A failing resident loop is a crash: let the helper restart us with backoff.
        if !(self?.shuttingDown.current ?? true) {
          DispatchQueue.global().async { self?.shutdown(exitCode: 3) }
        }
      }
    }
  }

  private func startTask(_ m: TaskStartMessage) {
    guard let core else {
      sink.send(.taskResult(taskId: m.taskId, result: .failed("program not initialized")))
      return
    }
    guard P.manifest.tasks.contains(m.task) else {
      sink.send(.taskResult(taskId: m.taskId, result: .failed("unknown task \(m.task)")))
      return
    }
    if tasks.withLock({ $0[m.taskId] != nil }) { return }
    try? FileManager.default.createDirectory(atPath: m.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let ctx = TaskContext(core: core, dataDir: dataDir, start: m, stop: StopController(parent: core.shutdown))
    let program = self.program
    let sink = self.sink!
    let handle = Task.detached { [weak self] in
      var result: TaskResult
      do {
        result = try await program.run(task: m.task, input: m.input, ctx: ctx)
      } catch {
        result = .failed("\(error)")
      }
      ctx.closeFiles()
      if let reason = ctx.stopReason, result.output["stopReason"] == nil {
        result.output = result.output.merging(["stopReason": .string(reason.rawValue)])
      }
      sink.send(.taskResult(taskId: m.taskId, result: result))
      _ = self?.tasks.withLock { $0.removeValue(forKey: m.taskId) }
    }
    tasks.withLock { $0[m.taskId] = (ctx, handle) }
  }

  private func shutdown(exitCode: Int32) {
    let first = shuttingDown.withLock { v -> Bool in defer { v = true }; return !v }
    guard first else { return }
    core?.shutdown.request(.shutdown)
    let running = tasks.withLock { $0.values.map(\.handle) }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      for h in running { await h.value }
      done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
    watchTask?.cancel()
    core?.source.shutdown()
    exit(exitCode)
  }
}

/// `--replay`: run the program against a fixture on virtual time and print events/results as JSON lines.
enum ReplayCLI<P: ReflexProgram> {
  static func run(_ args: [String]) -> Never {
    var fixturePath: String?
    var task: String?
    var input: JSON = .object([:])
    var stopAt: Double?
    var config: [String: JSON] = [:]
    var i = 0
    while i < args.count {
      let a = args[i]
      func value() -> String { i += 1; return i < args.count ? args[i] : "" }
      switch a {
      case "--task": task = value()
      case "--input": input = (try? JSON.parse(value())) ?? .object([:])
      case "--stop-at": stopAt = Double(value())
      case "--config": config = (try? JSON.parse(value()))?.object ?? [:]
      default: if fixturePath == nil { fixturePath = a }
      }
      i += 1
    }
    guard let fixturePath else {
      FileHandle.standardError.write(Data("--replay needs a fixture path\n".utf8))
      exit(64)
    }
    let echo: (OutboundMessage) -> Void = { msg in
      if let line = try? msg.line() { print(line) }
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      do {
        let harness = try ProgramHarness(P(), fixture: URL(fileURLWithPath: fixturePath), config: config, echo: echo)
        if let task {
          let r = try await harness.runTask(task, input: input, stopAt: stopAt)
          print(try OutboundMessage.taskResult(taskId: "replay", result: r).line())
        } else {
          _ = try await harness.runWatch()
        }
      } catch {
        FileHandle.standardError.write(Data("replay failed: \(error)\n".utf8))
      }
      done.signal()
    }
    done.wait()
    exit(0)
  }
}
