import Foundation
@testable import ReflexKit
import XCTest

@testable import Teams

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

final class MeetingTrackerTests: XCTestCase {
  func obs(_ s: Double, _ inMeeting: Bool, title: String? = "Standup", clock: String? = nil, app: Bool = true, popout: Bool = false,
           minimized: Bool = false, offScreen: Bool = false, compact: Bool = false) -> MeetingObservation {
    MeetingObservation(at: at(s), appRunning: app, inMeeting: inMeeting, title: title, clock: clock, captionsWindow: popout,
                       meetingWindowMinimized: minimized, meetingWindowOffScreen: offScreen, compactView: compact)
  }

  /// "mm:ss" of a timer that started at 0 s.
  func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

  func testStartLeaveRejoinWithinGraceIsOneMeeting() {
    var t = MeetingTracker()
    t.leaveGrace = 120
    guard case .started(let m) = t.update(obs(0, true)).first else { return XCTFail() }
    XCTAssertTrue(t.update(obs(10, false)).isEmpty)
    XCTAssertEqual(t.label, "leave_pending")
    XCTAssertEqual(t.update(obs(60, true)), [.rejoined(t.meeting!)])
    XCTAssertEqual(t.meeting?.correlationId, m.correlationId)
    XCTAssertEqual(t.label, "in_meeting")
  }

  func testZeroGraceUsesSafeDefault() {
    var t = MeetingTracker()
    t.leaveGrace = 0
    _ = t.update(obs(0, true))
    XCTAssertTrue(t.update(obs(10, false)).isEmpty)
    XCTAssertEqual(t.deadline, at(130))
    XCTAssertTrue(t.update(obs(129, false)).isEmpty)
    guard case .ended(_, let reason, let end) = t.update(obs(130, false)).first else { return XCTFail() }
    XCTAssertEqual(reason, "detection_timeout")
    XCTAssertEqual(end, at(130))
  }

  func testEndsOnlyAfterGrace() {
    var t = MeetingTracker()
    t.leaveGrace = 120
    _ = t.update(obs(0, true))
    _ = t.update(obs(100, false))
    XCTAssertTrue(t.update(obs(200, false)).isEmpty)
    let out = t.update(obs(221, false))
    guard case .ended(_, let reason, let endedAt) = out.first else { return XCTFail("\(out)") }
    XCTAssertEqual(reason, "detection_timeout")
    XCTAssertEqual(endedAt, at(221))
    XCTAssertEqual(t.label, "idle")
  }

  func testAppQuitEndsAfterGraceWithReason() {
    var t = MeetingTracker()
    t.leaveGrace = 30
    _ = t.update(obs(0, true))
    _ = t.update(obs(5, false, app: false))
    guard case .ended(_, let reason, _) = t.update(obs(40, false, app: false)).first else { return XCTFail() }
    XCTAssertEqual(reason, "detection_timeout")
  }

  func testTitleChangeAfterMissingScanDoesNotSplitMeeting() {
    var t = MeetingTracker()
    guard case .started(let a) = t.update(obs(0, true, title: "Standup")).first else { return XCTFail() }
    _ = t.update(obs(10, false))
    let out = t.update(obs(20, true, title: "Meeting compact view | Standup"))
    XCTAssertEqual(out.count, 1)
    guard case .rejoined = out[0] else { return XCTFail() }
    XCTAssertEqual(t.meeting?.correlationId, a.correlationId)
    XCTAssertEqual(t.meeting?.title, "Standup")
  }

  func testCompactViewFreezesCaptionsAndWarnsOncePerEpisode() {
    var t = MeetingTracker()
    t.frozenAfter = 5
    _ = t.update(obs(0, true, clock: clock(0)))
    XCTAssertTrue(t.update(obs(2, true, clock: clock(2), compact: true)).isEmpty)
    XCTAssertTrue(t.update(obs(6, true, clock: clock(6), compact: true)).isEmpty)
    let out = t.update(obs(7, true, clock: clock(7), compact: true))
    guard case .frozen(let m, let cause) = out.first else { return XCTFail("\(out)") }
    XCTAssertEqual(cause, "compact_view")
    XCTAssertEqual(m.freezeEpisodes, 1)
    XCTAssertEqual(t.meeting?.frozenSince, at(2))
    XCTAssertTrue(t.update(obs(30, true, clock: clock(30), compact: true)).isEmpty, "one warning per episode")
    XCTAssertEqual(t.label, "in_meeting")
    XCTAssertTrue(t.update(obs(32, true, clock: clock(32))).isEmpty)
    XCTAssertNil(t.meeting?.frozenSince)
    // A new episode is reported again.
    _ = t.update(obs(40, true, clock: clock(40), minimized: true, compact: true))
    guard case .frozen(_, let cause2) = t.update(obs(45, true, clock: clock(45), minimized: true, compact: true)).first else { return XCTFail() }
    XCTAssertEqual(cause2, "minimized")
  }

  func testCallWindowOnAnotherSpaceIsPaused() {
    var t = MeetingTracker()
    t.frozenAfter = 20
    _ = t.update(obs(0, true, clock: clock(0)))
    // Full screen, then the user switches to another desktop: the call window's timer stops where it was.
    XCTAssertTrue(t.update(obs(10, true, clock: clock(10), offScreen: true, compact: true)).isEmpty)
    XCTAssertTrue(t.update(obs(25, true, clock: clock(10), offScreen: true, compact: true)).isEmpty)
    let out = t.update(obs(31, true, clock: clock(10), offScreen: true, compact: true))
    guard case .frozen(_, let cause) = out.first else { return XCTFail("\(out)") }
    XCTAssertEqual(cause, "off_screen", "a paused window's timer is not a stalled page")
    XCTAssertEqual(t.label, "in_meeting")
    // Back on its desktop: the timer jumps ahead and nothing else is reported.
    XCTAssertTrue(t.update(obs(40, true, clock: clock(40))).isEmpty)
    XCTAssertTrue(t.update(obs(70, true, clock: clock(70))).isEmpty)
    XCTAssertEqual(t.meeting?.freezeEpisodes, 1)
  }

  func testQuickLookAtTheChatListIsNotAFreeze() {
    var t = MeetingTracker()
    t.frozenAfter = 20
    _ = t.update(obs(0, true, clock: clock(0)))
    XCTAssertTrue(t.update(obs(2, true, clock: clock(2), compact: true)).isEmpty)
    XCTAssertTrue(t.update(obs(8, true, clock: clock(8), compact: true)).isEmpty)
    XCTAssertTrue(t.update(obs(10, true, clock: clock(10))).isEmpty)
    XCTAssertTrue(t.update(obs(40, true, clock: clock(40))).isEmpty)
    XCTAssertEqual(t.meeting?.freezeEpisodes, 0)
  }

  func testPoppedOutCaptionsKeepGoingWhileMinimized() {
    var t = MeetingTracker()
    t.frozenAfter = 10
    _ = t.update(obs(0, true, clock: clock(0), popout: true))
    XCTAssertTrue(t.update(obs(5, true, clock: clock(5), popout: true, minimized: true, compact: true)).isEmpty)
    XCTAssertTrue(t.update(obs(30, true, clock: clock(30), popout: true, minimized: true, compact: true)).isEmpty)
  }

  func testStalledTimerMeansThePageStopped() {
    var t = MeetingTracker()
    t.frozenAfter = 20
    _ = t.update(obs(0, true, clock: "00:01"))
    _ = t.update(obs(5, true, clock: "00:06"))
    XCTAssertTrue(t.update(obs(20, true, clock: "00:06")).isEmpty)
    let out = t.update(obs(26, true, clock: "00:06"))
    guard case .frozen(let m, let cause) = out.first else { return XCTFail("\(out)") }
    XCTAssertEqual(cause, "stalled")
    XCTAssertEqual(m.frozenSince, at(5))
    XCTAssertTrue(t.update(obs(40, true, clock: "00:06")).isEmpty, "one warning per episode")
    _ = t.update(obs(45, true, clock: "00:46"))
    XCTAssertNil(t.meeting?.frozenSince)
  }

  func testTitleChromeIsStripped() {
    let siblings = ["Standup | Microsoft Teams", "Meeting compact view | Standup | Microsoft Teams", "Standup | Microsoft Teams | Live captions",
                    "Chat | Standup | Microsoft Teams"]
    let strip = { TeamsUI.stripChrome($0, siblings: siblings, suffix: "| Microsoft Teams") }
    XCTAssertEqual(strip("Standup | Microsoft Teams"), "Standup")
    XCTAssertEqual(strip("Meeting compact view | Standup | Microsoft Teams"), "Standup")
    XCTAssertEqual(strip("Standup | Microsoft Teams | Live captions"), "Standup")
    XCTAssertEqual(TeamsUI.stripChrome("Roadmap | Q3 | Microsoft Teams", siblings: ["Roadmap | Q3 | Microsoft Teams"], suffix: "| Microsoft Teams"), "Roadmap | Q3")
    XCTAssertEqual(TeamsUI.stripChrome("Q3 planning | Microsoft Teams", siblings: ["Q3 | Microsoft Teams"], suffix: "| Microsoft Teams"), "Q3 planning",
                   "only whole segments count")
    XCTAssertEqual(TeamsUI.parseClock("Elapsed time 1:02:03"), 3723)
    XCTAssertEqual(TeamsUI.parseClock("31:01"), 1861)
    // The timer group's own title is stale in Teams 26246: only the text inside counts.
    let timer = AXNode(role: "AXGroup", subrole: "AXTimeGroup", title: "Elapsed time 01:18", domId: "call-duration-custom",
                       children: [AXNode(role: "AXGroup", children: [AXNode(role: "AXStaticText", value: "23:30")])])
    XCTAssertEqual(TeamsUI.clockText(timer), "23:30")
    XCTAssertNil(TeamsUI.clockText(AXNode(role: "AXGroup", title: "Elapsed time 01:18")))
  }
}

final class CaptionAssemblerTests: XCTestCase {
  func e(_ id: String, _ speaker: String, _ text: String) -> CaptionEntry { CaptionEntry(id: id, speaker: speaker, text: text) }

  func testInPlaceRevisionThenFinalOnDisappear() {
    var a = CaptionAssembler()
    _ = a.ingest([e("1", "Alice", "Hello")], at: at(0))
    _ = a.ingest([e("1", "Alice", "Hello everyone")], at: at(1))
    XCTAssertEqual(a.lines.count, 1)
    XCTAssertEqual(a.lines[0].text, "Hello everyone")
    XCTAssertEqual(a.lines[0].revisions, 1)
    XCTAssertFalse(a.lines[0].final)
    let changes = a.ingest([e("2", "Bob", "Hi")], at: at(2))
    XCTAssertTrue(changes.contains(.finalized(0, why: "disappeared")))
  }

  func testRerenderWithNewIdIsTheSameLine() {
    var a = CaptionAssembler()
    _ = a.ingest([e("1", "Alice", "Great"), e("2", "Bob", "Next")], at: at(0))
    _ = a.ingest([e("2", "Bob", "Next")], at: at(1))
    _ = a.ingest([e("2", "Bob", "Next"), e("9", "Alice", "Great")], at: at(5))
    XCTAssertEqual(a.lines.map(\.text), ["Great", "Next"])
    XCTAssertEqual(a.lines[0].ids, ["1", "9"])
  }

  func testPrefixDedupeOnlyWithinWindowAndSameSpeaker() {
    var a = CaptionAssembler()
    a.rewriteWindow = 30
    _ = a.ingest([e("1", "Alice", "All right, so this is planning")], at: at(0))
    _ = a.ingest([], at: at(1))
    _ = a.ingest([e("2", "Alice", "All right")], at: at(10))
    XCTAssertEqual(a.lines.count, 1, "a shorter re-read within the window is the same line")
    _ = a.ingest([], at: at(11))
    _ = a.ingest([e("3", "Alice", "All right")], at: at(100))
    XCTAssertEqual(a.lines.count, 2, "outside the window it is a new utterance")
    _ = a.ingest([e("4", "Bob", "All right")], at: at(101))
    XCTAssertEqual(a.lines.count, 3, "another speaker is never merged")
  }

  func testSupersededAndStableFinalization() {
    var a = CaptionAssembler()
    a.stableAfter = 6
    _ = a.ingest([e("1", "Alice", "One")], at: at(0))
    let sup = a.ingest([e("1", "Alice", "One"), e("2", "Alice", "Two")], at: at(1))
    XCTAssertTrue(sup.contains(.finalized(0, why: "superseded")))
    let stable = a.ingest([e("1", "Alice", "One"), e("2", "Alice", "Two")], at: at(8))
    XCTAssertTrue(stable.contains(.finalized(1, why: "stable")))
  }

  func testGapsAndTranscript() {
    var a = CaptionAssembler()
    _ = a.ingest([e("1", "Alice", "Hello")], at: at(0))
    _ = a.ingest([e("2", "Alice", "Second line")], at: at(5))
    a.beginGap("window_frozen", at: at(10))
    a.endGap(at: at(70))
    _ = a.ingest([e("3", "Bob", "After the gap")], at: at(80))
    a.finalizeAll()
    let t = Transcript(title: "Standup", startedAt: at(0), endedAt: at(90), assembler: a)
    let md = t.markdown()
    XCTAssertTrue(md.contains("Alice**: Hello Second line"), md)
    XCTAssertTrue(md.contains("[Gap"), md)
    XCTAssertTrue(md.contains("minimized, fully covered or on another desktop"), md)
    XCTAssertLessThan(md.range(of: "[Gap")!.lowerBound, md.range(of: "After the gap")!.lowerBound)
    XCTAssertEqual(t.lineCount, 3)
    XCTAssertEqual(Transcript.shard(String(repeating: "para\n\n", count: 100), maxBytes: 60).count, 10)
  }
}

// MARK: - replay of a synthetic Teams-like fixture

enum TeamsFixture {
  static let bundle = "com.microsoft.teams2"

  static func entry(_ id: String, _ speaker: String, _ text: String) -> AXNode {
    AXNode(role: "AXGroup", domClasses: ["fui-ChatMessageCompact__body"], chromeId: id, children: [
      AXNode(role: "AXStaticText", value: speaker), AXNode(role: "AXStaticText", value: text),
    ])
  }

  enum CallWindow { case normal, minimized }

  /// Teams as observed on 26246: the call window holds the anchors and the caption panel; minimized it
  /// becomes an AXDialog and a compact view (AXSystemDialog with anchors) floats; popped-out captions
  /// live in an AXSystemDialog without anchors.
  static func app(meeting: Bool, clock: String = "00:01", entries: [AXNode] = [], call: CallWindow = .normal, popout: [AXNode]? = nil) -> AXNode {
    var windows = [AXNode(role: "AXWindow", subrole: "AXStandardWindow", title: "Chat | Microsoft Teams", domId: "app-root",
                          children: [AXNode(role: "AXGroup", domId: "chat-list")])]
    func timer() -> AXNode {
      AXNode(role: "AXGroup", subrole: "AXTimeGroup", title: "Elapsed time 00:01", domId: "call-duration-custom",
             children: [AXNode(role: "AXGroup", children: [AXNode(role: "AXStaticText", value: clock)])])
    }
    if meeting {
      var stage = [AXNode(role: "AXButton", title: "Leave", domId: "hangup-button"), timer()]
      if popout == nil { stage += [AXNode(role: "AXButton", domId: "captions-panel-dismiss-button"), AXNode(role: "AXList", children: entries)] }
      windows.append(AXNode(role: "AXWindow", subrole: call == .minimized ? "AXDialog" : "AXStandardWindow", title: "Standup | Microsoft Teams",
                            minimized: call == .minimized, children: [AXNode(role: "AXGroup", domId: "meeting-stage", children: stage)]))
      if call == .minimized {
        windows.append(AXNode(role: "AXWindow", subrole: "AXSystemDialog", title: "Meeting compact view | Standup | Microsoft Teams", children: [
          AXNode(role: "AXGroup", children: [AXNode(role: "AXButton", title: "Leave", domId: "hangup-button"), timer()]),
        ]))
      }
      if let popout {
        windows.append(AXNode(role: "AXWindow", subrole: "AXSystemDialog", title: "Standup | Microsoft Teams | Live captions", children: [
          AXNode(role: "AXGroup", children: [
            AXNode(role: "AXPopUpButton", domId: "captions-settings-menu-trigger-button-non-overflow"), AXNode(role: "AXList", children: popout),
          ]),
        ]))
      }
    }
    return AXNode(role: "AXApplication", title: "Microsoft Teams", children: windows)
  }

  static func fixture(leaveAt: Double = 45, end: Double = 60) -> Fixture {
    let meta = FixtureMeta(bundleIds: [bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic")
    let early = [entry("2", "Bob", "Sure, I can begin"), entry("3", "Alice", "Great")]
    var lines: [FixtureLine] = [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: bundle, name: "Microsoft Teams")]),
      .tree(t: 0, pid: 42, root: app(meeting: false)),
      .tree(t: 4, pid: 42, root: app(meeting: true, clock: "00:01")),
      .tree(t: 6, pid: 42, root: app(meeting: true, clock: "00:03", entries: [entry("1", "Alice", "Hello")])),
      .tree(t: 7, pid: 42, root: app(meeting: true, clock: "00:04", entries: [entry("1", "Alice", "Hello everyone")])),
      .tree(t: 9, pid: 42, root: app(meeting: true, clock: "00:06", entries: [entry("1", "Alice", "Hello everyone, let's start"), entry("2", "Bob", "Sure")])),
      .tree(t: 11, pid: 42, root: app(meeting: true, clock: "00:08", entries: early)),
    ]
    // 12…40: call window minimized — the timer keeps running, the caption list stands still.
    for s in stride(from: 12.0, through: 40, by: 4) {
      lines.append(.tree(t: s, pid: 42, root: app(meeting: true, clock: String(format: "00:%02d", Int(s) - 3), entries: early, call: .minimized)))
    }
    lines += [
      .tree(t: 41, pid: 42, root: app(meeting: true, clock: "00:38", entries: [entry("5", "Alice", "Great"), entry("4", "Bob", "Next topic")])),
      .tree(t: 43, pid: 42, root: app(meeting: true, clock: "00:40", entries: [entry("4", "Bob", "Next topic")])),
      .tree(t: leaveAt, pid: 42, root: app(meeting: false)),
      .marker(t: end, label: "end"),
    ]
    return Fixture(meta: meta, lines: lines)
  }

  /// Same meeting with popped-out captions: minimizing the call window does not stop them.
  static func popoutFixture() -> Fixture {
    let meta = FixtureMeta(bundleIds: [bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic")
    var lines: [FixtureLine] = [.apps(t: 0, apps: [AppInfo(pid: 42, bundleId: bundle, name: "Microsoft Teams")])]
    let said = [(4.0, "1", "Hello"), (8.0, "1", "Hello everyone"), (16.0, "2", "Budget first"), (24.0, "3", "Then hiring"), (32.0, "4", "Done")]
    var rows: [AXNode] = []
    for s in stride(from: 2.0, through: 36, by: 2) {
      for (t, id, text) in said where t == s {
        rows.removeAll { $0.chromeId == id }
        rows.append(entry(id, "Alice", text))
      }
      lines.append(.tree(t: s, pid: 42, root: app(meeting: true, clock: String(format: "00:%02d", Int(s)), call: s >= 12 ? .minimized : .normal, popout: rows)))
    }
    lines.append(.marker(t: 40, label: "end"))
    return Fixture(meta: meta, lines: lines)
  }
}

final class TeamsReplayTests: XCTestCase {
  func testLocatorReplacesAStillReadableStaleCaptionContainer() throws {
    var before = TeamsFixture.app(meeting: true, entries: [TeamsFixture.entry("old-row", "Speaker", "Old words")])
    before.children[1].children[0].children[3].chromeId = "old-list"
    var after = TeamsFixture.app(meeting: true, entries: [TeamsFixture.entry("new-row", "Speaker", "Current words")])
    after.children[1].children[0].children[3].chromeId = "new-list"
    // The old handle keeps answering, but is no longer the meeting window's caption list.
    after.children[0].children.append(before.children[1].children[0].children[3])
    let fixture = Fixture(meta: FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "stale-list"), lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Teams")]),
      .tree(t: 0, pid: 42, root: before), .tree(t: 2, pid: 42, root: after),
    ])
    let source = ReplayAX(fixture: fixture)
    let core = RuntimeCore(manifest: Teams.manifest, source: source, sink: CollectingSink(), config: Teams.manifest.config, grantedActions: [], dev: true)
    let ctx = ProgramContext(core: core, dataDir: FileManager.default.temporaryDirectory, stop: StopController())
    let locator = CaptionLocator(ctx: ctx)
    let old = try XCTUnwrap(locator.locate(now: at(0)))
    source.advance(to: at(2))
    XCTAssertEqual(try source.read(try XCTUnwrap(old.ref), CaptionLocator.limits).texts().last, "Old words")
    let current = try XCTUnwrap(locator.locate(now: at(2)))
    XCTAssertEqual(TeamsUI.captionEntries(in: current, entryClass: locator.sel.entryClass).last?.text, "Current words")
  }

  func testLongCaptionListReadsNewestRowsWithinTheSameBudget() throws {
    let rows = (0..<500).map { TeamsFixture.entry("row-\($0)", "Speaker", "Caption \($0)") }
    let latest = TeamsFixture.entry("row-500", "Speaker", "Newest words")
    let meta = FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "long-list")
    let fixture = Fixture(meta: meta, lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Teams")]),
      .tree(t: 0, pid: 42, root: TeamsFixture.app(meeting: true, entries: rows)),
      .tree(t: 1, pid: 42, root: TeamsFixture.app(meeting: true, entries: rows + [latest])),
    ])
    let source = ReplayAX(fixture: fixture)
    let core = RuntimeCore(manifest: Teams.manifest, source: source, sink: CollectingSink(), config: Teams.manifest.config, grantedActions: [], dev: true)
    let ctx = ProgramContext(core: core, dataDir: FileManager.default.temporaryDirectory, stop: StopController())
    let locator = CaptionLocator(ctx: ctx)
    let initial = try XCTUnwrap(locator.locate(now: at(0)))
    let entries = TeamsUI.captionEntries(in: initial, entryClass: locator.sel.entryClass)
    XCTAssertEqual(entries.last?.text, "Caption 499")
    XCTAssertLessThanOrEqual(initial.nodeCount, 400)
    XCTAssertGreaterThan(locator.omittedChildren, 0)
    XCTAssertTrue(entries.allSatisfy { $0.speaker == "Speaker" }, "tail traversal preserves speaker/text order")
    XCTAssertEqual(entries.map(\.id), entries.map(\.id).sorted { Int($0.dropFirst(4))! < Int($1.dropFirst(4))! })
    var legacy = CaptionLocator.limits; legacy.tailFirst = nil
    let head = try source.read(try XCTUnwrap(initial.ref), legacy)
    XCTAssertNotEqual(TeamsUI.captionEntries(in: head, entryClass: locator.sel.entryClass).last?.text, "Caption 499")
    source.advance(to: at(1))
    let updated = try XCTUnwrap(locator.locate(now: at(1)))
    XCTAssertEqual(TeamsUI.captionEntries(in: updated, entryClass: locator.sel.entryClass).last?.text, "Newest words")
    XCTAssertLessThanOrEqual(updated.nodeCount, 400)
    let lastRow = try XCTUnwrap(updated.all(.domClass(locator.sel.entryClass)).last)
    XCTAssertEqual(try source.read(try XCTUnwrap(lastRow.ref), ReadLimits()).texts(), ["Speaker", "Newest words"], "reversed traversal preserves real ref paths")
    let fragment = AXNode(domClasses: [locator.sel.entryClass], chromeId: "fragment", omittedChildren: 1,
      children: [AXNode(role: "AXStaticText", value: "partial"), AXNode(role: "AXStaticText", value: "text")])
    XCTAssertTrue(TeamsUI.captionEntries(in: fragment, entryClass: locator.sel.entryClass).isEmpty)
  }

  func testWatchEmitsStartedThenEndedAfterGrace() async throws {
    let h = try ProgramHarness(Teams(), fixture: TeamsFixture.fixture(), config: ["leaveGraceSec": 10, "scanSec": 2])
    let events = try await h.runWatch()
    let types = events.map(\.eventType)
    XCTAssertEqual(types.filter { $0 != "teams.captions.unavailable" }, ["teams.meeting.started", "teams.meeting.ended"])
    let started = events.first { $0.eventType == "teams.meeting.started" }!
    let ended = events.first { $0.eventType == "teams.meeting.ended" }!
    XCTAssertEqual(started.payload["title"]?.string, "Standup")
    XCTAssertEqual(started.correlationId, ended.correlationId)
    XCTAssertEqual(started.identity, .heuristic)
    XCTAssertEqual(started.observedAt.timeIntervalSince(t0), 4, accuracy: 0.01)
    XCTAssertEqual(ended.payload["reason"]?.string, "detection_timeout")
    // The minimized call window (12…40 s) is reported once, after frozenAfter; the meeting goes on.
    let frozen = events.filter { $0.payload["reason"]?.string == "window_frozen" }
    XCTAssertEqual(frozen.count, 1)
    XCTAssertEqual(frozen.first?.payload["cause"]?.string, "minimized")
    XCTAssertEqual(frozen[0].observedAt.timeIntervalSince(t0), 18, accuracy: 2.1)
    XCTAssertTrue(frozen[0].observedAt < ended.observedAt)
  }

  func testRestartedProgramDoesNotStartTheMeetingAgain() async throws {
    let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("teams-\(UUID().uuidString)")
    let first = try ProgramHarness(Teams(), fixture: TeamsFixture.fixture(), config: ["leaveGraceSec": 10], dataDir: dataDir)
    let a = try await first.runWatch(until: 20)
    XCTAssertEqual(a.map(\.eventType).filter { $0 == "teams.meeting.started" }.count, 1)
    let second = try ProgramHarness(Teams(), fixture: TeamsFixture.fixture(), config: ["leaveGraceSec": 10], dataDir: dataDir)
    second.advance(to: 20)
    let b = try await second.runWatch()
    XCTAssertEqual(b.map(\.eventType).filter { $0 == "teams.meeting.started" }.count, 0)
    XCTAssertEqual(b.first { $0.eventType == "teams.meeting.ended" }?.correlationId, a.first?.correlationId)
  }

  func testCaptureTaskWritesRecordWithGap() async throws {
    let h = try ProgramHarness(Teams(), fixture: TeamsFixture.fixture(), config: ["frozenAfterSec": 10, "captionPollMs": 1000])
    h.advance(to: 4)
    let result = try await h.runTask("captureCaptions", input: ["title": "Standup", "correlationId": "c1"], stopAt: 46)
    XCTAssertEqual(result.status, "partial", "\(result)")
    XCTAssertEqual(result.output["lines"]?.int, 4)
    XCTAssertEqual(result.output["speakers"]?.int, 2)
    XCTAssertGreaterThanOrEqual(result.output["gaps"]?.int ?? 0, 1)
    let record = try String(contentsOfFile: result.output["recordPath"]!.string!, encoding: .utf8)
    XCTAssertTrue(record.contains("Hello everyone, let's start"), record)
    XCTAssertTrue(record.contains("Sure, I can begin"), record)
    XCTAssertEqual(record.components(separatedBy: "Great").count - 1, 1, "re-rendered row counted once")
    XCTAssertTrue(record.contains("Next topic"), record)
    XCTAssertTrue(record.contains("[Gap"), record)
    XCTAssertTrue(record.contains("minimized"), record)
    let json = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: result.output["recordJsonPath"]!.string!)))
    XCTAssertEqual(json["lines"]?.array?.count, 4)
  }

  func testPoppedOutCaptionsAreCapturedWhileTheCallWindowIsMinimized() async throws {
    let watch = try ProgramHarness(Teams(), fixture: TeamsFixture.popoutFixture(), config: ["frozenAfterSec": 10, "leaveGraceSec": 600])
    let events = try await watch.runWatch()
    XCTAssertEqual(events.map(\.eventType), ["teams.meeting.started"], "no freeze warning with popped-out captions")
    let h = try ProgramHarness(Teams(), fixture: TeamsFixture.popoutFixture(), config: ["frozenAfterSec": 10, "captionPollMs": 1000])
    h.advance(to: 2)
    let result = try await h.runTask("captureCaptions", input: ["title": "Standup"], stopAt: 40)
    XCTAssertEqual(result.status, "ok", "\(result)")
    let record = try String(contentsOfFile: result.output["recordPath"]!.string!, encoding: .utf8)
    for text in ["Hello everyone", "Budget first", "Then hiring", "Done"] { XCTAssertTrue(record.contains(text), record) }
  }

  func testNoCaptionsWhenNobodySpeaks() async throws {
    let meta = FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic")
    let fixture = Fixture(meta: meta, lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Teams")]),
      .tree(t: 0, pid: 42, root: TeamsFixture.app(meeting: true)),
      .marker(t: 20, label: "end"),
    ])
    let h = try ProgramHarness(Teams(), fixture: fixture)
    let result = try await h.runTask("captureCaptions", input: ["title": "Quiet"], stopAt: 20)
    XCTAssertEqual(result.status, "no_captions")
    XCTAssertEqual(result.output["lines"]?.int, 0)
    XCTAssertTrue(h.events.isEmpty, "an open, silent caption panel must not trigger a reminder")
  }

  func testMissingCaptionPanelWarnsOnceAndRearmsAfterRecovery() async throws {
    let meta = FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic")
    func hidden() -> AXNode {
      var app = TeamsFixture.app(meeting: true)
      // Keep the meeting and timer, but close the caption panel.
      app.children[1].children[0].children.removeAll { $0.domId == "captions-panel-dismiss-button" || $0.role == "AXList" }
      return app
    }
    let fixture = Fixture(meta: meta, lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Teams")]),
      .tree(t: 0, pid: 42, root: TeamsFixture.app(meeting: true)), // silence before the panel disappears
      .tree(t: 10, pid: 42, root: hidden()),
      .tree(t: 24, pid: 42, root: TeamsFixture.app(meeting: true)), // recovery, still silent
      .tree(t: 30, pid: 42, root: hidden()),
      .marker(t: 46, label: "end"),
    ])
    let h = try ProgramHarness(Teams(), fixture: fixture)
    _ = try await h.runTask("captureCaptions", input: ["title": "Standup", "correlationId": "meeting-1"], stopAt: 46)
    let alerts = h.events.filter { $0.eventType == "teams.captions.unavailable" }
    XCTAssertEqual(alerts.count, 2, "once per missing-panel episode, including recovery without speech")
    XCTAssertGreaterThanOrEqual(alerts[0].observedAt.timeIntervalSince(t0), 15)
    XCTAssertLessThanOrEqual(alerts[0].observedAt.timeIntervalSince(t0), 18)
    XCTAssertGreaterThanOrEqual(alerts[1].observedAt.timeIntervalSince(t0), 35)
    XCTAssertNotEqual(alerts[0].dedupeKey, alerts[1].dedupeKey)
    XCTAssertEqual(alerts[0].correlationId, "meeting-1")
    XCTAssertTrue(alerts[0].payload["hint"]?.string?.contains("visible on screen") == true)
  }
}
