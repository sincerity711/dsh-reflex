import Foundation
import ReflexKit

/// browser: emits `browser.tab.focused` when the frontmost browser window shows a different tab
/// (its window title changes) or a browser becomes the active app. Reads window titles only.
@main
struct Browser: ReflexProgram {
  static let manifest = Manifest(
    id: "browser",
    version: "0.1.0",
    description: "Edge / Chrome / Safari: focused tab title events (window titles only)",
    apps: ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari"],
    capabilities: [.read],
    emits: ["browser.tab.focused"],
    tasks: [],
    config: [
      "scanSec": 2,
      // A title must stay the same this long before it is reported (tab cycling is not reported).
      "minStableSec": 1.0,
      "titleSuffixes": [" - Google Chrome", " - Microsoft Edge", " - Microsoft\u{200B} Edge", " — Safari"],
    ])

  static let names = ["com.google.Chrome": "Chrome", "com.microsoft.edgemac": "Edge", "com.apple.Safari": "Safari"]

  func watch(_ ctx: ProgramContext) async throws {
    var tracker = FocusTracker(minStable: ctx.double("minStableSec", 1.0))
    let suffixes = ctx.strings("titleSuffixes", [" - Google Chrome", " - Microsoft Edge"])
    let notifications = [AXNotification.titleChanged, AXNotification.focusedWindowChanged, AXNotification.mainWindowChanged]
    for try await tick in ctx.ticks("focus", every: .secondsDouble(ctx.double("scanSec", 2)), notifications: notifications, debounce: .milliseconds(250)) {
      var seen: FocusTracker.Observation?
      if let app = ctx.ax.apps().first(where: \.isActive) {
        do {
          if let title = try ctx.ax.windowNodes(app).first(where: { $0.minimized != true && $0.unlisted != true })?.title, !title.isEmpty {
            seen = .init(bundleId: app.bundleId, title: Self.strip(title, suffixes))
          }
        } catch ReflexError.notTrusted {
          throw ReflexError.notTrusted
        } catch {
          ctx.log.debug("cannot read \(app.bundleId) windows: \(error)")
        }
      }
      guard let focused = tracker.update(seen, at: tick.at) else { continue }
      try ctx.emit(ProgramEvent(
        "browser.tab.focused", resourceId: focused.bundleId, identity: .stable,
        payload: ["app": .string(focused.bundleId), "browser": .string(Self.names[focused.bundleId] ?? focused.bundleId), "title": .string(focused.title)],
        observedAt: tick.at,
        dedupeKey: "browser.tab.focused:\(focused.bundleId):\(FNV1a64.hash(focused.title).prefix(12)):\(Int(tick.at.timeIntervalSince1970))"))
    }
  }

  static func strip(_ title: String, _ suffixes: [String]) -> String {
    for s in suffixes where title.hasSuffix(s) { return String(title.dropLast(s.count)) }
    return title
  }
}

/// Reports a (browser, title) pair once it has been stable for `minStable` seconds.
struct FocusTracker {
  struct Observation: Equatable {
    var bundleId: String
    var title: String
  }

  var minStable: TimeInterval
  private var reported: Observation?
  private var pending: (Observation, since: Date)?

  init(minStable: TimeInterval) { self.minStable = minStable }

  mutating func update(_ o: Observation?, at now: Date) -> Observation? {
    guard let o else {
      pending = nil
      // Leaving the browser resets: coming back to the same tab is a new focus.
      reported = nil
      return nil
    }
    if o == reported { pending = nil; return nil }
    if let p = pending, p.0 == o {
      if now.timeIntervalSince(p.since) >= minStable {
        pending = nil
        reported = o
        return o
      }
      return nil
    }
    pending = (o, now)
    if minStable <= 0 {
      pending = nil
      reported = o
      return o
    }
    return nil
  }
}
