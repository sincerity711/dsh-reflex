import Foundation
import ReflexKit

/// Observations of the participant panel, not an attendance report or verified join/leave times.
struct ParticipantSnapshot: Codable, Equatable {
  var observedAt: Date
  var names: [String]
  var reportedCount: Int?
  var complete: Bool
}

struct ParticipantRoster: Codable {
  var snapshots: [ParticipantSnapshot] = []
  var state = "unavailable"
  var lastCheckedAt: Date?
  var observedNames: [String] = []
  var latest: ParticipantSnapshot? { snapshots.last }

  mutating func observe(_ snapshot: ParticipantSnapshot?, at now: Date, failed: Bool = false) {
    lastCheckedAt = now
    guard let snapshot else {
      state = failed ? "error" : "unavailable"
      return // Closing the panel does not mean everybody left.
    }
    state = snapshot.complete ? "available" : "partial"
    var occurrences: [String: Int] = [:]
    for name in snapshot.names {
      occurrences[name, default: 0] += 1
      if observedNames.filter({ $0 == name }).count < occurrences[name, default: 0] { observedNames.append(name) }
    }
    if let previous = latest, previous.names == snapshot.names,
       previous.reportedCount == snapshot.reportedCount, previous.complete == snapshot.complete { return }
    snapshots.append(snapshot)
  }
}

enum ParticipantsUI {
  static let listLabels = ["attendees", "participants", "与会者", "参会者", "参与者"]
  static let activeHeaders = ["in this meeting", "in the meeting", "在此会议中", "在会议中", "会议中", "本次会议", "正在参加"]
  static let otherHeaders = ["not in this meeting", "others invited", "people added to the chat", "invited", "suggested", "in the lobby", "未在此会议中", "未加入", "其他受邀者", "已邀请", "添加到聊天", "等候大厅", "建议"]

  static func isRoster(_ node: AXNode) -> Bool {
    [node.title, node.desc, node.value].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.contains { label in
      listLabels.contains { label == $0 || label.hasPrefix($0 + " ") }
    }
  }

  static func parse(_ list: AXNode, at now: Date) -> ParticipantSnapshot? {
    let rows = list.all(.role("AXRow"))
    var inMeeting = false
    var foundActive = false
    var count: Int?
    var names: [String] = []
    var truncated = list.all(AXQuery()).contains { ($0.omittedChildren ?? 0) > 0 }
    for row in rows {
      let labels = [row.title, row.desc, row.value].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
      if labels.contains(where: { ["see more", "show more", "see less", "show less", "查看更多", "显示更多", "查看更少", "显示更少"].contains($0) }) {
        if labels.contains(where: { ["see more", "show more", "查看更多", "显示更多"].contains($0) }) { truncated = true }
        continue
      }
      if labels.contains(where: { label in otherHeaders.contains { label.hasPrefix($0) } }) { inMeeting = false; continue }
      if let label = labels.first(where: { label in activeHeaders.contains { label.hasPrefix($0) } }) {
        inMeeting = true
        foundActive = true
        if let range = label.range(of: #"\d+"#, options: .regularExpression) { count = Int(label[range]) }
        continue
      }
      guard inMeeting else { continue }
      // Header rows may contain nested participant rows; only extract each leaf once.
      guard row.children.allSatisfy({ $0.all(.role("AXRow")).isEmpty }) else { continue }
      if row.all(AXQuery()).contains(where: { ($0.omittedChildren ?? 0) > 0 }) { truncated = true; continue }
      guard let name = row.texts().map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else {
        truncated = true; continue
      }
      names.append(name) // Preserve duplicate display names; they may be different people.
    }
    guard foundActive else { return nil }
    return ParticipantSnapshot(observedAt: now, names: names, reportedCount: count,
      complete: !truncated && count != nil && count == names.count)
  }
}

final class ParticipantScanner {
  private let ctx: ProgramContext
  private let windows: TeamsWindows
  init(ctx: ProgramContext) {
    self.ctx = ctx
    self.windows = TeamsWindows(ax: ctx.ax, sel: TeamsSelectors(ctx))
  }

  func observe(at now: Date) throws -> ParticipantSnapshot? {
    guard let app = ctx.ax.apps().first else { return nil }
    for window in try windows.scan(app, now: now, recheck: 15) where window.kind == .meeting {
      // Re-find from the live window: retained Chromium handles may point to an obsolete panel.
      let lists = try ctx.ax.findAll(.role("AXOutline"), in: window.ref,
        FindLimits(maxNodes: 6000, maxMatches: 8, timeBudget: 0.5))
      for list in lists {
        guard let ref = list.ref else { continue }
        let label = try ctx.ax.read(ref, ReadLimits(maxDepth: 0, maxNodes: 1, maxTextLength: 200, timeBudget: 0.2))
        guard ParticipantsUI.isRoster(label) else { continue }
        let node = try ctx.ax.read(ref, ReadLimits(maxDepth: 14, maxNodes: 2000, maxTextLength: 500, timeBudget: 0.5))
        if let snapshot = ParticipantsUI.parse(node, at: now) { return snapshot }
      }
    }
    return nil
  }
}
