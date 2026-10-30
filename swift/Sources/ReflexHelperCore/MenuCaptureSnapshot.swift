import Foundation
import ReflexKit

/// Reads only the capture belonging to the currently displayed run.
struct MenuCaptureSnapshot {
  let capture: JSON
  let checkpoint: JSON
  let status: JSON

  static func read(tasks: [JSON], runId: String?, correlationId: String? = nil, runCorrelationId: String? = nil) -> MenuCaptureSnapshot {
    guard let runId, !runId.isEmpty,
          let task = tasks.first(where: { $0["program"]?.string == "teams" && $0["task"]?.string == "captureCaptions" && $0["taskId"]?.string == "\(runId).capture" }),
          (correlationId == nil ||
           (task["correlationId"]?.string ?? task["input"]?["correlationId"]?.string ?? runCorrelationId) == correlationId),
          let dir = task["dir"]?.string else {
      return MenuCaptureSnapshot(capture: .null, checkpoint: .null, status: .null)
    }
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    func file(_ name: String, max: Int) -> JSON {
      guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(name)) else { return .null }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: max + 1), data.count <= max else { return .null }
      return (try? JSON.parse(data)) ?? .null
    }
    return MenuCaptureSnapshot(capture: task, checkpoint: file("checkpoint.json", max: 8_000_000), status: file("status.json", max: 16_384))
  }
}
