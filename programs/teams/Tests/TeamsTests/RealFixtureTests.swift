import Foundation
import ReflexKit
import XCTest

@testable import Teams

/// Replays a real Teams 26246 meeting recorded by `dsh-reflex probe teams --speak` and cut with
/// `probe trim --script-only` (pseudonymized; only the scripted test sentences are left). In order:
/// call window in front, in the background, covered; minimized (compact view, captions frozen, the
/// sentences come back on restore); a feedback dialog that hides the page from AX; captions off and
/// on; captions popped out while the call window is minimized; leaving.
final class RealFixtureTests: XCTestCase {
  static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/teams-26246-probe.jsonl")
  /// Pseudonym of the meeting title in this recording.
  static let title = "Blphut Xvaid"

  static let captured = [
    "Please confirm the budget numbers by Friday.", "Our next milestone is the payment integration.",
    "Marketing will prepare the launch checklist.", "We still need a decision on the pricing page.",
    "Support tickets dropped by 30% this month.", "Let us schedule a follow up meeting on Tuesday.",
    "The vendor contract expires in December.", "Security review is blocked on the audit report.",
    "Remember to update the release notes tonight.", "The final agenda item is the holiday schedule.",
    "This sentence tests the pop out captions window.",
  ]

  func testMeetingEventsAcrossWindowStates() async throws {
    let fixture = try Fixture.load(Self.fixtureURL)
    let start = fixture.meta.startedAt
    let h = try ProgramHarness(Teams(), fixture: fixture, config: ["leaveGraceSec": 20, "frozenAfterSec": 20])
    let events = try await h.runWatch()
    let started = events.filter { $0.eventType == "teams.meeting.started" }
    XCTAssertEqual(started.count, 1, "\(events.map(\.eventType))")
    XCTAssertEqual(started.first?.payload["title"]?.string, Self.title)
    // Minimized 98–150 s: one warning. The feedback dialog (171–184 s) and the minimized window with
    // popped-out captions (487 s on) are not.
    let frozen = events.filter { $0.eventType == "teams.captions.unavailable" }
    XCTAssertEqual(frozen.count, 1, "\(frozen.map(\.payload))")
    XCTAssertEqual(frozen.first?.payload["cause"]?.string, "minimized")
    XCTAssertEqual(frozen.first.map { $0.observedAt.timeIntervalSince(start) } ?? 0, 120, accuracy: 4)
    let ended = try XCTUnwrap(events.first { $0.eventType == "teams.meeting.ended" })
    XCTAssertEqual(ended.correlationId, started.first?.correlationId)
    XCTAssertEqual(ended.payload["reason"]?.string, "detection_timeout")
    let endedAt = try XCTUnwrap(ended.payload["endedAt"]?.string.flatMap(ISO8601.parse))
    XCTAssertEqual(endedAt.timeIntervalSince(start), 643, accuracy: 3)
  }

  func testEverySpokenSentenceReachesTheRecord() async throws {
    let h = try ProgramHarness(Teams(), fixture: Fixture.load(Self.fixtureURL), config: ["frozenAfterSec": 20, "captionsMissingSec": 30])
    h.advance(to: 1)
    let result = try await h.runTask("captureCaptions", input: ["title": .string(Self.title)], stopAt: 622)
    XCTAssertEqual(result.status, "partial", "\(result)")
    let record = try String(contentsOfFile: try XCTUnwrap(result.output["recordPath"]?.string), encoding: .utf8)
    for sentence in Self.captured { XCTAssertTrue(record.contains(sentence), "missing: \(sentence)\n\(record)") }
    XCTAssertFalse(record.contains("Nothing in this part"), "said while captions were off")
    for sentence in Self.captured {
      XCTAssertEqual(record.components(separatedBy: sentence).count - 1, 1, "once: \(sentence)")
    }
    XCTAssertTrue(record.contains("minimized"), record)
    XCTAssertTrue(record.contains("Captions were off or not visible"), record)
  }
}

/// Replays a second Teams 26246 meeting (`probe teams --steps foreground,fullscreen-away,fullscreen-teams,hidden,leave`):
/// the call window goes full screen and the user switches to another desktop, so it drops out of
/// AXWindows (`unlisted`), Teams shows its compact view and pauses the call window (caption list and
/// timer stop) until the user is back on its desktop, when the six sentences said meanwhile appear.
/// Then ⌘H (Teams un-hides itself within 1.5 s), a 16 s pause with the compact view, and leaving.
final class SpacesFixtureTests: XCTestCase {
  static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/teams-26246-spaces.jsonl")
  static let title = "Heqmre Dsyrh"

  /// Final caption texts (Teams' recognition, pseudonymized where it is not a script word).
  static let captured = [
    "The quarterly hyya hga review starts with the mobile release.", "Please confirm the budget numbers by Friday.",
    "Our next milestone is the payment integration.",
    // Said while the call window was on another desktop.
    "The meeting window is now on another desktop.", "Lguprxf revenue grew faster than expected.",
    "Please send the slides before lunch.", "Now the chat list is open on this desktop.",
    "The office move is Planned for next spring.", "Two more volunteers for the workshop.",
    // ⌘H.
    "Microsoft Teams is hidden for this dmyc.", "The training budget was approved yesterday.",
    "Our customers asked for a dark mode option.",
  ]

  func testCallWindowOnAnotherDesktopStaysTheSameMeeting() async throws {
    let fixture = try Fixture.load(Self.fixtureURL)
    let start = fixture.meta.startedAt
    let h = try ProgramHarness(Teams(), fixture: fixture, config: ["leaveGraceSec": 20, "frozenAfterSec": 20])
    let events = try await h.runWatch()
    let started = events.filter { $0.eventType == "teams.meeting.started" }
    XCTAssertEqual(started.count, 1, "\(events.map(\.eventType))")
    XCTAssertEqual(started.first?.payload["title"]?.string, Self.title)
    // Away from 69 s to 295 s: one warning. The compact-view blips after ⌘H and the 16 s pause at 409 s are not.
    let frozen = events.filter { $0.eventType == "teams.captions.unavailable" }
    XCTAssertEqual(frozen.count, 1, "\(frozen.map(\.payload))")
    XCTAssertEqual(frozen.first?.payload["cause"]?.string, "off_screen")
    XCTAssertEqual(frozen.first.map { $0.observedAt.timeIntervalSince(start) } ?? 0, 89, accuracy: 4)
    let ended = events.filter { $0.eventType == "teams.meeting.ended" }
    XCTAssertEqual(ended.count, 1, "the meeting must not end while the call window is on another desktop")
    XCTAssertEqual(ended.first?.correlationId, started.first?.correlationId)
    XCTAssertEqual(ended.first?.payload["reason"]?.string, "detection_timeout")
    let endedAt = try XCTUnwrap(ended.first?.payload["endedAt"]?.string.flatMap(ISO8601.parse))
    XCTAssertEqual(endedAt.timeIntervalSince(start), 511, accuracy: 3)
  }

  func testSentencesSaidWhileAwayReachTheRecordOnce() async throws {
    let h = try ProgramHarness(Teams(), fixture: Fixture.load(Self.fixtureURL), config: ["frozenAfterSec": 20, "captionsMissingSec": 30])
    h.advance(to: 1)
    let result = try await h.runTask("captureCaptions", input: ["title": .string(Self.title)], stopAt: 488)
    XCTAssertEqual(result.status, "partial", "\(result)")
    let record = try String(contentsOfFile: try XCTUnwrap(result.output["recordPath"]?.string), encoding: .utf8)
    for sentence in Self.captured {
      XCTAssertEqual(record.components(separatedBy: sentence).count - 1, 1, "once: \(sentence)\n\(record)")
    }
    XCTAssertTrue(record.contains("on another desktop"), record)
    XCTAssertEqual(record.components(separatedBy: "[Gap").count - 1, 1, record)
  }
}
