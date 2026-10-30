import Foundation

/// One caption row as shown on screen (Teams keeps about three of them).
struct CaptionEntry: Equatable {
  /// Chromium node id of the row (`ChromeAXNodeId`).
  var id: String
  var speaker: String
  var text: String
}

struct CaptionLine: Codable, Equatable {
  /// Every node id this line was rendered under (Teams re-renders finished rows with fresh ids).
  var ids: [String]
  var speaker: String
  var text: String
  var firstSeen: Date
  var lastChanged: Date
  var lastSeen: Date
  var revisions: Int
  var final: Bool
}

struct CaptionGap: Codable, Equatable {
  var from: Date
  var to: Date?
  var reason: String
}

enum CaptionChange: Equatable {
  case added(Int)
  case revised(Int)
  case merged(Int, newId: String)
  case finalized(Int, why: String)
}

/// Turns the moving window of on-screen caption rows into a stable list of lines.
///
/// - A row still being spoken is revised in place (same id): keep the latest text.
/// - A row is final when its node disappears, when the same speaker starts a later row, or when its
///   text has been stable for `stableAfter` seconds.
/// - A finished row re-rendered under a new id is the same line when, within `rewriteWindow`, the
///   same speaker's texts are equal or one is a prefix of the other.
struct CaptionAssembler: Codable {
  var lines: [CaptionLine] = []
  var gaps: [CaptionGap] = []
  var stableAfter: TimeInterval = 6
  var rewriteWindow: TimeInterval = 30

  var openGap: CaptionGap? { gaps.last.flatMap { $0.to == nil ? $0 : nil } }

  mutating func ingest(_ entries: [CaptionEntry], at now: Date) -> [CaptionChange] {
    var changes: [CaptionChange] = []
    var visibleLines = Set<Int>()
    for e in entries where !e.text.isEmpty {
      if let i = lines.lastIndex(where: { $0.ids.contains(e.id) }) {
        visibleLines.insert(i)
        lines[i].lastSeen = now
        if e.text != lines[i].text {
          // A final line only grows (a re-read of a shorter render must not truncate it).
          if !lines[i].final || e.text.count > lines[i].text.count && e.text.hasPrefix(lines[i].text) {
            lines[i].text = e.text
            lines[i].lastChanged = now
            lines[i].revisions += 1
            changes.append(.revised(i))
          }
        }
        continue
      }
      if let i = rerenderMatch(e, now: now, excluding: visibleLines) {
        visibleLines.insert(i)
        lines[i].ids.append(e.id)
        lines[i].lastSeen = now
        if e.text.count > lines[i].text.count {
          lines[i].text = e.text
          lines[i].lastChanged = now
          lines[i].revisions += 1
        }
        changes.append(.merged(i, newId: e.id))
        continue
      }
      lines.append(CaptionLine(ids: [e.id], speaker: e.speaker, text: e.text, firstSeen: now, lastChanged: now, lastSeen: now, revisions: 0, final: false))
      visibleLines.insert(lines.count - 1)
      changes.append(.added(lines.count - 1))
    }
    // Finalize provisional lines.
    for i in lines.indices where !lines[i].final {
      if !visibleLines.contains(i) {
        lines[i].final = true
        changes.append(.finalized(i, why: "disappeared"))
      } else if lines.indices.contains(where: { $0 > i && lines[$0].speaker == lines[i].speaker && visibleLines.contains($0) }) {
        lines[i].final = true
        changes.append(.finalized(i, why: "superseded"))
      } else if now.timeIntervalSince(lines[i].lastChanged) >= stableAfter {
        lines[i].final = true
        changes.append(.finalized(i, why: "stable"))
      }
    }
    return changes
  }

  /// A recent line of the same speaker whose text equals or prefixes (either way) the new row.
  private func rerenderMatch(_ e: CaptionEntry, now: Date, excluding: Set<Int>) -> Int? {
    for i in lines.indices.reversed() where !excluding.contains(i) {
      let l = lines[i]
      if now.timeIntervalSince(l.lastSeen) > rewriteWindow { continue }
      guard l.speaker == e.speaker else { continue }
      if l.text == e.text || l.text.hasPrefix(e.text) || e.text.hasPrefix(l.text) { return i }
    }
    return nil
  }

  mutating func finalizeAll() {
    for i in lines.indices { lines[i].final = true }
  }

  /// Open a gap (no-op when one is already open).
  mutating func beginGap(_ reason: String, at: Date) {
    if openGap != nil { return }
    gaps.append(CaptionGap(from: at, to: nil, reason: reason))
  }

  mutating func endGap(at: Date) {
    guard let last = gaps.indices.last, gaps[last].to == nil else { return }
    gaps[last].to = at
    // Gaps shorter than two seconds are noise.
    if at.timeIntervalSince(gaps[last].from) < 2 { gaps.removeLast() }
  }

  var gapSeconds: TimeInterval {
    gaps.reduce(0) { $0 + (($1.to ?? $1.from).timeIntervalSince($1.from)) }
  }
}
