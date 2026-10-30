import Foundation
import XCTest

@testable import ReflexKit

final class WireTests: XCTestCase {
  func testJSONLiteralsAndRoundTrip() throws {
    let j: JSON = ["a": 1, "b": [true, nil, "x"], "c": ["d": 1.5]]
    XCTAssertEqual(j["a"]?.int, 1)
    XCTAssertEqual(j["c"]?["d"]?.double, 1.5)
    XCTAssertEqual(try JSON.parse(j.serialized()), j)
    XCTAssertEqual(JSON.number(3).serialized(), "3")
  }

  func testInboundMessagesRoundTrip() throws {
    let start = TaskStartMessage(taskId: "R1.capture", task: "captureCaptions", input: ["title": "Standup"], dir: "/tmp/x", resume: true)
    guard case .taskStart(let m) = try InboundMessage.parse(try InboundMessage.taskStart(start).line()) else { return XCTFail() }
    XCTAssertEqual(m.taskId, "R1.capture")
    XCTAssertTrue(m.resume)
    guard case .taskStop(let id, let reason) = try InboundMessage.parse(try InboundMessage.taskStop(taskId: "t", reason: .stopOn).line()) else { return XCTFail() }
    XCTAssertEqual(id, "t")
    XCTAssertEqual(reason, .stopOn)
    let initMsg = InitMessage(programId: "teams", config: ["k": 1], dataDir: "/d", grantedActions: ["a"], dev: false)
    guard case .initialize(let i) = try InboundMessage.parse(try InboundMessage.initialize(initMsg).line()) else { return XCTFail() }
    XCTAssertEqual(i.config["k"], 1)
  }

  func testOutboundEventKeepsDates() throws {
    let at = Date(timeIntervalSince1970: 1_700_000_000.123)
    let e = ProgramEvent("teams.meeting.started", resourceId: "m", correlationId: "c", identity: .heuristic, payload: ["title": "T"], observedAt: at)
    guard case .event(let back) = try OutboundMessage.parse(try OutboundMessage.event(e).line()) else { return XCTFail() }
    XCTAssertEqual(back.eventType, e.eventType)
    XCTAssertEqual(back.identity, .heuristic)
    XCTAssertEqual(back.observedAt.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.002)
    let r = TaskResult(status: "partial", output: ["lines": 3], files: ["/a"], error: nil)
    guard case .taskResult(let id, let rr) = try OutboundMessage.parse(try OutboundMessage.taskResult(taskId: "t1", result: r).line()) else { return XCTFail() }
    XCTAssertEqual(id, "t1")
    XCTAssertEqual(rr, r)
  }

  func testULIDShape() {
    let a = ULID.make(date: Date(timeIntervalSince1970: 1))
    let b = ULID.make(date: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(a.count, 26)
    XCTAssertLessThan(a, b)
  }

  func testManifestProblems() {
    XCTAssertTrue(Manifest(id: "teams", apps: ["x"], emits: ["teams.meeting.started"]).problems().isEmpty)
    let bad = Manifest(id: "Bad Id", apps: [], actions: [ActionDecl("press", "x")], emits: ["other.thing.happened"])
    let p = bad.problems().joined(separator: "\n")
    XCTAssertTrue(p.contains("id must match"))
    XCTAssertTrue(p.contains("apps must list"))
    XCTAssertTrue(p.contains("must start with"))
    XCTAssertTrue(p.contains(".perform is missing"))
  }
}

final class AXNodeTests: XCTestCase {
  func node(_ text: String, frame: Rect? = nil) -> AXNode {
    AXNode(role: "AXGroup", domClasses: ["row"], children: [AXNode(role: "AXStaticText", value: "Alice"), AXNode(role: "AXStaticText", value: text)])
  }

  func testHashIgnoresFramesButNotText() {
    var a = node("hello")
    let b = node("hello")
    a.frame = Rect(x: 1, y: 2, w: 3, h: 4)
    XCTAssertEqual(a.contentHash, b.contentHash)
    XCTAssertNotEqual(node("hello").contentHash, node("hello world").contentHash)
  }

  func testCodableOmitsEmptyChildren() throws {
    let data = try JSONEncoder().encode(AXNode(role: "AXButton", domId: "x"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("children"))
    let back = try JSONDecoder().decode(AXNode.self, from: try JSONEncoder().encode(node("t")))
    XCTAssertEqual(back, node("t"))
  }

  func testUnlistedWindowsRoundTripAndKeepOldHashes() throws {
    let listed = AXNode(role: "AXWindow", title: "Standup | Microsoft Teams")
    var unlisted = listed
    unlisted.unlisted = true
    XCTAssertNotEqual(listed.contentHash, unlisted.contentHash)
    XCTAssertNotEqual(listed, unlisted)
    // Nodes without the flag hash as before it existed (recorded fixtures and checkpoints stay valid).
    XCTAssertEqual(listed.contentHash, AXNode(role: "AXWindow", title: "Standup | Microsoft Teams", unlisted: false).contentHash)
    let json = String(decoding: try JSONEncoder().encode(unlisted), as: UTF8.self)
    XCTAssertTrue(json.contains("\"unlisted\":true"), json)
    XCTAssertEqual(try JSONDecoder().decode(AXNode.self, from: Data(json.utf8)), unlisted)
    XCTAssertTrue(unlisted.label.contains("unlisted"))
  }

  func testQueryParseAndMatch() throws {
    let q = try AXQuery.parse("role=AXGroup .row")
    XCTAssertTrue(q.matches(node("x")))
    XCTAssertFalse(try AXQuery.parse("#hangup-button").matches(node("x")))
    XCTAssertTrue(try AXQuery.parse(".~RO").matches(node("x")))
    XCTAssertTrue(try AXQuery.parse("title^=Meet").matches(AXNode(title: "Meeting with Bob")))
    XCTAssertThrowsError(try AXQuery.parse("nonsense"))
    let tree = AXNode(role: "AXWindow", children: [AXNode(role: "AXGroup", children: [node("a"), node("b")])])
    XCTAssertEqual(tree.all(.domClass("row")).count, 2)
    XCTAssertEqual(tree.parent(ofChildMatching: .domClass("row"))?.role, "AXGroup")
    XCTAssertEqual(node("hi").texts(), ["Alice", "hi"])
  }

  func testPruneKeepsMatchesAncestorsAndShallowWindows() {
    let app = AXNode(role: "AXApplication", children: [
      AXNode(role: "AXWindow", title: "Main", children: [AXNode(role: "AXGroup", children: [AXNode(role: "AXButton", domId: "hangup-button"), AXNode(role: "AXGroup")])]),
      AXNode(role: "AXWindow", title: "Other", children: [AXNode(role: "AXGroup")]),
    ])
    let pruned = app.pruned(keep: [.domId("hangup-button")])!
    XCTAssertEqual(pruned.children.count, 2)
    XCTAssertNotNil(pruned.first(.domId("hangup-button")))
    XCTAssertEqual(pruned.children[1].children.count, 0)
    XCTAssertEqual(pruned.children[1].omittedChildren, 1)
  }

  func testPseudonymizationPreservesPrefixesAndVocabulary() {
    let r = Redactor(mode: .pseudo, salt: "s")
    let a = r.pseudonymize("Okay, and the oth")
    let b = r.pseudonymize("Okay, and the other thing")
    XCTAssertTrue(b.hasPrefix(a), "\(a) / \(b)")
    XCTAssertEqual(r.pseudonymize("Standup | Microsoft Teams").hasSuffix("| Microsoft Teams"), true)
    XCTAssertNotEqual(r.pseudonymize("Alice"), "Alice")
    XCTAssertEqual(Redactor(mode: .ui, salt: "s").redact("Leave", role: "AXButton"), "Leave")
    let scripted = Redactor(mode: .pseudo, salt: "s", keep: ["quarterly", "Roadmap"])
    XCTAssertEqual(scripted.pseudonymize("Quarterly roadmap"), "Quarterly roadmap")
    XCTAssertNotEqual(scripted.pseudonymize("Alice"), "Alice")
  }
}

final class CommandWireTests: XCTestCase {
  func testCommandAndResultRoundTrip() throws {
    let command = ProgramCommand(requestId: "request", correlationId: "meeting", action: "continue", episode: 2,
                                 issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let wire = try InboundMessage.command(command).line()
    XCTAssertNotNil(try JSON.parse(wire)["issuedAt"]?.string)
    guard case .command(let decoded) = try InboundMessage.parse(wire) else { return XCTFail() }
    XCTAssertEqual(decoded, command)
    let result = ProgramCommandResult(requestId: "request", error: "stale_meeting", status: ["meeting": "idle"])
    guard case .commandResult(let response) = try OutboundMessage.parse(OutboundMessage.commandResult(result).line()) else { return XCTFail() }
    XCTAssertEqual(response, result)
    XCTAssertThrowsError(try InboundMessage.parse("{\"type\":\"program.command\",\"requestId\":\"bad\"}"))
  }
}
