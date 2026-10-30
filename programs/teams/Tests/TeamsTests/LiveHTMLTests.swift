import AppKit
import ApplicationServices
import Foundation
import XCTest

@testable import ReflexKit
@testable import Teams

/// Opt-in live AX test against examples/fixtures/teams-like.html in Microsoft Edge.
/// Run from a terminal that has Accessibility permission:
///   REFLEX_AX_INTEGRATION=1 swift test --filter LiveHTMLTests
final class LiveHTMLTests: XCTestCase {
  func testCaptionsFromTeamsLikePage() async throws {
    guard ProcessInfo.processInfo.environment["REFLEX_AX_INTEGRATION"] == "1" else { throw XCTSkip("set REFLEX_AX_INTEGRATION=1") }
    guard AXIsProcessTrusted() else { throw XCTSkip("this process has no Accessibility permission") }
    let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("../../examples/fixtures/teams-like.html").standardizedFileURL
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-a", "Microsoft Edge", page.path]
    try open.run()
    open.waitUntilExit()

    let manifest = Manifest(id: "teams-html", apps: ["com.microsoft.edgemac"], capabilities: [.read, .prepareWeb])
    let core = RuntimeCore(manifest: manifest, source: LiveAX(), sink: CollectingSink(), config: Teams.manifest.config, grantedActions: [], dev: true)
    let ctx = ProgramContext(core: core, dataDir: FileManager.default.temporaryDirectory, stop: StopController())
    guard let app = ctx.ax.apps().first else { throw XCTSkip("Edge is not running") }
    _ = try await ctx.ax.prepareWeb(app, verifyWithin: .seconds(5))
    let locator = CaptionLocator(ctx: ctx)
    var assembler = CaptionAssembler()
    let start = Date()
    while Date().timeIntervalSince(start) < 18 {
      if let node = try locator.locate(now: Date()) {
        _ = assembler.ingest(TeamsUI.captionEntries(in: node, entryClass: locator.sel.entryClass), at: Date())
      } else {
        _ = assembler.ingest([], at: Date())
      }
      try await Task.sleep(nanoseconds: 300_000_000)
    }
    assembler.finalizeAll()
    let got = assembler.lines.map { [$0.speaker, $0.text] }
    XCTAssertEqual(got, [["Alice", "Hello everyone, let us start"], ["Bob", "Sure, I can begin"], ["Alice", "Great"], ["Bob", "Next topic is the release"]])
    XCTAssertNotNil(locator.clock())
  }
}
