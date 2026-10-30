import Foundation
import ReflexKit

/// Speaker-grouped transcript with gaps marked in place. Never claims completeness.
struct Transcript {
  struct Paragraph {
    var speaker: String
    var at: Date
    var texts: [String]
  }

  enum Item {
    case paragraph(Paragraph)
    case gap(CaptionGap)
  }

  let title: String
  let startedAt: Date
  let endedAt: Date
  let items: [Item]
  let lineCount: Int
  let speakers: [String]
  let gapSeconds: TimeInterval
  let participants: ParticipantRoster?

  static let gapLabels: [String: String] = [
    "program_restart": "Program or helper restarted",
    "window_frozen": "The meeting window was not visible (minimized, fully covered or on another desktop), so Teams paused captions. The next few lines were recovered afterwards; their timestamps may be inaccurate and their content incomplete",
    "page_stalled": "The Teams meeting window stopped refreshing; captions were not updated",
    "captions_off": "Captions were off or not visible",
    "app_not_running": "Teams was not running",
    "no_permission": "Accessibility permission was unavailable",
    "unreadable": "The caption area could not be read",
  ]

  init(title: String, startedAt: Date, endedAt: Date, assembler: CaptionAssembler, participants: ParticipantRoster? = nil) {
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.participants = participants
    let lines = assembler.lines.filter { !$0.text.isEmpty }.sorted { $0.firstSeen < $1.firstSeen }
    var items: [Item] = []
    var gaps = assembler.gaps.sorted { $0.from < $1.from }
    var current: Paragraph?
    func flush() {
      if let p = current { items.append(.paragraph(p)) }
      current = nil
    }
    for line in lines {
      while let g = gaps.first, g.from <= line.firstSeen {
        flush()
        items.append(.gap(g))
        gaps.removeFirst()
      }
      if var p = current, p.speaker == line.speaker {
        p.texts.append(line.text)
        current = p
      } else {
        flush()
        current = Paragraph(speaker: line.speaker, at: line.firstSeen, texts: [line.text])
      }
    }
    flush()
    for g in gaps { items.append(.gap(g)) }
    self.items = items
    self.lineCount = lines.count
    var seen: [String] = []
    for l in lines where !seen.contains(l.speaker) { seen.append(l.speaker) }
    self.speakers = seen
    self.gapSeconds = assembler.gapSeconds
  }

  static func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: d)
  }

  func markdown() -> String {
    var out: [String] = []
    out.append("# \(title)")
    out.append("")
    let minutes = Int((endedAt.timeIntervalSince(startedAt) / 60).rounded())
    out.append("- Time: \(ISO8601.format(startedAt)) – \(ISO8601.format(endedAt)) (approximately \(minutes) minutes)")
    out.append("- Captions: \(lineCount) lines, \(speakers.count) speakers, \(items.filter { if case .gap = $0 { return true } else { return false } }.count) gaps totaling \(Int(gapSeconds / 60)) minutes \(Int(gapSeconds) % 60) seconds")
    out.append("- Source: Teams live captions (speech recognition; errors may be present). No content was captured during gaps; this record is incomplete.")
    out.append("")
    if let roster = participants, let latest = roster.latest {
      out.append("## Participants observed in Teams")
      out.append("")
      out.append("- Last roster change observed: \(ISO8601.format(latest.observedAt)); names read: \(latest.names.count); Teams reported count: \(latest.reportedCount.map(String.init) ?? "unknown").")
      out.append("- These are participant-panel observations, not verified join/leave times. The list may be partial or outdated when the panel is closed; identical display names are not unique identities. Caption speakers are tracked separately.")
      out.append("- Names observed across all snapshots (may include people no longer present):")
      for name in roster.observedNames {
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: " ")
          .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
          .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
        out.append("- \(safe)")
      }
      out.append("")
    }
    for item in items {
      switch item {
      case .paragraph(let p):
        out.append("**[\(Self.clock(p.at))] \(p.speaker)**: \(p.texts.joined(separator: " "))")
        out.append("")
      case .gap(let g):
        let to = g.to.map(Self.clock) ?? "end"
        out.append("[Gap \(Self.clock(g.from))–\(to): \(Self.gapLabels[g.reason] ?? g.reason)]")
        out.append("")
      }
    }
    return out.joined(separator: "\n")
  }

  func json(assembler: CaptionAssembler) -> JSON {
    let lines = assembler.lines.filter { !$0.text.isEmpty }.sorted { $0.firstSeen < $1.firstSeen }
    return [
      "title": .string(title),
      "startedAt": JSON(startedAt),
      "endedAt": JSON(endedAt),
      "source": "teams-live-captions",
      "participants": participants.flatMap { try? JSON.parse(JSONCoding.encoder.encode($0)) } ?? .null,
      "lines": .array(lines.map { ["at": JSON($0.firstSeen), "speaker": .string($0.speaker), "text": .string($0.text), "revisions": JSON($0.revisions)] }),
      "gaps": .array(assembler.gaps.map { ["from": JSON($0.from), "to": $0.to.map(JSON.init) ?? .null, "reason": .string($0.reason)] }),
      "stats": ["lines": JSON(lineCount), "speakers": JSON(speakers), "gapSeconds": JSON(gapSeconds.rounded())],
    ]
  }

  /// Split a long markdown record into parts of at most `maxBytes` at paragraph boundaries.
  static func shard(_ markdown: String, maxBytes: Int) -> [String] {
    guard markdown.utf8.count > maxBytes else { return [markdown] }
    var parts: [String] = []
    var current = ""
    for block in markdown.components(separatedBy: "\n\n") {
      if !current.isEmpty, current.utf8.count + block.utf8.count + 2 > maxBytes {
        parts.append(current)
        current = ""
      }
      current += (current.isEmpty ? "" : "\n\n") + block
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }
}
