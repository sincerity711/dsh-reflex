import Foundation
import ReflexKit

/// teams: meeting detection + live-caption capture for the new Microsoft Teams (Edge WebView2).
@main
struct Teams: ReflexProgram {
  private var readAudio: ((Date) -> AudioEvidence)?
  init() {}
  init(audio: @escaping (Date) -> AudioEvidence) { readAudio = audio }

  static let manifest = Manifest(
    id: "teams",
    version: "0.2.8",
    description: "Microsoft Teams: meeting start/end events and live-caption capture",
    apps: ["com.microsoft.teams2"],
    capabilities: [.read, .prepareWeb],
    emits: ["teams.meeting.started", "teams.meeting.ended", "teams.captions.unavailable"],
    tasks: ["captureCaptions"],
    config: [
      "scanSec": 2,
      "leaveGraceSec": 120,
      "frozenAfterSec": 5,
      "captionPollMs": 1000,
      "finalizeStableSec": 6,
      "rewriteWindowSec": 30,
      "captionsMissingSec": 5,
      "maxPartBytes": 120000,
      "anchorIds": ["hangup-button", "call-duration-custom"],
      "clockId": "call-duration-custom",
      "captionEntryClass": "fui-ChatMessageCompact__body",
      "captionPanelIds": .array(TeamsSelectors.defaultPanelIds.map(JSON.string)),
      "titleSuffix": "| Microsoft Teams",
    ],
    stallTimeoutSec: 120,
    lingerSec: 180)

  struct Journal: Codable {
    var state: TrackerState
    var receipts: [String: Receipt] = [:]
    var pending: [MeetingTracker.Output] = []

    mutating func apply(_ command: ProgramCommand, tracker: inout MeetingTracker, at now: Date, observation: MeetingObservation? = nil) -> ProgramCommandResult {
      pending = []
      if let receipt = receipts[command.requestId] {
        return ProgramCommandResult(requestId: command.requestId,
          error: receipt.command == command ? receipt.result.error : "request_conflict", status: Teams().status(tracker))
      }
      let result: (outputs: [MeetingTracker.Output], error: String?)
      if now.timeIntervalSince(command.issuedAt) > 60 || command.issuedAt.timeIntervalSince(now) > 5 {
        result = ([], "expired_request")
      } else { result = tracker.command(command, at: now, observation: observation) }
      let reply = ProgramCommandResult(requestId: command.requestId, error: result.error, status: Teams().status(tracker))
      receipts = receipts.filter { now.timeIntervalSince($0.value.command.issuedAt) <= 120 }
      receipts[command.requestId] = Receipt(command: command, result: reply)
      state = tracker.state
      pending = result.outputs
      return reply
    }
  }
  struct Receipt: Codable {
    var command: ProgramCommand
    var result: ProgramCommandResult
  }

  func watch(_ ctx: ProgramContext) async throws {
    var tracker = MeetingTracker()
    tracker.leaveGrace = ctx.double("leaveGraceSec", 120)
    tracker.frozenAfter = ctx.double("frozenAfterSec", 5)
    var journal = ctx.checkpoint.load(Journal.self, from: "meetingLifecycle")
      ?? Journal(state: ctx.checkpoint.load(TrackerState.self, from: "tracker") ?? .idle)
    tracker.state = journal.state
    // A crash between saving a transition and publishing it replays the same dedupe keys.
    for output in journal.pending { try emit(output, ctx) }
    journal.pending = []
    try ctx.checkpoint.save(journal, as: "meetingLifecycle")
    let scanner = TeamsScanner(ctx: ctx)
    let audio = TeamsAudioProbe()
    var lastStatus: [String: JSON] = [:]
    var lastEvidence: [String: JSON] = [:]
    let notifications = [AXNotification.windowCreated, AXNotification.focusedWindowChanged,
                         AXNotification.windowMiniaturized, AXNotification.windowDeminiaturized]
    for try await _ in ctx.ticks("meeting", every: .secondsDouble(ctx.double("scanSec", 2)), notifications: notifications, debounce: .milliseconds(300)) {
      // Snapshot requests before scanning; reattachment must validate fresh meeting controls.
      let commands = ctx.takeCommands()
      var observation: MeetingObservation
      do { observation = try await scanner.observe(at: ctx.now) }
      catch {
        observation = MeetingObservation(at: ctx.now, appRunning: !ctx.ax.apps().isEmpty, inMeeting: false)
        observation.windowEvidence = "error"
        observation.windowError = ctx.ax.isTrusted ? String(describing: type(of: error)) : "no_permission"
      }
      // Replay must never query the real machine's microphone state.
      observation.audio = readAudio?(ctx.now) ?? (ctx.clock.isVirtual ? .unknown : audio.snapshot())
      observation.at = ctx.now
      for command in commands {
        let before = tracker.label
        journal.pending = []
        let reply = journal.apply(command, tracker: &tracker, at: ctx.now, observation: observation)
        try ctx.checkpoint.save(journal, as: "meetingLifecycle")
        for output in journal.pending { try emit(output, ctx) }
        journal.pending = []
        try ctx.checkpoint.save(journal, as: "meetingLifecycle")
        ctx.log.info("meeting operation", ["action": .string(command.action), "requestId": .string(command.requestId),
          "correlationId": .string(command.correlationId), "from": .string(before), "to": .string(tracker.label),
          "deadline": tracker.deadline.map { JSON($0) } ?? .null, "error": JSON(reply.error)])
        ctx.reply(reply)
      }
      let evidence: [String: JSON] = ["window": .string(observation.windowEvidence), "anchor": JSON(observation.inMeeting && observation.windowEvidence != "title_only"),
        "audio": .string(observation.audio.state.rawValue), "audioProcesses": JSON(observation.audio.processes),
        "windowError": JSON(observation.windowError), "audioError": JSON(observation.audio.error), "captionsWindow": JSON(observation.captionsWindow),
        "minimized": JSON(observation.meetingWindowMinimized), "offScreen": JSON(observation.meetingWindowOffScreen), "compactView": JSON(observation.compactView),
        "titleLength": JSON(observation.title?.count ?? 0), "titleHash": JSON(observation.title.map { FNV1a64.hash($0) })]
      let before = tracker.label
      let outputs = tracker.update(observation)
      if tracker.state != journal.state || !outputs.isEmpty {
        journal.state = tracker.state
        journal.pending = outputs
        try ctx.checkpoint.save(journal, as: "meetingLifecycle")
        for output in outputs { try emit(output, ctx) }
        journal.pending = []
        try ctx.checkpoint.save(journal, as: "meetingLifecycle")
      }
      if evidence != lastEvidence || tracker.label != before {
        ctx.log.info("meeting evidence", evidence.merging(["from": .string(before), "to": .string(tracker.label),
          "correlationId": JSON(tracker.meeting?.correlationId), "deadline": tracker.deadline.map { JSON($0) } ?? .null]) { _, new in new })
        lastEvidence = evidence
      }
      var current = status(tracker)
      current["audio"] = .string(observation.audio.state.rawValue)
      current["windowEvidence"] = .string(observation.windowEvidence)
      current["captionsWindow"] = JSON(observation.captionsWindow)
      current["compactView"] = JSON(observation.compactView)
      current["callWindowOffScreen"] = JSON(observation.meetingWindowOffScreen)
      if current != lastStatus { ctx.setStatus(current); lastStatus = current }
    }
  }

  func status(_ tracker: MeetingTracker) -> [String: JSON] {
    var value: [String: JSON] = ["meeting": .string(tracker.label), "commandsSupported": true]
    if case .suppressed(let previous, _) = tracker.state {
      value["attachSupported"] = true
      value["attachCorrelationId"] = .string(previous.correlationId)
    }
    if let m = tracker.meeting {
      value["title"] = .string(m.title)
      value["correlationId"] = .string(m.correlationId)
      value["since"] = JSON(m.startedAt)
      value["deadline"] = m.deadline.map { JSON($0) } ?? .null
      value["lostAt"] = m.lostAt.map { JSON($0) } ?? .null
      value["episode"] = m.waitingEpisode.map { JSON($0) } ?? .null
      value["frozen"] = JSON(m.frozenSince != nil)
    }
    return value
  }

  private func emit(_ output: MeetingTracker.Output, _ ctx: ProgramContext) throws {
    switch output {
    case .started(let m):
      ctx.log.info("meeting started")
      try ctx.emit(ProgramEvent(
        "teams.meeting.started", resourceId: "meeting:\(m.correlationId)", correlationId: m.correlationId, identity: .heuristic,
        payload: ["title": .string(m.title), "startedAt": JSON(m.startedAt)], observedAt: m.startedAt,
        dedupeKey: "teams.meeting.started:\(m.correlationId)"))
    case .ended(let m, let reason, let at):
      ctx.log.info("meeting ended (\(reason))")
      try ctx.emit(ProgramEvent(
        "teams.meeting.ended", resourceId: "meeting:\(m.correlationId)", correlationId: m.correlationId, identity: .heuristic,
        payload: ["title": .string(m.title), "startedAt": JSON(m.startedAt), "endedAt": JSON(at), "reason": .string(reason),
                  "lostAt": m.lostAt.map { JSON($0) } ?? .null, "durationSec": JSON(at.timeIntervalSince(m.startedAt).rounded())],
        observedAt: at, dedupeKey: "teams.meeting.ended:\(m.correlationId)"))
    case .frozen(let m, let cause):
      try ctx.emit(ProgramEvent(
        "teams.captions.unavailable", resourceId: "meeting:\(m.correlationId)", correlationId: m.correlationId, identity: .heuristic,
        payload: ["reason": "window_frozen", "cause": .string(cause), "title": .string(m.title), "hint": .string(Self.frozenHint(cause))],
        observedAt: ctx.now, dedupeKey: "teams.captions.unavailable:\(m.correlationId):frozen:\(m.freezeEpisodes)"))
    case .rejoined:
      ctx.log.info("meeting resumed within the grace period")
    }
  }

  static func frozenHint(_ cause: String) -> String {
    switch cause {
    case "unreadable": return "Teams audio input is still active, but Reflex cannot read the captions. Restore the meeting or live captions window and check that captions are updating."
    case "stalled": return "Teams has stopped refreshing, so Reflex cannot capture the transcript. Keep the meeting or live captions window visible and check that captions are updating."
    case "off_screen": return "The Teams meeting is on another desktop and captions have paused. Switch back and keep the meeting or live captions window visible so Reflex can capture the transcript. Tip: use Open captions in new window."
    default: return "Teams captions have paused because the meeting window is minimized or fully covered. Keep the meeting or live captions window visible so Reflex can capture the transcript. Tip: use Open captions in new window."
    }
  }

  static func unavailableHint(_ reason: String) -> String {
    if reason == "no_permission" { return "Reflex cannot read Teams captions. Enable Accessibility access for DSH Reflex Helper and keep the Teams meeting or live captions window visible." }
    return "Reflex cannot read the Teams transcript. Turn on live captions and keep the meeting or live captions window visible on screen; otherwise captions cannot be captured. Tip: use Open captions in new window."
  }

  func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult {
    guard task == "captureCaptions" else { throw ReflexError.unknownTask(task) }
    return try await CaptionCapture(ctx: ctx).run()
  }
}
