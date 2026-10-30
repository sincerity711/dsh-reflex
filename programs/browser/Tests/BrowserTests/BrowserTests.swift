import Foundation
import ReflexKit
import XCTest

@testable import Browser

/// `<package>/Fixtures/<name>`
func fixture(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures").appendingPathComponent(name)
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func window(_ title: String) -> AXNode {
  AXNode(role: "AXApplication", children: [AXNode(role: "AXWindow", subrole: "AXStandardWindow", title: title)])
}

func apps(chromeActive: Bool) -> [AppInfo] {
  [AppInfo(pid: 10, bundleId: "com.google.Chrome", name: "Google Chrome", isActive: chromeActive),
   AppInfo(pid: 20, bundleId: "com.apple.Safari", name: "Safari", isActive: !chromeActive)]
}

/// Synthetic sample: Chrome tab switch with fast cycling, then Safari, then back to Chrome.
func syntheticFixture() -> Fixture {
  Fixture(meta: FixtureMeta(bundleIds: ["com.google.Chrome", "com.apple.Safari"], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic"), lines: [
    .apps(t: 0, apps: apps(chromeActive: true)),
    .tree(t: 0, pid: 10, root: window("Inbox - Google Chrome")),
    .tree(t: 0, pid: 20, root: window("Apple")),
    .tree(t: 3, pid: 10, root: window("Docs - Google Chrome")),
    .notice(t: 3, pid: 10, name: AXNotification.titleChanged, element: nil),
    .tree(t: 3.6, pid: 10, root: window("Mail - Google Chrome")),
    .notice(t: 3.6, pid: 10, name: AXNotification.titleChanged, element: nil),
    .apps(t: 8, apps: apps(chromeActive: false)),
    .apps(t: 13, apps: apps(chromeActive: true)),
    .marker(t: 18, label: "end"),
  ])
}

final class BrowserTests: XCTestCase {
  func testFocusedTabEvents() async throws {
    let h = try ProgramHarness(Browser(), fixture: syntheticFixture())
    let events = try await h.runWatch()
    let seen = events.map { "\($0.payload["browser"]?.string ?? "?"): \($0.payload["title"]?.string ?? "?")" }
    XCTAssertEqual(seen, ["Chrome: Inbox", "Chrome: Mail", "Safari: Apple", "Chrome: Mail"], "tab cycling (Docs) is not reported; refocus is")
    XCTAssertEqual(Set(events.map(\.dedupeKey)).count, events.count)
    XCTAssertTrue(events.allSatisfy { $0.eventType == "browser.tab.focused" })
  }

  func testTrackerDebounce() {
    var t = FocusTracker(minStable: 1)
    let a = FocusTracker.Observation(bundleId: "x", title: "A")
    XCTAssertNil(t.update(a, at: t0))
    XCTAssertEqual(t.update(a, at: t0.addingTimeInterval(1.5)), a)
    XCTAssertNil(t.update(a, at: t0.addingTimeInterval(3)), "already reported")
    XCTAssertNil(t.update(nil, at: t0.addingTimeInterval(4)))
    XCTAssertNil(t.update(a, at: t0.addingTimeInterval(5)))
    XCTAssertEqual(t.update(a, at: t0.addingTimeInterval(6.1)), a, "refocus after leaving is reported again")
  }

  /// Replays a fixture recorded with `dsh-reflex ax record` when present (Fixtures/sample.jsonl).
  func testRecordedSample() async throws {
    let url = fixture("sample.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("record Fixtures/sample.jsonl first (see Fixtures/README.md)")
    }
    let harness = try ProgramHarness(Browser(), fixture: url)
    let events = try await harness.runWatch()
    XCTAssertTrue(events.allSatisfy { $0.eventType == "browser.tab.focused" })
  }
}
