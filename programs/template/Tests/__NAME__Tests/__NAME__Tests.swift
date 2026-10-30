import Foundation
import ReflexKit
import XCTest

@testable import __NAME__

/// `<package>/Fixtures/<name>`
func fixture(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures").appendingPathComponent(name)
}

final class __NAME__Tests: XCTestCase {
  /// Replays a fixture recorded with `dsh-reflex ax record --app <bundleId>` (saved as Fixtures/sample.jsonl).
  func testReplay() async throws {
    let url = fixture("sample.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("record Fixtures/sample.jsonl first (see Fixtures/README.md)")
    }
    let harness = try ProgramHarness(__NAME__(), fixture: url)
    let events = try await harness.runWatch()
    XCTAssertFalse(events.isEmpty)
  }
}
