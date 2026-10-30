import Foundation
import ReflexKit
import XCTest
@testable import Teams

final class MeetingConfirmationTests: XCTestCase {
  func testLegacyCheckpointKeepsIdentityWithoutNewStart() throws {
    let legacy: JSON = ["inMeeting": ["_0": ["correlationId": "legacy-meeting", "title": "Standup",
      "startedAt": JSON(at(0)), "lastSeenAt": JSON(at(10)), "clock": "00:10",
      "clockChangedAt": JSON(at(10)), "freezeEpisodes": 0]]]
    var tracker = MeetingTracker()
    tracker.state = try JSONCoding.decoder.decode(TrackerState.self, from: Data(legacy.serialized().utf8))
    let outputs = tracker.update(observation(11, window: true))
    XCTAssertEqual(tracker.meeting?.correlationId, "legacy-meeting")
    XCTAssertFalse(outputs.contains { if case .started = $0 { return true }; return false })
    XCTAssertNil(tracker.deadline)
  }
  func observation(_ seconds: Double, window: Bool = false, audio: AudioEvidence.State = .unknown, title: String = "Standup") -> MeetingObservation {
    var o = MeetingObservation(at: at(seconds), appRunning: true, inMeeting: window, title: title)
    o.audio = AudioEvidence(state: audio)
    o.windowEvidence = window ? "meeting_anchor" : "no_anchor"
    return o
  }
  func started() -> MeetingTracker {
    var t = MeetingTracker()
    _ = t.update(observation(0, window: true))
    return t
  }
  func command(_ t: MeetingTracker, _ action: String, _ seconds: Double, id: String = UUID().uuidString) -> ProgramCommand {
    ProgramCommand(requestId: id, correlationId: t.meeting!.correlationId, action: action,
                   episode: t.meeting?.waitingEpisode, issuedAt: at(seconds))
  }
  func testHiddenWindowAndChangingAudioProcessesNeverStartCountdown() {
    var t = started()
    let id = t.meeting!.correlationId
    for i in [2, 6, 10, 130, 600] {
      var o = observation(Double(i), audio: .running)
      o.audio.processes = ["pid:\(i)"] // device/process/object changes don't identify a new meeting
      let outputs = t.update(o)
      XCTAssertFalse(outputs.contains { if case .ended = $0 { return true }; return false })
      XCTAssertNil(t.deadline)
      XCTAssertEqual(t.label, "in_meeting")
      XCTAssertEqual(t.meeting?.correlationId, id)
    }
    XCTAssertEqual(t.meeting?.freezeEpisodes, 1, "caption availability remains independent")
  }
  func testAudioAloneNeverStartsMeeting() {
    var t = MeetingTracker()
    XCTAssertTrue(t.update(observation(0, audio: .running)).isEmpty)
    XCTAssertNil(t.meeting)
  }

  func testExplicitReattachUsesFreshWindowEvidenceAndNewIdentityExactlyOnce() throws {
    var t = started()
    let old = t.meeting!.correlationId
    var journal = Teams.Journal(state: t.state)
    XCTAssertNil(journal.apply(command(t, "end", 0), tracker: &t, at: at(0)).error)
    journal.pending = []
    journal = try JSONCoding.decoder.decode(Teams.Journal.self, from: JSONCoding.encoder.encode(journal))
    t.state = journal.state
    let target = ProgramCommand(requestId: "reattach", correlationId: old, action: "attach", issuedAt: at(0))
    // Even ending and reattaching in the same second must not reuse the old dedupe key.
    XCTAssertNil(journal.apply(target, tracker: &t, at: at(0), observation: observation(0, window: true)).error)
    XCTAssertNotEqual(t.meeting?.correlationId, old)
    XCTAssertEqual(journal.pending.count, 1)
    guard case .started = journal.pending.first else { return XCTFail() }
    let attached = t.meeting!.correlationId
    journal.pending = []
    journal = try JSONCoding.decoder.decode(Teams.Journal.self, from: JSONCoding.encoder.encode(journal))
    t.state = journal.state
    XCTAssertNil(journal.apply(target, tracker: &t, at: at(1), observation: observation(1, window: true)).error)
    XCTAssertTrue(journal.pending.isEmpty)
    XCTAssertEqual(t.meeting?.correlationId, attached)
    var stale = target; stale.requestId = "old-button"
    XCTAssertEqual(journal.apply(stale, tracker: &t, at: at(1), observation: observation(1, window: true)).error, "stale_meeting")
    XCTAssertEqual(t.command(ProgramCommand(requestId: "old-end", correlationId: old, action: "end"), at: at(1)).error, "stale_meeting")
    XCTAssertEqual(t.meeting?.correlationId, attached)
  }

  func testReattachRejectsAudioAloneStaleScansAndExpiredRequests() {
    for input in [observation(10, audio: .running), observation(0, window: true), observation(10)] {
      var t = started()
      let old = t.meeting!.correlationId
      _ = t.command(command(t, "end", 2), at: at(2))
      let attach = ProgramCommand(requestId: UUID().uuidString, correlationId: old, action: "attach", issuedAt: at(10))
      var journal = Teams.Journal(state: t.state)
      XCTAssertEqual(journal.apply(attach, tracker: &t, at: at(10), observation: input).error, "meeting_not_detected")
      XCTAssertEqual(t.label, "suppressed")
      XCTAssertTrue(journal.pending.isEmpty)
    }
    var t = started()
    let old = t.meeting!.correlationId
    _ = t.command(command(t, "end", 2), at: at(2))
    var journal = Teams.Journal(state: t.state)
    let expired = ProgramCommand(requestId: "expired-attach", correlationId: old, action: "attach", issuedAt: at(2))
    XCTAssertEqual(journal.apply(expired, tracker: &t, at: at(70), observation: observation(70, window: true)).error, "expired_request")
    XCTAssertEqual(t.label, "suppressed")
    XCTAssertTrue(journal.pending.isEmpty)
  }
  func testUnknownAndUnsupportedUseConfirmationNotImmediateDeparture() {
    for audio in [AudioEvidence.State.unknown, .unsupported, .inactive] {
      var t = started()
      XCTAssertTrue(t.update(observation(10, audio: audio)).isEmpty)
      XCTAssertTrue(t.update(observation(129, audio: audio)).isEmpty)
      let outputs = t.update(observation(130, audio: audio))
      guard case .ended(_, let reason, let end) = outputs.first else { return XCTFail() }
      XCTAssertEqual(reason, "detection_timeout")
      XCTAssertEqual(end, at(130))
      XCTAssertTrue(t.update(observation(131, audio: audio)).isEmpty)
    }
  }
  func testRecoveryAtDeadlineWinsAndKeepsIdentity() {
    var t = started()
    let id = t.meeting!.correlationId
    _ = t.update(observation(10))
    guard case .rejoined = t.update(observation(130, audio: .running)).first else { return XCTFail() }
    XCTAssertEqual(t.meeting?.correlationId, id)
    XCTAssertNil(t.deadline)
  }
  func testRenewalRestartDuplicateAndStaleEpisode() throws {
    var t = started()
    _ = t.update(observation(10))
    var journal = Teams.Journal(state: t.state)
    let cmd = command(t, "continue", 100, id: "renew")
    XCTAssertNil(journal.apply(cmd, tracker: &t, at: at(102)).error)
    XCTAssertEqual(t.deadline, at(220))
    journal = try JSONCoding.decoder.decode(Teams.Journal.self, from: JSONCoding.encoder.encode(journal))
    t.state = journal.state
    XCTAssertNil(journal.apply(cmd, tracker: &t, at: at(120)).error)
    XCTAssertEqual(t.deadline, at(220), "retry after restart doesn't renew again")
    _ = t.update(observation(130, window: true))
    _ = t.update(observation(140))
    var stale = cmd; stale.requestId = "stale"; stale.issuedAt = at(145)
    XCTAssertEqual(journal.apply(stale, tracker: &t, at: at(145)).error, "stale_wait")
    XCTAssertEqual(t.deadline, at(260))
  }
  func testManualEndIsOnceAndSuppressionSurvivesRestart() throws {
    var t = started()
    let end = command(t, "end", 3)
    var journal = Teams.Journal(state: t.state)
    XCTAssertNil(journal.apply(end, tracker: &t, at: at(3)).error)
    guard case .ended(_, let reason, _) = journal.pending.first else { return XCTFail() }
    XCTAssertEqual(reason, "user_confirmed")
    journal.pending = []
    journal = try JSONCoding.decoder.decode(Teams.Journal.self, from: JSONCoding.encoder.encode(journal))
    t.state = journal.state
    XCTAssertNil(journal.apply(end, tracker: &t, at: at(4)).error)
    XCTAssertTrue(journal.pending.isEmpty)
    for s in [5.0, 150, 300] {
      XCTAssertTrue(t.update(observation(s, window: true, audio: .running, title: "Live captions | Standup")).isEmpty)
      XCTAssertNil(t.meeting)
    }
    _ = t.update(observation(310, audio: .inactive))
    _ = t.update(observation(429, audio: .inactive))
    XCTAssertNil(t.meeting)
    _ = t.update(observation(430, audio: .inactive))
    guard case .started(let next) = t.update(observation(431, window: true)).first else { return XCTFail() }
    XCTAssertNotEqual(next.correlationId, end.correlationId, "same title after confirmed absence is a new meeting")
    XCTAssertEqual(t.command(end, at: at(432)).error, "stale_meeting")
  }
  func testSuppressionDoesNotClearOnQueryErrors() {
    var t = started()
    _ = t.command(command(t, "end", 1), at: at(1))
    _ = t.update(observation(2, audio: .inactive))
    _ = t.update(observation(125, audio: .unknown))
    _ = t.update(observation(126, audio: .inactive))
    XCTAssertTrue(t.update(observation(200, window: true)).isEmpty)
    XCTAssertNil(t.meeting)
  }
  func testTimeoutAndManualActionCannotEndTwice() {
    var t = started()
    _ = t.update(observation(1))
    let end = command(t, "end", 121)
    XCTAssertEqual(t.update(observation(121)).count, 1)
    XCTAssertEqual(t.command(end, at: at(121)).error, "stale_meeting")
    XCTAssertTrue(t.command(end, at: at(121)).outputs.isEmpty)
  }
  func testExpiredAndConflictingRequestCannotMutateState() {
    var t = started()
    var j = Teams.Journal(state: t.state)
    let expired = command(t, "end", 0)
    XCTAssertEqual(j.apply(expired, tracker: &t, at: at(61)).error, "expired_request")
    XCTAssertNotNil(t.meeting)
    _ = t.update(observation(62))
    var cmd = command(t, "continue", 63, id: "same-request")
    XCTAssertNil(j.apply(cmd, tracker: &t, at: at(63)).error)
    cmd.action = "end"
    XCTAssertEqual(j.apply(cmd, tracker: &t, at: at(64)).error, "request_conflict")
    XCTAssertNotNil(t.meeting)
  }
  func testLegacyCheckpointAndNonpositiveGrace() throws {
    var t = started()
    let m = t.meeting!
    t.state = .leavePending(m, since: at(10))
    t.state = try JSONCoding.decoder.decode(TrackerState.self, from: JSONCoding.encoder.encode(t.state))
    for grace in [0.0, -1, .nan, .infinity] {
      t.leaveGrace = grace
      XCTAssertEqual(t.grace, 120)
    }
    _ = t.update(observation(11))
    XCTAssertEqual(t.deadline, at(130))
  }
  func testWatchWithHiddenWindowAndAudioDoesNotSplitOrWait() async throws {
    let h = try ProgramHarness(Teams(audio: { _ in AudioEvidence(state: .running, processes: ["pid:42"]) }),
      fixture: TeamsFixture.fixture(leaveAt: 45, end: 200))
    let events = try await h.runWatch()
    XCTAssertEqual(events.filter { $0.eventType == "teams.meeting.started" }.count, 1)
    XCTAssertFalse(events.contains { $0.eventType == "teams.meeting.ended" })
    XCTAssertFalse(h.sink.statuses.contains { $0["meeting"]?.string == "leave_pending" })
    XCTAssertEqual(Set(h.sink.statuses.compactMap { $0["correlationId"]?.string }).count, 1)
  }

  func testCaptureSwitchesFromCachedMainListToNewPopout() async throws {
    let meta = FixtureMeta(bundleIds: [TeamsFixture.bundle], startedAt: t0, redaction: .none, limits: ReadLimits(), tool: "synthetic")
    let old = [TeamsFixture.entry("old", "Alice", "Before popout")]
    let new = [TeamsFixture.entry("new", "Bob", "After popout")]
    let fixture = Fixture(meta: meta, lines: [
      .apps(t: 0, apps: [AppInfo(pid: 42, bundleId: TeamsFixture.bundle, name: "Microsoft Teams")]),
      .tree(t: 0, pid: 42, root: TeamsFixture.app(meeting: true, clock: "00:01", entries: old)),
      .tree(t: 4, pid: 42, root: TeamsFixture.app(meeting: true, clock: "00:05", entries: old, call: .minimized, popout: new)),
      .marker(t: 12, label: "end")])
    let h = try ProgramHarness(Teams(), fixture: fixture)
    let result = try await h.runTask("captureCaptions", input: ["title": "Standup"], stopAt: 12)
    let path = try XCTUnwrap(result.output["recordPath"]?.string)
    let record = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertTrue(record.contains("Before popout"))
    XCTAssertTrue(record.contains("After popout"))
    let sources = h.sink.all.compactMap { message -> String? in
      if case .taskProgress(_, let p) = message { return p["source"]?.string }; return nil
    }
    XCTAssertEqual(sources.last, "popout")
  }

  func testOnlyConfirmedTeamsOwnershipCounts() {
    XCTAssertTrue(TeamsAudioProbe.owns(bundle: "com.microsoft.teams2", executable: nil))
    XCTAssertTrue(TeamsAudioProbe.owns(bundle: "com.microsoft.teams2.helper", executable: nil))
    XCTAssertTrue(TeamsAudioProbe.owns(bundle: nil, executable: "/Applications/Microsoft Teams.app/Contents/Frameworks/MSTeams Helper.app/Contents/MacOS/MSTeams Helper"))
    XCTAssertFalse(TeamsAudioProbe.owns(bundle: "com.microsoft.edgemac", executable: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"))
    XCTAssertFalse(TeamsAudioProbe.owns(bundle: "com.microsoft.teams2-unrelated", executable: nil))
    XCTAssertFalse(TeamsAudioProbe.owns(bundle: nil, executable: nil))
  }
}
