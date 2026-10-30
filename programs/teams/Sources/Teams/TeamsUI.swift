import Foundation
import ReflexKit

/// Teams 2 (Edge WebView2) UI knowledge. Selectors come from config so they can follow Teams updates.
struct TeamsSelectors {
  var anchorIds: Set<String>
  var clockId: String
  var entryClass: String
  var panelIds: Set<String>
  var titleSuffix: String

  static let defaultPanelIds = [
    "captions-panel-dismiss-button", "closed-captions-overflow-menu-button", "closed-captions-pop-out-button",
    "captions-settings-menu-trigger-button-non-overflow",
  ]

  init(_ ctx: ProgramContext) {
    anchorIds = Set(ctx.strings("anchorIds", ["hangup-button", "call-duration-custom"]))
    clockId = ctx.string("clockId", "call-duration-custom")
    entryClass = ctx.string("captionEntryClass", "fui-ChatMessageCompact__body")
    panelIds = Set(ctx.strings("captionPanelIds", Self.defaultPanelIds))
    titleSuffix = ctx.string("titleSuffix", "| Microsoft Teams")
  }
}

enum TeamsUI {
  /// Title without Teams' own segment. Side windows add a segment on either side:
  /// "Meeting compact view | Standup | Microsoft Teams", "Standup | Microsoft Teams | Live captions".
  static func cleaned(_ title: String, suffix: String) -> String {
    let app = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "|").union(.whitespaces))
    return title.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0 != app }.joined(separator: " | ")
  }

  /// The meeting's own name: the call window carries the bare name and side windows add a localized
  /// label before or after it, so among sibling titles the shortest one this title starts or ends with
  /// (on a " | " boundary) is the name.
  static func stripChrome(_ title: String, siblings: [String], suffix: String) -> String {
    let base = cleaned(title, suffix: suffix)
    var shortest = base
    for s in siblings {
      let c = cleaned(s, suffix: suffix)
      guard !c.isEmpty, c.count < shortest.count, base.hasSuffix(" | " + c) || base.hasPrefix(c + " | ") else { continue }
      shortest = c
    }
    return shortest
  }

  /// Caption rows: elements with the entry class whose static texts are [speaker, text…].
  static func captionEntries(in container: AXNode, entryClass: String) -> [CaptionEntry] {
    container.all(.domClass(entryClass)).compactMap { row in
      // A budget-boundary fragment is not a complete caption (its speaker may be missing).
      guard !row.all(AXQuery()).contains(where: { ($0.omittedChildren ?? 0) > 0 }) else { return nil }
      let texts = row.texts()
      guard texts.count >= 2, let id = row.chromeId ?? row.domId else { return nil }
      return CaptionEntry(id: id, speaker: texts[0], text: texts.dropFirst().joined(separator: " "))
    }
  }

  /// "31:01" or "1:02:03" → seconds.
  static func parseClock(_ text: String) -> TimeInterval? {
    guard let m = text.range(of: #"\d{1,2}(:\d{2}){1,2}"#, options: .regularExpression) else { return nil }
    let parts = text[m].split(separator: ":").compactMap { Double($0) }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  /// 1:1 calls are titled "Meeting with …" even while the WebView is still hollow (English UI only).
  static func looksLikeMeetingTitle(_ title: String, suffix: String) -> Bool {
    cleaned(title, suffix: suffix).hasPrefix("Meeting with ")
  }

  /// Text of the call timer: the static text inside the timer group. The group's own title
  /// ("Elapsed time 01:18") is set once and not kept up to date, so it is not a fallback.
  static func clockText(_ node: AXNode) -> String? {
    let text = node.texts().joined(separator: " ")
    return text.isEmpty ? nil : text
  }
}

/// What a Teams window is during a meeting (observed on Teams 26246, see docs/TEAMS.md):
/// - `meeting`: the call window: anchors, plus the caption panel while captions are on. When it is
///   minimized its subrole turns into AXDialog; on a Space that is not on screen it is `unlisted`.
/// - `compact`: the floating "Meeting compact view" (an AXSystemDialog with anchors and no captions).
///   Teams shows it whenever the call window cannot be seen (minimized, on another Space, completely
///   covered) and pauses the call window meanwhile: its caption list and timer stop, and what was said
///   shows up once the call window is back, as far as the list still holds it.
/// - `captions`: popped-out captions (caption panel controls and rows, no anchors). Floats above other
///   windows and keeps updating in every state.
/// - `other`: the main window, dialogs.
enum TeamsWindowKind: String {
  case meeting, compact, captions, other
}

struct TeamsWindow {
  let ref: AXRef
  /// Depth-0 read: title, subrole, minimized.
  let node: AXNode
  let kind: TeamsWindowKind
}

/// Classifies Teams windows with few AX calls: a window is searched when it appears or its title,
/// subrole or minimized state changes; after that the handle found in it (anchor or caption row) is
/// re-read to confirm. Windows without one are searched again after `recheck` seconds (a hollow
/// WebView fills in later).
final class TeamsWindows {
  let ax: GuardedAX
  let sel: TeamsSelectors
  private var known: [String: (kind: TeamsWindowKind, handle: AXRef?, at: Date)] = [:]

  init(ax: GuardedAX, sel: TeamsSelectors) {
    self.ax = ax
    self.sel = sel
  }

  func scan(_ app: AppInfo, now: Date, recheck: TimeInterval) throws -> [TeamsWindow] {
    var out: [TeamsWindow] = []
    var seen = Set<String>()
    for ref in try ax.windows(app) {
      guard let node = try? ax.read(ref, ReadLimits(maxDepth: 0, maxNodes: 1, maxTextLength: 300, timeBudget: 0.5)) else { continue }
      let key = "\(node.subrole ?? "")|\(node.minimized == true)|\(node.title ?? "")"
      seen.insert(key)
      if let k = known[key], confirmed(k.handle, since: k.at, now: now, recheck: recheck) {
        out.append(TeamsWindow(ref: ref, node: node, kind: k.kind))
        continue
      }
      let (kind, handle) = try classify(ref, node)
      known[key] = (kind, handle, now)
      out.append(TeamsWindow(ref: ref, node: node, kind: kind))
    }
    known = known.filter { seen.contains($0.key) }
    return out
  }

  private func confirmed(_ handle: AXRef?, since: Date, now: Date, recheck: TimeInterval) -> Bool {
    guard let handle else { return now.timeIntervalSince(since) < recheck }
    return (try? ax.read(handle, ReadLimits(maxDepth: 0, maxNodes: 1))) != nil
  }

  private func classify(_ ref: AXRef, _ node: AXNode) throws -> (TeamsWindowKind, AXRef?) {
    if let anchor = try ax.find(.domId(in: sel.anchorIds), in: ref, FindLimits(maxNodes: 6000, timeBudget: 1.0)) {
      return (node.subrole == "AXSystemDialog" ? .compact : .meeting, anchor.ref)
    }
    // The panel's controls are there before anyone speaks, and stay while rows come and go.
    if let control = try ax.find(.domId(in: sel.panelIds), in: ref, FindLimits(maxNodes: 3000, timeBudget: 0.5)) {
      return (.captions, control.ref)
    }
    if let row = try ax.find(.domClass(sel.entryClass), in: ref, FindLimits(maxNodes: 3000, timeBudget: 0.5)) {
      return (.captions, row.ref)
    }
    return (.other, nil)
  }
}

/// Watches Teams windows for a meeting. A steady meeting costs a few AX calls per scan: windows are
/// classified once and confirmed through cached handles.
final class TeamsScanner {
  let ctx: ProgramContext
  let sel: TeamsSelectors
  private let windows: TeamsWindows
  private var clockRef: AXRef?
  private var webAwake = false
  private var lastWakeAttempt = Date.distantPast
  private var inMeeting = false
  private var titleOnly = false
  /// Name of the call window the last time its anchors were seen.
  private var lastCall: (title: String, at: Date)?
  /// Re-search windows without anchors this often while idle (6× less often during a meeting).
  var rescanEvery: TimeInterval = 10
  /// How long the call window still counts by its title alone after its anchors vanished.
  var modalGrace: TimeInterval = 600

  init(ctx: ProgramContext) {
    self.ctx = ctx
    self.sel = TeamsSelectors(ctx)
    self.windows = TeamsWindows(ax: ctx.ax, sel: sel)
  }

  func observe(at now: Date) async throws -> MeetingObservation {
    guard let app = ctx.ax.apps().first else {
      clockRef = nil
      inMeeting = false
      var o = MeetingObservation(at: now, appRunning: false, inMeeting: false)
      o.windowEvidence = "app_absent"
      return o
    }
    if !webAwake && now.timeIntervalSince(lastWakeAttempt) >= 60 {
      lastWakeAttempt = now
      webAwake = (try await ctx.ax.prepareWeb(app)) == .awake
    }
    let all = try windows.scan(app, now: now, recheck: titleOnly ? 2 : inMeeting ? rescanEvery * 6 : rescanEvery)
    var call = all.first { $0.kind == .meeting } ?? all.first { $0.kind == .compact }
    if let call {
      webAwake = true
      lastCall = (TeamsUI.cleaned(call.node.title ?? "", suffix: sel.titleSuffix), now)
    }
    // A modal dialog in the call window (feedback, device settings…) hides everything else from AX:
    // the window still titled like the meeting keeps counting for a while.
    if call == nil, let last = lastCall, now.timeIntervalSince(last.at) < modalGrace {
      call = all.first { $0.node.subrole == "AXStandardWindow" && TeamsUI.cleaned($0.node.title ?? "", suffix: sel.titleSuffix) == last.title }
    }
    // Fallback for a hollow WebView: "Meeting with …" window titles (English UI, heuristic).
    if call == nil { call = all.first { TeamsUI.looksLikeMeetingTitle($0.node.title ?? "", suffix: sel.titleSuffix) } }
    titleOnly = call?.kind == .other
    inMeeting = call != nil
    guard let call else {
      clockRef = nil
      var o = MeetingObservation(at: now, appRunning: true, inMeeting: false,
                                 captionsWindow: all.contains { $0.kind == .captions })
      o.windowEvidence = "no_anchor"
      return o
    }
    let title = TeamsUI.stripChrome(call.node.title ?? "", siblings: all.compactMap(\.node.title), suffix: sel.titleSuffix)
    var observation = MeetingObservation(
      at: now, appRunning: true, inMeeting: true, title: title.isEmpty ? nil : title, clock: clock(in: call),
      captionsWindow: all.contains { $0.kind == .captions },
      meetingWindowMinimized: call.kind == .meeting && call.node.minimized == true,
      meetingWindowOffScreen: call.kind == .meeting && call.node.unlisted == true,
      compactView: all.contains { $0.kind == .compact && $0.node.unlisted != true })
    observation.windowEvidence = call.kind == .meeting ? "meeting_anchor" : call.kind == .compact ? "compact_anchor" : "title_only"
    return observation
  }

  private func clock(in window: TeamsWindow) -> String? {
    if clockRef == nil {
      clockRef = try? ctx.ax.find(.domId(sel.clockId), in: window.ref, FindLimits(maxNodes: 6000, timeBudget: 0.8))?.ref
    }
    guard let c = clockRef else { return nil }
    guard let node = try? ctx.ax.read(c, ReadLimits(maxDepth: 3, maxNodes: 20)) else {
      clockRef = nil
      return nil
    }
    return TeamsUI.clockText(node)
  }
}

/// Finds the caption list: the popped-out captions window first (it can stay visible while the meeting window is minimized), else the panel in the call window. The list is the parent of the rows.
final class CaptionLocator {
  enum Source: String { case popout, meeting }

  let ctx: ProgramContext
  let sel: TeamsSelectors
  private let windows: TeamsWindows
  private var container: (ref: AXRef, source: Source)?
  private var lastSearch = Date.distantPast
  private var clockRef: AXRef?
  private(set) var source: Source?
  private(set) var readNodes = 0
  private(set) var omittedChildren = 0
  private var comparedLegacyRead = false
  var searchEvery: TimeInterval = 2

  init(ctx: ProgramContext) {
    self.ctx = ctx
    self.sel = TeamsSelectors(ctx)
    self.windows = TeamsWindows(ax: ctx.ax, sel: sel)
  }

  static let limits = ReadLimits(maxDepth: 8, maxNodes: 400, maxTextLength: 4000, timeBudget: 0.5, tailFirst: true)

  private func readList(_ ref: AXRef) throws -> AXNode {
    let node = try ctx.ax.read(ref, Self.limits)
    readNodes = node.nodeCount
    omittedChildren = node.all(AXQuery()).reduce(0) { $0 + ($1.omittedChildren ?? 0) }
    if !comparedLegacyRead {
      comparedLegacyRead = true
      var headLimits = Self.limits
      headLimits.tailFirst = false
      if let head = try? ctx.ax.read(ref, headLimits) {
        let older = TeamsUI.captionEntries(in: head, entryClass: sel.entryClass)
        let newer = TeamsUI.captionEntries(in: node, entryClass: sel.entryClass)
        ctx.log.info("caption read bounds", ["headNodes": JSON(head.nodeCount),
          "headOmitted": JSON(head.all(AXQuery()).reduce(0) { $0 + ($1.omittedChildren ?? 0) }),
          "tailNodes": JSON(readNodes), "tailOmitted": JSON(omittedChildren),
          "headRows": JSON(older.count), "tailRows": JSON(newer.count),
          "sameLastRow": JSON(older.last == newer.last)])
      }
    }
    return node
  }

  func locate(now: Date) throws -> AXNode? {
    // Chromium can retain a readable old caption subtree after replacing its live panel.
    // A successful read is not proof that this handle is still the current list.
    // Re-find from the meeting/popout window on a bounded cadence, including for popouts.
    if container != nil, now.timeIntervalSince(lastSearch) >= searchEvery { container = nil }
    if let c = container {
      if let node = try? readList(c.ref), node.contains(.domClass(sel.entryClass)) {
        source = c.source
        return node
      }
      container = nil
    }
    guard now.timeIntervalSince(lastSearch) >= searchEvery, let app = ctx.ax.apps().first else { return nil }
    lastSearch = now
    let all = try windows.scan(app, now: now, recheck: 10)
    for w in all.filter({ $0.kind == .captions }) + all.filter({ $0.kind == .meeting }) {
      guard let row = try ctx.ax.find(.domClass(sel.entryClass), in: w.ref, FindLimits(maxNodes: 8000, timeBudget: 1.5)),
            let rowRef = row.ref, let parent = try ctx.ax.parent(of: rowRef)
      else { continue }
      let src: Source = w.kind == .captions ? .popout : .meeting
      container = (parent, src)
      source = src
      return try readList(parent)
    }
    source = nil
    return nil
  }

  /// Whether the list being read has stopped updating: it is the call window's panel and Teams paused
  /// that window (minimized, off screen, or the compact view is up). A popped-out list keeps going.
  func frozen(now: Date) -> Bool {
    guard source == .meeting, let app = ctx.ax.apps().first, let all = try? windows.scan(app, now: now, recheck: 10) else { return false }
    return all.contains { w in
      switch w.kind {
      case .compact: return w.node.unlisted != true
      case .meeting: return w.node.minimized == true || w.node.unlisted == true
      case .captions, .other: return false
      }
    }
  }

  /// Whether the captions panel is up (rows may be absent while nobody speaks).
  func panelOpen() -> Bool {
    guard let app = ctx.ax.apps().first, let windows = try? ctx.ax.windows(app) else { return false }
    for w in windows {
      if (try? ctx.ax.find(.domId(in: sel.panelIds), in: w, FindLimits(maxNodes: 8000, timeBudget: 1.0))) != nil { return true }
    }
    return false
  }

  /// Meeting timer text; nil when not found.
  func clock() -> String? {
    if clockRef == nil, let app = ctx.ax.apps().first, let windows = try? ctx.ax.windows(app) {
      for w in windows {
        if let hit = try? ctx.ax.find(.domId(sel.clockId), in: w, FindLimits(maxNodes: 8000, timeBudget: 0.8)) {
          clockRef = hit.ref
          break
        }
      }
    }
    guard let c = clockRef else { return nil }
    guard let node = try? ctx.ax.read(c, ReadLimits(maxDepth: 3, maxNodes: 20)) else {
      clockRef = nil
      return nil
    }
    return TeamsUI.clockText(node)
  }
}
