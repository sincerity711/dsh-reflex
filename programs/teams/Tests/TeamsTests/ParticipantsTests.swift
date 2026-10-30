import Foundation
import XCTest
@testable import ReflexKit
@testable import Teams

final class ParticipantsTests: XCTestCase {
  func person(_ name: String) -> AXNode {
    AXNode(role: "AXRow", title: name + ", Muted", children: [AXNode(role: "AXStaticText", value: name), AXNode(role: "AXImage", desc: "Muted")])
  }
  func roster(_ names: [String], count: Int, chinese: Bool = false) -> AXNode {
    AXNode(role: "AXOutline", desc: chinese ? "与会者" : "Attendees", children:
      [AXNode(role: "AXRow", title: chinese ? "在此会议中，\(count) 人" : "In this meeting, \(count) total Mute all")]
      + names.map(person) + [AXNode(role: "AXRow", title: "Invited"), person("Not attending")])
  }

  func testCurrentRosterExcludesInviteesAndPreservesDuplicateNames() throws {
    for chinese in [false, true] {
      let node = roster(["Alex", "Sam", "Alex"], count: 3, chinese: chinese)
      XCTAssertTrue(ParticipantsUI.isRoster(node))
      let snapshot = try XCTUnwrap(ParticipantsUI.parse(node, at: at(1)))
      XCTAssertEqual(snapshot.names, ["Alex", "Sam", "Alex"])
      XCTAssertEqual(snapshot.reportedCount, 3)
      XCTAssertTrue(snapshot.complete)
      var mixed = node
      mixed.title = "Tree"
      mixed.children[0].desc = mixed.children[0].title
      mixed.children[0].title = "Section"
      XCTAssertTrue(ParticipantsUI.isRoster(mixed))
      XCTAssertEqual(ParticipantsUI.parse(mixed, at: at(2))?.reportedCount, 3)
    }
  }

  func testPartialAndUnavailableAreNotFalseDepartures() throws {
    var state = ParticipantRoster()
    let first = try XCTUnwrap(ParticipantsUI.parse(roster(["Alex", "Sam"], count: 2), at: at(1)))
    state.observe(first, at: at(1))
    var unchanged = first; unchanged.observedAt = at(2)
    state.observe(unchanged, at: at(2))
    XCTAssertEqual(state.snapshots.count, 1)
    state.observe(nil, at: at(3))
    XCTAssertEqual(state.state, "unavailable")
    XCTAssertEqual(state.observedNames, ["Alex", "Sam"])
    XCTAssertEqual(state.latest?.names, ["Alex", "Sam"])
    var partial = roster(["Alex"], count: 2)
    partial.omittedChildren = 1
    state.observe(try XCTUnwrap(ParticipantsUI.parse(partial, at: at(4))), at: at(4))
    XCTAssertEqual(state.state, "partial")
    XCTAssertEqual(state.observedNames, ["Alex", "Sam"])
    state.observe(ParticipantSnapshot(observedAt: at(5), names: ["Alex", "Alex"], reportedCount: 2, complete: true), at: at(5))
    XCTAssertEqual(state.observedNames, ["Alex", "Sam", "Alex"])
    let restored = try JSONCoding.decoder.decode(ParticipantRoster.self, from: JSONCoding.encoder.encode(state))
    XCTAssertEqual(restored.snapshots, state.snapshots)
    XCTAssertEqual(restored.observedNames, state.observedNames)
    let transcript = Transcript(title: "Test", startedAt: at(0), endedAt: at(6), assembler: CaptionAssembler(), participants: restored)
    XCTAssertTrue(transcript.markdown().contains("Sam"), "retain previously observed participants in the final record")
    XCTAssertTrue(transcript.markdown().contains("not verified join/leave times"))
    XCTAssertEqual(transcript.json(assembler: CaptionAssembler())["participants"]?["snapshots"]?.array?.count, 3)
    XCTAssertEqual(transcript.json(assembler: CaptionAssembler())["participants"]?["snapshots"]?[0]?["observedAt"]?.string, ISO8601.format(at(1)))
  }

  func testCollapsedRosterDoesNotCollectExpandControlsOrInvitees() throws {
    var list = roster(["Alex", "Sam"], count: 31)
    list.children = Array(list.children.prefix(3)) + [
      AXNode(role: "AXRow", title: "See more", children: [AXNode(role: "AXStaticText", value: "See more")]),
      AXNode(role: "AXRow", title: "Others invited, 3 total"), person("Invited only"),
      AXNode(role: "AXRow", title: "People added to the chat, 37 total"), person("Chat only"),
    ]
    let snapshot = try XCTUnwrap(ParticipantsUI.parse(list, at: at(1)))
    XCTAssertEqual(snapshot.names, ["Alex", "Sam"])
    XCTAssertEqual(snapshot.reportedCount, 31)
    XCTAssertFalse(snapshot.complete)
  }

  func testScannerOnlyReadsRosterInMeetingWindowAndOldCheckpointStillDecodes() throws {
    var tree = TeamsFixture.app(meeting: true)
    tree.children[0].children.append(roster(["Unrelated chat"], count: 1))
    tree.children[1].children.append(roster(["Alex", "Sam"], count: 2))
    let fixture = Fixture(meta: FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "roster"), lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Teams")]), .tree(t: 0, pid: 42, root: tree),
    ])
    let core = RuntimeCore(manifest: Teams.manifest, source: ReplayAX(fixture: fixture), sink: CollectingSink(), config: Teams.manifest.config, grantedActions: [], dev: true)
    let ctx = ProgramContext(core: core, dataDir: FileManager.default.temporaryDirectory, stop: StopController())
    XCTAssertEqual(try ParticipantScanner(ctx: ctx).observe(at: at(0))?.names, ["Alex", "Sam"])
    let legacy: JSON = ["title": "Test", "startedAt": JSON(at(0)), "savedAt": JSON(at(3)), "assembler": try JSON(encoding: CaptionAssembler()), "unavailableSent": []]
    let decoded = try JSONCoding.decoder.decode(CaptionCapture.Meta.self, from: Data(legacy.serialized().utf8))
    XCTAssertNil(decoded.participants)
    XCTAssertEqual(decoded.startedAt, at(0))
  }
}
