import Foundation

/// Runs a program against a recorded fixture on virtual time — no real app needed.
///
/// ```swift
/// let h = try ProgramHarness(Teams(), fixture: url, config: ["leaveGraceSec": 120])
/// let events = try await h.runWatch()
/// let result = try await h.runTask("captureCaptions", stopAt: 600)
/// ```
public final class ProgramHarness<P: ReflexProgram>: @unchecked Sendable {
  public let program: P
  public let replay: ReplayAX
  public let sink: CollectingSink
  public let dataDir: URL
  let core: RuntimeCore

  public init(_ program: P, fixture: Fixture, config: [String: JSON] = [:], grantedActions: [String] = [],
              dataDir: URL? = nil, echo: ((OutboundMessage) -> Void)? = nil) throws
  {
    self.program = program
    self.replay = ReplayAX(fixture: fixture)
    self.sink = CollectingSink(echo: echo)
    let dir = dataDir ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("reflex-harness-\(P.manifest.id)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.dataDir = dir
    self.core = RuntimeCore(manifest: P.manifest, source: replay, sink: sink, config: config,
                            grantedActions: Set(grantedActions), dev: true)
  }

  public convenience init(_ program: P, fixture url: URL, config: [String: JSON] = [:], grantedActions: [String] = [],
                          dataDir: URL? = nil, echo: ((OutboundMessage) -> Void)? = nil) throws
  {
    try self.init(program, fixture: try Fixture.load(url), config: config, grantedActions: grantedActions, dataDir: dataDir, echo: echo)
  }

  public var events: [ProgramEvent] { sink.events }

  /// Seconds since the recording started (virtual).
  public var elapsed: Double { replay.elapsed }

  /// Run the resident `watch` loop until `until` seconds into the recording (default: the end).
  @discardableResult
  public func runWatch(until seconds: Double? = nil) async throws -> [ProgramEvent] {
    let before = sink.events.count
    let ctx = ProgramContext(core: core, dataDir: dataDir, stop: StopController())
    ctx.stopAt = replay.date(at: seconds ?? replay.fixture.duration)
    ctx.stopAtReason = .shutdown
    try await program.watch(ctx)
    return Array(sink.events.dropFirst(before))
  }

  /// Run one task from the current virtual time until `stopAt` seconds (the stop signal is delivered
  /// with `stopReason`), or until the program returns on its own.
  public func runTask(_ task: String, input: JSON = .object([:]), stopAt seconds: Double? = nil,
                      stopReason: StopReason = .stopOn, resume: Bool = false, dir: URL? = nil,
                      taskId: String = "task-1") async throws -> TaskResult
  {
    guard P.manifest.tasks.contains(task) else { throw ReflexError.unknownTask(task) }
    let taskDir = dir ?? dataDir.appendingPathComponent("tasks/\(taskId)", isDirectory: true)
    try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
    let start = TaskStartMessage(taskId: taskId, task: task, input: input, dir: taskDir.path, resume: resume)
    let ctx = TaskContext(core: core, dataDir: dataDir, start: start, stop: StopController())
    ctx.stopAt = replay.date(at: seconds ?? replay.fixture.duration)
    ctx.stopAtReason = stopReason
    defer { ctx.closeFiles() }
    return try await program.run(task: task, input: input, ctx: ctx)
  }

  /// Jump virtual time (e.g. to start a task at a marker).
  public func advance(to seconds: Double) {
    replay.advance(to: replay.date(at: seconds))
  }
}
