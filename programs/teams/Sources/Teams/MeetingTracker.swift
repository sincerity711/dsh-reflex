import Foundation
import ReflexKit

/// What one scan of Teams' windows saw.
struct MeetingObservation: Equatable {
  var at: Date
  var appRunning: Bool
  /// A meeting anchor (hangup button / call timer) exists in some window.
  var inMeeting: Bool
  /// Meeting name with Teams' window-title chrome stripped.
  var title: String?
  /// Text of the call timer ("31:01"), when visible. While the call window is visible it keeps running;
  /// when it stands still the page itself has stopped. (Minimized, the window's timer stops too.)
  var clock: String?
  /// A popped-out captions window exists (it keeps updating in every window state).
  var captionsWindow: Bool
  var meetingWindowMinimized: Bool
  /// The call window is not in the AXWindows list: it sits on a Space that is not on screen (e.g. full
  /// screen, and the user switched to another desktop).
  var meetingWindowOffScreen: Bool
  /// Teams shows its floating "Meeting compact view". It does whenever the call window cannot be seen
  /// (minimized, on a Space that is not on screen, or completely covered) and pauses that window.
  var windowError: String?
  var audio: AudioEvidence = .unknown
  var windowEvidence: String = "anchors"
  var compactView: Bool

  init(at: Date, appRunning: Bool, inMeeting: Bool, title: String? = nil, clock: String? = nil, captionsWindow: Bool = false,
       meetingWindowMinimized: Bool = false, meetingWindowOffScreen: Bool = false, compactView: Bool = false) {
    self.at = at
    self.appRunning = appRunning
    self.inMeeting = inMeeting
    self.title = title
    self.clock = clock
    self.captionsWindow = captionsWindow
    self.meetingWindowMinimized = meetingWindowMinimized
    self.meetingWindowOffScreen = meetingWindowOffScreen
    self.compactView = compactView
  }

  /// The call window's caption list is not updating: Teams paused that window (it cannot be seen), and
  /// no popped-out captions window takes over.
  var captionsFrozen: Bool { !captionsWindow && (meetingWindowMinimized || meetingWindowOffScreen || compactView) }
}

struct Meeting: Codable, Equatable {
  var correlationId: String
  var title: String
  var startedAt: Date
  var lastSeenAt: Date
  var clock: String?
  var clockChangedAt: Date
  /// Start of the current freeze episode (captions frozen, or the timer standing still).
  var frozenSince: Date?
  /// The current episode was reported (once per episode).
  var frozenWarned: Bool?
  var freezeEpisodes: Int
  var waitingEpisode: Int?
  var deadline: Date?
  var lostAt: Date?
}

enum TrackerState: Codable, Equatable {
  case idle
  case suppressed(Meeting, absentSince: Date?)
  case inMeeting(Meeting)
  case leavePending(Meeting, since: Date)
}

/// Meeting state machine: idle → in_meeting → leave_pending → (ended) idle.
/// Closing the window, short disconnects and covered windows inside the grace period are not an end.
struct MeetingTracker {
  var state: TrackerState = .idle
  var leaveGrace: TimeInterval = 120
  var frozenAfter: TimeInterval = 5

  enum Output: Codable, Equatable {
    case started(Meeting)
    case ended(Meeting, reason: String, at: Date)
    /// cause: `minimized`, `off_screen` (on a Space that is not on screen), `compact_view` (Teams paused
    /// the call window, e.g. it is completely covered) or `stalled` (the timer stopped: the page is not updating).
    case frozen(Meeting, cause: String)
    case rejoined(Meeting)
  }

  var meeting: Meeting? {
    switch state {
    case .idle, .suppressed: return nil
    case .inMeeting(let m), .leavePending(let m, _): return m
    }
  }

  var label: String {
    switch state {
    case .idle: return "idle"
    case .suppressed: return "suppressed"
    case .inMeeting: return "in_meeting"
    case .leavePending: return "leave_pending"
    }
  }

  static func correlationId(title: String, startedAt: Date) -> String {
    "teams:\(FNV1a64.hash(normalize(title)).prefix(10)):\(Int(startedAt.timeIntervalSince1970))"
  }

  static func normalize(_ title: String) -> String {
    title.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }

  var grace: TimeInterval { leaveGrace.isFinite && leaveGrace > 0 ? leaveGrace : 120 }
  var deadline: Date? { meeting?.deadline }

  /// A click is serialized with scans by the watch loop. The helper supplies stable request IDs.
  mutating func command(_ command: ProgramCommand, at now: Date, observation: MeetingObservation? = nil) -> (outputs: [Output], error: String?) {
    if command.action == "attach" {
      guard case .suppressed(let previous, _) = state, command.correlationId == previous.correlationId else {
        return ([], "stale_meeting")
      }
      guard var observation, observation.inMeeting, observation.windowEvidence != "title_only",
            observation.windowEvidence != "error", abs(now.timeIntervalSince(observation.at)) <= 5 else {
        return ([], "meeting_not_detected")
      }
      // Explicit reattachment starts a new record; never resurrect a finalized run or its dedupe key.
      observation.at = now
      state = .idle
      _ = update(observation)
      guard var attached = meeting else { return ([], "meeting_not_detected") }
      attached.correlationId += ":manual:\(FNV1a64.hash(command.requestId))"
      state = .inMeeting(attached)
      return ([.started(attached)], nil)
    }
    guard var m = meeting, command.correlationId == m.correlationId else { return ([], "stale_meeting") }
    if command.action == "end" {
      state = .suppressed(m, absentSince: nil)
      return ([.ended(m, reason: "user_confirmed", at: now)], nil)
    }
    guard command.action == "continue" else { return ([], "unknown_action") }
    guard case .leavePending = state, command.episode == m.waitingEpisode else { return ([], "stale_wait") }
    m.deadline = command.issuedAt.addingTimeInterval(120)
    state = .leavePending(m, since: m.lostAt ?? now)
    return ([], nil)
  }

  mutating func update(_ o: MeetingObservation) -> [Output] {
    var out: [Output] = []
    let evidence = (o.inMeeting && o.windowEvidence != "title_only") || o.audio.state == .running
    switch state {
    case .suppressed(let m, let absent):
      // Neither an unreadable AX tree nor a failed audio query proves departure.
      if evidence { state = .suppressed(m, absentSince: nil) }
      else if o.windowEvidence == "app_absent" || (o.windowEvidence != "error" && o.audio.state == .inactive) {
        let since = absent ?? o.at
        state = o.at.timeIntervalSince(since) >= 120 ? .idle : .suppressed(m, absentSince: since)
      } else { state = .suppressed(m, absentSince: nil) }
    case .idle:
      // Audio is keepalive only; it never starts a capture.
      if o.inMeeting {
        let title = o.title ?? "Teams meeting"
        var m = Meeting(correlationId: Self.correlationId(title: title, startedAt: o.at), title: title, startedAt: o.at,
                        lastSeenAt: o.at, clock: o.clock, clockChangedAt: o.at, frozenSince: nil, freezeEpisodes: 0)
        _ = trackFreeze(&m, o)
        state = .inMeeting(m)
        out.append(.started(m))
      }
    case .inMeeting(var m):
      if evidence {
        m.lastSeenAt = o.at
        // Display titles and CoreAudio object/device IDs are not meeting identities.
        out += trackFreeze(&m, o)
        state = .inMeeting(m)
      } else {
        m.waitingEpisode = (m.waitingEpisode ?? 0) + 1
        m.lostAt = o.at
        m.deadline = o.at.addingTimeInterval(grace)
        state = .leavePending(m, since: o.at)
      }
    case .leavePending(var m, let since):
      if evidence {
        m.lastSeenAt = o.at
        m.clockChangedAt = o.at
        m.frozenSince = nil
        m.frozenWarned = nil
        m.deadline = nil
        m.lostAt = nil
        state = .inMeeting(m)
        out.append(.rejoined(m))
      } else if o.at >= (m.deadline ?? since.addingTimeInterval(grace)) {
        out.append(.ended(m, reason: "detection_timeout", at: o.at))
        state = .idle
      } else if m.deadline == nil {
        // Migrate an old leavePending checkpoint without losing its elapsed time.
        m.deadline = since.addingTimeInterval(grace)
        m.lostAt = since
        m.waitingEpisode = (m.waitingEpisode ?? 0) + 1
        state = .leavePending(m, since: since)
      }
    }
    return out
  }

  /// Captions freeze while Teams pauses the call window (minimized, off screen, or the compact view is
  /// up); a timer standing still means the page stopped. Reported once per episode, after it lasted `frozenAfter` (a quick
  /// look at the chat list is fine: what was said shows up when the call window is back).
  private mutating func trackFreeze(_ m: inout Meeting, _ o: MeetingObservation) -> [Output] {
    if let clock = o.clock, clock != m.clock {
      m.clock = clock
      m.clockChangedAt = o.at
    }
    // Only a call window that is not paused keeps its timer running (the compact view's runs instead).
    let clockLive = !o.meetingWindowMinimized && !o.meetingWindowOffScreen && !o.compactView
    if !clockLive { m.clockChangedAt = o.at }
    let stalled = !o.captionsWindow && clockLive && o.clock != nil && o.at.timeIntervalSince(m.clockChangedAt) >= frozenAfter
    guard stalled || o.captionsFrozen || (!o.inMeeting && !o.captionsWindow) else {
      m.frozenSince = nil
      m.frozenWarned = nil
      return []
    }
    if m.frozenSince == nil { m.frozenSince = stalled ? m.clockChangedAt : o.at }
    guard m.frozenWarned != true, let since = m.frozenSince, o.at.timeIntervalSince(since) >= frozenAfter else { return [] }
    m.frozenWarned = true
    m.freezeEpisodes += 1
    let cause = !o.inMeeting ? "unreadable" : stalled ? "stalled" : o.meetingWindowMinimized ? "minimized" : o.meetingWindowOffScreen ? "off_screen" : "compact_view"
    return [.frozen(m, cause: cause)]
  }

}
