import Foundation
import ReflexKit

/// Task `captureCaptions`: follow the caption list until the stop signal, then write
/// record.md / record.json and return ok | partial | no_captions.
///
/// Task directory: raw.jsonl (changes), lines.json (checkpoint), gaps.json, status.json,
/// record.md (+ record.partN.md when long), record.json.
struct CaptionCapture {
  let ctx: TaskContext

  struct Meta: Codable {
    var title: String
    var startedAt: Date
    var savedAt: Date
    var assembler: CaptionAssembler
    var unavailableSent: [String]
    var unavailableEpisode: Int?
    var participants: ParticipantRoster?
  }

  func run() async throws -> TaskResult {
    let title = ctx.input["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Teams meeting"
    let pollMs = ctx.int("captionPollMs", 1000)
    let frozenAfter = ctx.double("frozenAfterSec", 5)
    let missingAfter = ctx.double("captionsMissingSec", 5)
    var meta = Meta(title: title, startedAt: ctx.now, savedAt: ctx.now, assembler: CaptionAssembler(), unavailableSent: [])
    meta.assembler.stableAfter = ctx.double("finalizeStableSec", 6)
    meta.assembler.rewriteWindow = ctx.double("rewriteWindowSec", 30)
    if ctx.isResume, let saved = ctx.checkpoint.load(Meta.self, from: "capture") {
      meta = saved
      // Whatever was said while the program/helper was down is lost: mark it.
      meta.assembler.beginGap("program_restart", at: saved.savedAt)
      meta.assembler.endGap(at: ctx.now)
      ctx.log.info("resumed caption capture", ["lines": JSON(meta.assembler.lines.count)])
    }
    guard ctx.ax.isTrusted else {
      try emitUnavailable("no_permission", &meta)
      return finish(&meta, reason: "no_permission")
    }
    if let app = ctx.ax.apps().first, try await ctx.ax.prepareWeb(app) != .awake {
      ctx.log.warn("Teams web content not awake yet")
    }

    let locator = CaptionLocator(ctx: ctx)
    let participantScanner = ParticipantScanner(ctx: ctx)
    var lastParticipantsCheck = Date.distantPast
    var lastClock: String?
    var clockChangedAt = ctx.now
    var missingSince: Date?
    var lastSave = Date.distantPast
    var lastPanelCheck = Date.distantPast
    var lastFreezeCheck = Date.distantPast
    var frozenSince: Date?
    // Caption text changes send no notifications (Teams 26246), and element destruction fires several
    // times a second: polling does the work, the rare value/row notifications only shorten it.
    let watch = ctx.watch(
      "captions", every: .milliseconds(Int64(pollMs)),
      notifications: [AXNotification.valueChanged, AXNotification.liveRegionChanged, AXNotification.rowCountChanged],
      debounce: .milliseconds(150), idleEvery: .seconds(2)
    ) {
      try locator.locate(now: self.ctx.now)
    }

    for try await update in watch {
      let now = update.at
      var contentChanged = false
      if now.timeIntervalSince(lastParticipantsCheck) >= 15 {
        lastParticipantsCheck = now
        var roster = meta.participants ?? ParticipantRoster()
        let previousState = roster.state
        let previousCount = roster.snapshots.count
        do { roster.observe(try participantScanner.observe(at: now), at: now) }
        catch { roster.observe(nil, at: now, failed: true) }
        meta.participants = roster
        if previousState != roster.state || previousCount != roster.snapshots.count {
          ctx.log.info("participant observation", ["state": JSON(roster.state),
            "namesRead": JSON(roster.latest?.names.count ?? 0), "reportedCount": roster.latest?.reportedCount.map { JSON($0) } ?? .null])
          contentChanged = true
        }
      }
      if let node = update.node {
        missingSince = nil
        meta.unavailableSent.removeAll { $0 == "captions_off" || $0 == "unreadable" }
        if meta.assembler.openGap?.reason == "captions_off" || meta.assembler.openGap?.reason == "unreadable" { meta.assembler.endGap(at: now) }
        let entries = TeamsUI.captionEntries(in: node, entryClass: locator.sel.entryClass)
        let changes = meta.assembler.ingest(entries, at: now)
        contentChanged = contentChanged || !changes.isEmpty
        try record(changes, meta.assembler, at: now)
      } else {
        _ = meta.assembler.ingest([], at: now)
        if now.timeIntervalSince(lastPanelCheck) >= 2 {
          lastPanelCheck = now
          if !locator.panelOpen() {
            if missingSince == nil { missingSince = now }
            if let since = missingSince, now.timeIntervalSince(since) >= missingAfter {
              meta.assembler.beginGap("captions_off", at: since)
              try emitUnavailable("captions_off", &meta)
            }
          } else {
            // An open, empty caption panel means silence, not a capture failure.
            missingSince = nil
            meta.unavailableSent.removeAll { $0 == "captions_off" || $0 == "unreadable" }
            if meta.assembler.openGap?.reason == "captions_off" { meta.assembler.endGap(at: now) }
          }
        }
      }
      // Freeze: the call window's list stops while that window is minimized or Teams shows its compact
      // view (rows said meanwhile appear late, as far as the list still holds them); a timer standing
      // still means the page stopped. Short episodes (a look at the chat list) are not gaps.
      if now.timeIntervalSince(lastFreezeCheck) >= 2 {
        lastFreezeCheck = now
        let windowFrozen = locator.frozen(now: now)
        frozenSince = windowFrozen ? (frozenSince ?? now) : nil
        var stalled = false
        // Only a visible call window keeps its timer running.
        if locator.source == .meeting, !windowFrozen, let clock = locator.clock() {
          if clock != lastClock {
            lastClock = clock
            clockChangedAt = now
          } else {
            stalled = now.timeIntervalSince(clockChangedAt) >= frozenAfter
          }
        } else {
          clockChangedAt = now
        }
        if stalled {
          meta.assembler.beginGap("page_stalled", at: clockChangedAt)
        } else if let since = frozenSince, now.timeIntervalSince(since) >= frozenAfter {
          meta.assembler.beginGap("window_frozen", at: since)
        } else if let open = meta.assembler.openGap?.reason, open == "window_frozen" || open == "page_stalled" {
          meta.assembler.endGap(at: now)
        }
      }
      if contentChanged || now.timeIntervalSince(lastSave) >= 2 {
        lastSave = now
        try save(&meta, at: now)
        ctx.progress(["lines": JSON(meta.assembler.lines.count), "source": JSON(locator.source?.rawValue)])
      }
    }
    return finish(&meta, reason: nil)
  }

  private func emitUnavailable(_ reason: String, _ meta: inout Meta) throws {
    guard !meta.unavailableSent.contains(reason) else { return }
    meta.unavailableSent.append(reason)
    meta.unavailableEpisode = (meta.unavailableEpisode ?? 0) + 1
    let correlation = ctx.input["correlationId"]?.string
    try ctx.emit(ProgramEvent(
      "teams.captions.unavailable", resourceId: correlation ?? "teams", correlationId: correlation, identity: .heuristic,
      payload: ["reason": .string(reason), "title": .string(meta.title), "hint": .string(Teams.unavailableHint(reason))], observedAt: ctx.now,
      dedupeKey: "teams.captions.unavailable:\(correlation ?? ctx.taskId):\(reason):\(meta.unavailableEpisode!)"))
  }

  private func record(_ changes: [CaptionChange], _ a: CaptionAssembler, at now: Date) throws {
    for c in changes {
      var o: [String: JSON] = ["t": JSON(now)]
      switch c {
      case .added(let i): o["op"] = "add"; o["line"] = JSON(i)
      case .revised(let i): o["op"] = "revise"; o["line"] = JSON(i)
      case .merged(let i, let id): o["op"] = "merge"; o["line"] = JSON(i); o["id"] = .string(id)
      case .finalized(let i, let why): o["op"] = "final"; o["line"] = JSON(i); o["why"] = .string(why)
      }
      if let i = o["line"]?.int, a.lines.indices.contains(i) {
        o["speaker"] = .string(a.lines[i].speaker)
        o["text"] = .string(a.lines[i].text)
      }
      try ctx.append("raw.jsonl", line: JSON.object(o).serialized())
    }
  }

  private func save(_ meta: inout Meta, at now: Date) throws {
    meta.savedAt = now
    try ctx.checkpoint.save(meta, as: "capture")
    try ctx.writeJSON("gaps.json", meta.assembler.gaps)
    try ctx.write("status.json", JSON.object([
      "lines": JSON(meta.assembler.lines.count), "savedAt": JSON(now), "openGap": JSON(meta.assembler.openGap?.reason),
    ]).serialized())
  }

  private func finish(_ meta: inout Meta, reason: String?) -> TaskResult {
    let end = ctx.now
    meta.assembler.finalizeAll()
    meta.assembler.endGap(at: end)
    try? save(&meta, at: end)
    let transcript = Transcript(title: meta.title, startedAt: meta.startedAt, endedAt: end, assembler: meta.assembler, participants: meta.participants)
    var files: [String] = []
    do {
      let md = transcript.markdown()
      try ctx.write("record.md", md)
      try ctx.write("record.json", transcript.json(assembler: meta.assembler).serialized())
      files = [try ctx.file("record.md").path, try ctx.file("record.json").path]
      let parts = Transcript.shard(md, maxBytes: ctx.int("maxPartBytes", 120_000))
      if parts.count > 1 {
        for (i, p) in parts.enumerated() {
          try ctx.write("record.part\(i + 1).md", p)
          files.append(try ctx.file("record.part\(i + 1).md").path)
        }
      }
    } catch {
      return .failed("cannot write the record: \(error)")
    }
    let output: JSON = [
      "recordPath": .string((try? ctx.file("record.md").path) ?? ""),
      "recordJsonPath": .string((try? ctx.file("record.json").path) ?? ""),
      "title": .string(meta.title),
      "lines": JSON(transcript.lineCount),
      "speakers": JSON(transcript.speakers.count),
      "durationSec": JSON(end.timeIntervalSince(meta.startedAt).rounded()),
      "gaps": JSON(meta.assembler.gaps.count),
      "gapSec": JSON(meta.assembler.gapSeconds.rounded()),
      "parts": JSON(max(0, files.count - 2)),
      "stopReason": JSON(ctx.stopReason?.rawValue),
    ]
    if transcript.lineCount == 0 {
      var o = output
      o = o.merging(["reason": .string(reason ?? meta.unavailableSent.last ?? "no captions were seen")])
      return TaskResult(status: "no_captions", output: o, files: files)
    }
    return TaskResult(status: meta.assembler.gaps.isEmpty ? TaskStatusCode.ok : TaskStatusCode.partial, output: output, files: files)
  }
}
