import Foundation
import XCTest

@testable import ReflexKit

let exampleBundle = "com.example.app"

func exampleTree(_ title: String, rows: [(id: String, speaker: String, text: String)] = []) -> AXNode {
  AXNode(role: "AXApplication", title: "Example", children: [
    AXNode(role: "AXWindow", subrole: "AXStandardWindow", title: title, children: [
      AXNode(role: "AXGroup", domId: "list", children: rows.map { r in
        AXNode(role: "AXGroup", domClasses: ["row"], chromeId: r.id, children: [
          AXNode(role: "AXStaticText", value: r.speaker), AXNode(role: "AXStaticText", value: r.text),
        ])
      }),
    ]),
  ])
}

func exampleFixture() -> Fixture {
  let start = Date(timeIntervalSince1970: 1_000_000)
  let meta = FixtureMeta(bundleIds: [exampleBundle], startedAt: start, redaction: .none, limits: ReadLimits(), tool: "test")
  return Fixture(meta: meta, lines: [
    .apps(t: 0, apps: [AppInfo(pid: 100, bundleId: exampleBundle, name: "Example")]),
    .tree(t: 0, pid: 100, root: exampleTree("Hello | Example")),
    .notice(t: 4.9, pid: 100, name: AXNotification.titleChanged, element: nil),
    .tree(t: 5, pid: 100, root: exampleTree("World | Example", rows: [("1", "Alice", "Hi")])),
    .tree(t: 6, pid: 100, root: exampleTree("World | Example", rows: [("1", "Alice", "Hi there")])),
    .tree(t: 7, pid: 100, root: exampleTree("World | Example", rows: [("2", "Bob", "Yes")])),
    .tree(t: 12, pid: 100, root: exampleTree("Bye | Example")),
  ])
}

struct TitleWatcher: ReflexProgram {
  static let manifest = Manifest(id: "example", apps: [exampleBundle], emits: ["example.title.changed"], tasks: ["collect"])

  func watch(_ ctx: ProgramContext) async throws {
    var last: String?
    for try await tick in ctx.ticks("titles", every: .seconds(2), notifications: [AXNotification.titleChanged]) {
      for app in ctx.ax.apps() {
        let title = try ctx.ax.windowNodes(app).first?.title
        if title != last {
          last = title
          try ctx.emit(ProgramEvent("example.title.changed", resourceId: "w", payload: ["title": JSON(title)], observedAt: tick.at))
        }
      }
    }
  }

  func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult {
    var seen: [JSON] = []
    let watch = ctx.watch("rows", every: .milliseconds(500)) {
      guard let app = ctx.ax.apps().first, let w = try ctx.ax.windows(app).first else { return nil }
      return try ctx.ax.read(w).first(.domId("list"))
    }
    for try await update in watch where update.changed {
      let rows = update.node?.all(.domClass("row")).map { JSON($0.texts().joined(separator: ": ")) } ?? []
      seen.append(.array(rows))
    }
    try ctx.write("rows.json", JSON.array(seen).serialized())
    return .ok(["snapshots": .array(seen), "stopReason": JSON(ctx.stopReason?.rawValue)])
  }
}

final class ReplayTests: XCTestCase {
  func testReplayStateFollowsVirtualTime() throws {
    let replay = ReplayAX(fixture: exampleFixture())
    let app = replay.runningApps([exampleBundle]).first!
    XCTAssertEqual(try replay.windowList(app).first?.title, "Hello | Example")
    replay.advance(to: replay.date(at: 6.5))
    XCTAssertEqual(try replay.windowList(app).first?.title, "World | Example")
    let w = try replay.windows(app).first!
    let row = try replay.find(in: w, .domClass("row"), .first).first!
    XCTAssertEqual(try replay.read(row.ref!, ReadLimits()).texts(), ["Alice", "Hi there"])
    // Identity by Chromium id: after the row is replaced (new id), the old ref is gone.
    replay.advance(to: replay.date(at: 7.5))
    XCTAssertThrowsError(try replay.read(row.ref!, ReadLimits()))
  }

  func testNoticesAreDeliveredOnAdvance() throws {
    let replay = ReplayAX(fixture: exampleFixture())
    let got = Locked([String]())
    let sub = try replay.subscribe(pid: 100, notifications: [AXNotification.titleChanged]) { n in got.withLock { $0.append(n.name) } }
    replay.advance(to: replay.date(at: 5))
    XCTAssertEqual(got.current, [AXNotification.titleChanged])
    sub.cancel()
  }

  func testWatchLoopOnVirtualTime() async throws {
    let h = try ProgramHarness(TitleWatcher(), fixture: exampleFixture())
    let events = try await h.runWatch()
    XCTAssertEqual(events.map { $0.payload["title"]?.string }, ["Hello | Example", "World | Example", "Bye | Example"])
    // The notice at 4.9s (+200ms debounce) wakes the loop before the 6s timer tick.
    XCTAssertEqual(events[1].observedAt.timeIntervalSince(h.replay.startedAt), 5.1, accuracy: 0.01)
  }

  func testTaskStopsAtVirtualStopTime() async throws {
    let h = try ProgramHarness(TitleWatcher(), fixture: exampleFixture())
    let result = try await h.runTask("collect", stopAt: 10)
    XCTAssertEqual(result.status, "ok")
    XCTAssertEqual(result.output["stopReason"]?.string, "stopOn")
    let snapshots = result.output["snapshots"]?.array ?? []
    XCTAssertEqual(snapshots.map { $0.array?.compactMap(\.string) ?? [] }, [[], ["Alice: Hi"], ["Alice: Hi there"], ["Bob: Yes"]])
  }
}

final class GuardTests: XCTestCase {
  func context(_ manifest: Manifest, granted: Set<String> = []) -> (ProgramContext, CollectingSink) {
    let sink = CollectingSink()
    let core = RuntimeCore(manifest: manifest, source: ReplayAX(fixture: exampleFixture()), sink: sink, config: [:], grantedActions: granted, dev: false)
    return (ProgramContext(core: core, dataDir: FileManager.default.temporaryDirectory, stop: StopController()), sink)
  }

  func testUndeclaredEventIsRejected() {
    let (ctx, sink) = context(TitleWatcher.manifest)
    XCTAssertThrowsError(try ctx.emit(ProgramEvent("example.other.thing", resourceId: "x")))
    XCTAssertTrue(sink.events.isEmpty)
  }

  func testUndeclaredAppIsRejected() {
    let (ctx, _) = context(Manifest(id: "other", apps: ["com.other.app"]))
    let foreign = AppInfo(pid: 100, bundleId: exampleBundle, name: "Example")
    XCTAssertThrowsError(try ctx.ax.windows(foreign))
    XCTAssertTrue(ctx.ax.apps().isEmpty)
  }

  func testActionsNeedDeclarationAndGrant() throws {
    let m = Manifest(id: "example", apps: [exampleBundle], capabilities: [.read, .perform], actions: [ActionDecl("press", "Press the button")])
    let (denied, _) = context(m)
    let app = denied.ax.apps().first!
    let ref = try denied.ax.appRef(app)
    XCTAssertThrowsError(try denied.ax.perform("press", on: ref))
    let (allowed, sink) = context(m, granted: ["press"])
    XCTAssertNoThrow(try allowed.ax.perform("press", on: ref))
    XCTAssertTrue(sink.logs.contains { $0.level == "audit" })
    XCTAssertThrowsError(try allowed.ax.perform("undeclared", on: ref))
  }

  func testPrepareWebNeedsCapability() async {
    let (ctx, _) = context(TitleWatcher.manifest)
    let app = ctx.ax.apps().first!
    do {
      _ = try await ctx.ax.prepareWeb(app)
      XCTFail("expected capability error")
    } catch {}
  }

  func testTaskFilesStayInTaskDir() throws {
    let sink = CollectingSink()
    let core = RuntimeCore(manifest: TitleWatcher.manifest, source: ReplayAX(fixture: exampleFixture()), sink: sink, config: [:], grantedActions: [], dev: false)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ctx = TaskContext(core: core, dataDir: dir, start: TaskStartMessage(taskId: "t", task: "collect", input: [:], dir: dir.path, resume: false), stop: StopController())
    XCTAssertThrowsError(try ctx.file("../escape.txt"))
    XCTAssertNoThrow(try ctx.write("ok.txt", "fine"))
  }
}
