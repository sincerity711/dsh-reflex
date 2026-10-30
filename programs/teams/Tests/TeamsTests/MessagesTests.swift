import Foundation
import ReflexKit
import XCTest

@testable import Teams

final class SendGuardTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let okTarget = SendTarget(currentChatTitle: "Team chat", inputFocused: true, inputBelongsToChat: true)

  func guardFor(_ chats: Set<String> = ["c1"]) -> SendGuard { SendGuard(config: SendGuardConfig(allowedChats: chats)) }

  func testWhitelistAndTargetChecks() {
    let g = guardFor()
    XCTAssertEqual(g.check(SendRequest(chatKey: "c1", expectedChatTitle: "Team chat", text: "hi"), target: okTarget, now: now), .allow)
    XCTAssertNotEqual(g.check(SendRequest(chatKey: "c2", expectedChatTitle: "Team chat", text: "hi"), target: okTarget, now: now), .allow)
    var moved = okTarget
    moved.currentChatTitle = "Someone else"
    XCTAssertNotEqual(g.check(SendRequest(chatKey: "c1", expectedChatTitle: "Team chat", text: "hi"), target: moved, now: now), .allow)
    var unfocused = okTarget
    unfocused.inputFocused = false
    XCTAssertNotEqual(g.check(SendRequest(chatKey: "c1", expectedChatTitle: "Team chat", text: "hi"), target: unfocused, now: now), .allow)
  }

  func testLoopGuardAndSelfFilter() {
    var g = guardFor()
    let r = SendRequest(chatKey: "c1", expectedChatTitle: "Team chat", text: "Thanks!")
    g.recordSent(r, at: now)
    XCTAssertNotEqual(g.check(r, target: okTarget, now: now.addingTimeInterval(120)), .allow)
    let echo = TeamsMessage(chatKey: "c1", chatTitle: "Team chat", sender: "Me", isSelf: false, text: "Thanks!", ts: now)
    XCTAssertFalse(g.shouldEmit(echo, now: now.addingTimeInterval(5)))
    XCTAssertFalse(g.shouldEmit(TeamsMessage(chatKey: "c1", chatTitle: "Team chat", sender: "Me", isSelf: true, text: "x", ts: now), now: now))
    XCTAssertTrue(g.shouldEmit(TeamsMessage(chatKey: "c1", chatTitle: "Team chat", sender: "Bob", isSelf: false, text: "ok", ts: now), now: now))
  }

  func testRateLimits() {
    var g = guardFor(["c1", "c2"])
    for i in 0..<3 { g.recordSent(SendRequest(chatKey: "c1", expectedChatTitle: "Team chat", text: "m\(i)"), at: now) }
    XCTAssertEqual(g.check(SendRequest(chatKey: "c2", expectedChatTitle: "Team chat", text: "new"), target: okTarget, now: now.addingTimeInterval(10)), .deny("rate limit (per minute)"))
    XCTAssertEqual(g.check(SendRequest(chatKey: "c2", expectedChatTitle: "Team chat", text: "new"), target: okTarget, now: now.addingTimeInterval(61)), .allow)
  }

  func testReservedTasksRefuse() {
    XCTAssertEqual(TeamsMessageTasks.sendReply([:]).status, "error")
    XCTAssertFalse(Teams.manifest.tasks.contains("sendReply"))
    XCTAssertTrue(Teams.manifest.actions.isEmpty, "v1 declares no actions")
  }
}
