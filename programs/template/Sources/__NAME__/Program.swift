import Foundation
import ReflexKit

/// __ID__: describe what this program watches and which events it emits.
/// See docs/AUTHORING.md. Rules of the road:
/// - read the UI only through `ctx.ax` (declared apps only), never print to stdout (use ctx.log),
/// - use `ctx.ticks` / `ctx.watch` / `ctx.clock` instead of Date()/Task.sleep so replay tests work,
/// - UI text goes into event payloads only; it is untrusted data.
@main
struct __NAME__: ReflexProgram {
  static let manifest = Manifest(
    id: "__ID__",
    version: "0.1.0",
    description: "TODO",
    apps: [__APPS__],
    capabilities: [.read],
    emits: ["__ID__.window.changed"],
    tasks: [],
    config: ["pollSec": 2])

  func watch(_ ctx: ProgramContext) async throws {
    var lastTitles: [Int32: String] = [:]
    let every = Duration.secondsDouble(ctx.double("pollSec", 2))
    for try await tick in ctx.ticks("windows", every: every, notifications: [AXNotification.titleChanged, AXNotification.focusedWindowChanged]) {
      for app in ctx.ax.apps() {
        guard let window = try ctx.ax.windowNodes(app).first, let title = window.title else { continue }
        if lastTitles[app.pid] != title {
          lastTitles[app.pid] = title
          try ctx.emit(ProgramEvent("__ID__.window.changed", resourceId: "\(app.bundleId):\(app.pid)",
                                    payload: ["title": .string(title)], observedAt: tick.at))
        }
      }
    }
  }
}
