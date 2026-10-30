import Foundation
import ReflexKit

/// Test double used by ReflexHelperCoreTests: echo / wait / crash / hang tasks, optional stall or crash loop.
@main
struct TestProgram: ReflexProgram {
  static let manifest = Manifest(
    id: "testprog",
    version: "0.0.1",
    description: "ReflexKit test program",
    apps: ["com.apple.finder"],
    capabilities: [.read],
    emits: ["testprog.started", "testprog.tick"],
    tasks: ["echo", "wait", "crash", "hang"],
    config: ["crashOnStart": false, "stallWatch": false],
    stallTimeoutSec: 2,
    lingerSec: 1)

  func watch(_ ctx: ProgramContext) async throws {
    if ctx.bool("crashOnStart", false) { exit(5) }
    try ctx.emit(ProgramEvent("testprog.started", resourceId: "testprog", observedAt: ctx.now, origin: .poll))
    for try await _ in ctx.ticks("main", every: .milliseconds(200)) {
      for command in ctx.takeCommands() {
        ctx.reply(ProgramCommandResult(requestId: command.requestId, error: command.action == "echo" ? nil : "unknown_action",
                                      status: ["correlationId": .string(command.correlationId)]))
      }
      if ctx.bool("stallWatch", false) {
        // Block the loop (simulates a stuck program) without returning to the runtime.
        usleep(30_000_000)
      }
    }
  }

  func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult {
    switch task {
    case "echo":
      return .ok(["echo": input])
    case "wait":
      let resumes = (ctx.checkpoint["starts"]?.int ?? 0)
      ctx.checkpoint["starts"] = JSON(resumes + 1)
      try ctx.checkpoint.save()
      for try await _ in ctx.ticks("wait", every: .milliseconds(100)) {}
      return .ok(["resumed": JSON(ctx.isResume), "starts": JSON(resumes + 1), "stopReason": JSON(ctx.stopReason?.rawValue)])
    case "crash":
      exit(9)
    case "hang":
      while true { usleep(1_000_000) }
    default:
      throw ReflexError.unknownTask(task)
    }
  }
}
