import Foundation

/// How reliable a resource identity is. `heuristic` when derived from window titles etc.
public enum IdentityQuality: String, Codable, Sendable {
  case stable
  case heuristic
}

public enum EventOrigin: String, Codable, Sendable {
  case ax
  case poll
  case simulated
}

/// A business event emitted by a program. The helper assigns `eventId` and persists it in the outbox.
public struct ProgramEvent: Codable, Hashable, Sendable {
  public var eventType: String
  public var resourceId: String
  public var correlationId: String?
  public var identity: IdentityQuality
  public var payload: [String: JSON]
  public var observedAt: Date
  public var origin: EventOrigin
  /// Optional; the plugin derives one from type + resource + correlation when absent.
  public var dedupeKey: String?

  public init(
    _ eventType: String,
    resourceId: String,
    correlationId: String? = nil,
    identity: IdentityQuality = .stable,
    payload: [String: JSON] = [:],
    observedAt: Date = Date(),
    origin: EventOrigin = .ax,
    dedupeKey: String? = nil
  ) {
    self.eventType = eventType
    self.resourceId = resourceId
    self.correlationId = correlationId
    self.identity = identity
    self.payload = payload
    self.observedAt = observedAt
    self.origin = origin
    self.dedupeKey = dedupeKey
  }
}

public enum TaskStatusCode {
  public static let ok = "ok"
  public static let partial = "partial"
  public static let error = "error"
  public static let cancelled = "cancelled"
  public static let timedOut = "timed_out"
}

/// Structured task result: small data in `output`, big content in `files` (absolute paths).
public struct TaskResult: Codable, Hashable, Sendable {
  public var status: String
  public var output: JSON
  public var files: [String]
  public var error: String?

  public init(status: String, output: JSON = .object([:]), files: [String] = [], error: String? = nil) {
    self.status = status
    self.output = output
    self.files = files
    self.error = error
  }

  public static func ok(_ output: JSON = .object([:]), files: [String] = []) -> TaskResult {
    TaskResult(status: TaskStatusCode.ok, output: output, files: files)
  }

  public static func failed(_ message: String, status: String = TaskStatusCode.error) -> TaskResult {
    TaskResult(status: status, output: .object([:]), files: [], error: message)
  }
}

public enum StopReason: String, Codable, Sendable {
  /// A rule's `stopOn` event arrived: finish normally.
  case stopOn
  case cancel
  case timeout
  /// The program or helper is shutting down; the task may be resumed later.
  case shutdown
}

// MARK: - helper -> program

public struct InitMessage: Codable, Sendable {
  public var programId: String
  public var protocolVersion: Int
  public var config: [String: JSON]
  public var dataDir: String
  public var grantedActions: [String]
  public var dev: Bool

  public init(programId: String, config: [String: JSON], dataDir: String, grantedActions: [String], dev: Bool) {
    self.programId = programId
    self.protocolVersion = ReflexProtocol.version
    self.config = config
    self.dataDir = dataDir
    self.grantedActions = grantedActions
    self.dev = dev
  }
}

public struct TaskStartMessage: Codable, Sendable {
  public var taskId: String
  public var task: String
  public var input: JSON
  public var dir: String
  public var resume: Bool

  public init(taskId: String, task: String, input: JSON, dir: String, resume: Bool) {
    self.taskId = taskId
    self.task = task
    self.input = input
    self.dir = dir
    self.resume = resume
  }
}

/// A local lifecycle operation, never an AX action or a task cancellation.
public struct ProgramCommand: Codable, Equatable, Sendable {
  public var requestId: String
  public var correlationId: String
  public var action: String
  public var episode: Int?
  public var issuedAt: Date
  public init(requestId: String, correlationId: String, action: String, episode: Int? = nil, issuedAt: Date = Date()) {
    self.requestId = requestId; self.correlationId = correlationId; self.action = action
    self.episode = episode; self.issuedAt = issuedAt
  }
}

public struct ProgramCommandResult: Codable, Equatable, Sendable {
  public var requestId: String
  public var error: String?
  public var status: [String: JSON]
  public init(requestId: String, error: String? = nil, status: [String: JSON] = [:]) {
    self.requestId = requestId; self.error = error; self.status = status
  }
}

public enum InboundMessage: Sendable {
  case command(ProgramCommand)
  case initialize(InitMessage)
  case taskStart(TaskStartMessage)
  case taskStop(taskId: String, reason: StopReason)
  case ping(seq: Int)
  case config([String: JSON])
  case shutdown

  public func line() throws -> String {
    var o: [String: JSON]
    switch self {
    case .command(let m):
      o = try JSON.parse(JSONCoding.encoder.encode(m)).object ?? [:]
      o["type"] = "program.command"
    case .initialize(let m):
      o = try JSON(encoding: m).object ?? [:]
      o["type"] = "init"
    case .taskStart(let m):
      o = try JSON(encoding: m).object ?? [:]
      o["type"] = "task.start"
    case .taskStop(let id, let reason):
      o = ["type": "task.stop", "taskId": .string(id), "reason": .string(reason.rawValue)]
    case .ping(let seq):
      o = ["type": "ping", "seq": JSON(seq)]
    case .config(let c):
      o = ["type": "config", "config": .object(c)]
    case .shutdown:
      o = ["type": "shutdown"]
    }
    return JSON.object(o).serialized()
  }

  public static func parse(_ line: String) throws -> InboundMessage {
    let json = try JSON.parse(line)
    guard let type = json["type"]?.string else { throw WireError.malformed("missing type") }
    switch type {
    case "program.command": return .command(try JSONCoding.decoder.decode(ProgramCommand.self, from: Data(json.serialized().utf8)))
    case "init": return .initialize(try json.decode(as: InitMessage.self))
    case "task.start": return .taskStart(try json.decode(as: TaskStartMessage.self))
    case "task.stop":
      guard let id = json["taskId"]?.string else { throw WireError.malformed("task.stop without taskId") }
      return .taskStop(taskId: id, reason: StopReason(rawValue: json["reason"]?.string ?? "") ?? .cancel)
    case "ping": return .ping(seq: json["seq"]?.int ?? 0)
    case "config": return .config(json["config"]?.object ?? [:])
    case "shutdown": return .shutdown
    default: throw WireError.malformed("unknown type \(type)")
    }
  }
}

// MARK: - program -> helper

public struct LoopHealth: Codable, Hashable, Sendable {
  public var name: String
  public var ticks: Int
  public var lastTickAt: Date?
  public var stalledSec: Double
  public var avgHandlerMs: Double
  public var maxHandlerMs: Double

  public init(name: String, ticks: Int, lastTickAt: Date?, stalledSec: Double, avgHandlerMs: Double, maxHandlerMs: Double) {
    self.name = name
    self.ticks = ticks
    self.lastTickAt = lastTickAt
    self.stalledSec = stalledSec
    self.avgHandlerMs = avgHandlerMs
    self.maxHandlerMs = maxHandlerMs
  }
}

public struct ProgramMetrics: Codable, Hashable, Sendable {
  public var axCalls: Int
  public var axMillis: Double
  public var axErrors: Int
  public var eventsEmitted: Int
  public var avgEventLatencyMs: Double
  public var loops: [LoopHealth]

  public init(axCalls: Int = 0, axMillis: Double = 0, axErrors: Int = 0, eventsEmitted: Int = 0, avgEventLatencyMs: Double = 0, loops: [LoopHealth] = []) {
    self.axCalls = axCalls
    self.axMillis = axMillis
    self.axErrors = axErrors
    self.eventsEmitted = eventsEmitted
    self.avgEventLatencyMs = avgEventLatencyMs
    self.loops = loops
  }
}

public enum OutboundMessage: Sendable {
  case commandResult(ProgramCommandResult)
  case ready(programId: String, version: String, protocolVersion: Int, pid: Int32)
  case event(ProgramEvent)
  case taskResult(taskId: String, result: TaskResult)
  case taskProgress(taskId: String, progress: JSON)
  case log(level: String, message: String, fields: [String: JSON])
  case status([String: JSON])
  case pong(seq: Int, metrics: ProgramMetrics)

  public func line() throws -> String {
    var o: [String: JSON]
    switch self {
    case .commandResult(let result):
      o = try JSON(encoding: result).object ?? [:]
      o["type"] = "program.command.result"
    case .ready(let id, let version, let proto, let pid):
      o = ["type": "ready", "programId": .string(id), "version": .string(version), "protocolVersion": JSON(proto), "pid": JSON(Int(pid))]
    case .event(let e):
      o = try JSON(encoding: EncodableBox(e)).object ?? [:]
      o["type"] = "event"
    case .taskResult(let id, let r):
      o = try JSON(encoding: r).object ?? [:]
      o["type"] = "task.result"
      o["taskId"] = .string(id)
    case .taskProgress(let id, let p):
      o = ["type": "task.progress", "taskId": .string(id), "progress": p]
    case .log(let level, let message, let fields):
      o = ["type": "log", "level": .string(level), "message": .string(message), "fields": .object(fields)]
    case .status(let s):
      o = ["type": "status", "status": .object(s)]
    case .pong(let seq, let metrics):
      o = ["type": "pong", "seq": JSON(seq), "metrics": try JSON(encoding: EncodableBox(metrics))]
    }
    return JSON.object(o).serialized()
  }

  public static func parse(_ line: String) throws -> OutboundMessage {
    let json = try JSON.parse(line)
    guard let type = json["type"]?.string else { throw WireError.malformed("missing type") }
    switch type {
    case "program.command.result": return .commandResult(try json.decode(as: ProgramCommandResult.self))
    case "ready":
      return .ready(programId: json["programId"]?.string ?? "", version: json["version"]?.string ?? "",
                    protocolVersion: json["protocolVersion"]?.int ?? 0, pid: Int32(json["pid"]?.int ?? 0))
    case "event":
      return .event(try JSONCoding.decoder.decode(ProgramEvent.self, from: Data(json.serialized().utf8)))
    case "task.result":
      guard let id = json["taskId"]?.string else { throw WireError.malformed("task.result without taskId") }
      return .taskResult(taskId: id, result: try json.decode(as: TaskResult.self))
    case "task.progress":
      return .taskProgress(taskId: json["taskId"]?.string ?? "", progress: json["progress"] ?? .null)
    case "log":
      return .log(level: json["level"]?.string ?? "info", message: json["message"]?.string ?? "", fields: json["fields"]?.object ?? [:])
    case "status":
      return .status(json["status"]?.object ?? [:])
    case "pong":
      let metrics = (try? JSONCoding.decoder.decode(ProgramMetrics.self, from: Data((json["metrics"] ?? .null).serialized().utf8))) ?? ProgramMetrics()
      return .pong(seq: json["seq"]?.int ?? 0, metrics: metrics)
    default:
      throw WireError.malformed("unknown type \(type)")
    }
  }
}

/// Encodes Dates as ISO strings when converting to JSON.
struct EncodableBox<T: Encodable>: Encodable {
  let value: T
  init(_ value: T) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension JSON {
  /// Encode with ISO-8601 dates (JSONCoding.encoder).
  init<T: Encodable>(encoding box: EncodableBox<T>) throws {
    let data = try JSONCoding.encoder.encode(box.value)
    self = try JSONDecoder().decode(JSON.self, from: data)
  }
}

public enum WireError: Error, CustomStringConvertible {
  case malformed(String)

  public var description: String {
    switch self {
    case .malformed(let m): return "malformed message: \(m)"
    }
  }
}
