import ApplicationServices
import Foundation

/// Opaque handle to a UI element. Live handles retain an AXUIElement; replay handles point into a fixture.
public final class AXRef: @unchecked Sendable, Hashable, CustomStringConvertible {
  public let pid: pid_t
  let element: AXUIElement?
  /// Replay: child-index path from the application root, and an identity key when the node has one.
  let replayPath: [Int]?
  let replayKey: String?
  /// Live window handle that the app's AXWindows list left out (see `AXNode.unlisted`).
  let unlisted: Bool

  init(live element: AXUIElement, pid: pid_t, unlisted: Bool = false) {
    self.element = element
    self.pid = pid
    self.replayPath = nil
    self.replayKey = nil
    self.unlisted = unlisted
  }

  init(replayPid pid: pid_t, path: [Int], key: String?) {
    self.element = nil
    self.pid = pid
    self.replayPath = path
    self.replayKey = key
    self.unlisted = false
  }

  public static func == (a: AXRef, b: AXRef) -> Bool {
    if let ea = a.element, let eb = b.element { return CFEqual(ea, eb) }
    return a.pid == b.pid && a.replayPath == b.replayPath && a.replayKey == b.replayKey
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(pid)
    if let e = element { hasher.combine(CFHash(e)) } else {
      hasher.combine(replayPath)
      hasher.combine(replayKey)
    }
  }

  public var description: String {
    if element != nil { return "AXRef(pid: \(pid))" }
    return "AXRef(replay pid: \(pid), path: \(replayPath ?? []), key: \(replayKey ?? "-"))"
  }
}

public struct Rect: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }
}

/// A value snapshot of one element and (a bounded part of) its subtree.
public struct AXNode: Codable, Hashable, Sendable {
  public var role: String?
  public var subrole: String?
  public var title: String?
  public var desc: String?
  public var value: String?
  public var identifier: String?
  public var domId: String?
  public var domClasses: [String]?
  /// Chromium's per-node id (`ChromeAXNodeId`). Distinguishes list entries.
  public var chromeId: String?
  public var frame: Rect?
  public var minimized: Bool?
  public var focused: Bool?
  /// A window that is not in the app's AXWindows list, which only holds windows on Spaces that are on
  /// screen (plus minimized ones): e.g. a full-screen window the user switched away from. Found as the
  /// app's focused/main window, or kept from an earlier listing while its handle still answers.
  public var unlisted: Bool?
  /// Owning process when it differs from the parent's (e.g. a WebView child process).
  public var pid: Int32?
  /// Number of children that exist but were not read because of limits.
  public var omittedChildren: Int?
  public var children: [AXNode]
  /// Live or replay handle; not part of equality or serialization.
  public var ref: AXRef?

  public init(
    role: String? = nil, subrole: String? = nil, title: String? = nil, desc: String? = nil,
    value: String? = nil, identifier: String? = nil, domId: String? = nil, domClasses: [String]? = nil,
    chromeId: String? = nil, frame: Rect? = nil, minimized: Bool? = nil, focused: Bool? = nil,
    unlisted: Bool? = nil, pid: Int32? = nil, omittedChildren: Int? = nil, children: [AXNode] = [], ref: AXRef? = nil
  ) {
    self.role = role; self.subrole = subrole; self.title = title; self.desc = desc
    self.value = value; self.identifier = identifier; self.domId = domId; self.domClasses = domClasses
    self.chromeId = chromeId; self.frame = frame; self.minimized = minimized; self.focused = focused
    self.unlisted = unlisted
    self.pid = pid; self.omittedChildren = omittedChildren; self.children = children; self.ref = ref
  }

  enum CodingKeys: String, CodingKey {
    case role, subrole, title, desc, value, identifier, domId, domClasses, chromeId, frame, minimized, focused, unlisted, pid, omittedChildren, children
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    role = try c.decodeIfPresent(String.self, forKey: .role)
    subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    desc = try c.decodeIfPresent(String.self, forKey: .desc)
    value = try c.decodeIfPresent(String.self, forKey: .value)
    identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    domId = try c.decodeIfPresent(String.self, forKey: .domId)
    domClasses = try c.decodeIfPresent([String].self, forKey: .domClasses)
    chromeId = try c.decodeIfPresent(String.self, forKey: .chromeId)
    frame = try c.decodeIfPresent(Rect.self, forKey: .frame)
    minimized = try c.decodeIfPresent(Bool.self, forKey: .minimized)
    focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
    unlisted = try c.decodeIfPresent(Bool.self, forKey: .unlisted)
    pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
    omittedChildren = try c.decodeIfPresent(Int.self, forKey: .omittedChildren)
    children = try c.decodeIfPresent([AXNode].self, forKey: .children) ?? []
    ref = nil
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(role, forKey: .role)
    try c.encodeIfPresent(subrole, forKey: .subrole)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(desc, forKey: .desc)
    try c.encodeIfPresent(value, forKey: .value)
    try c.encodeIfPresent(identifier, forKey: .identifier)
    try c.encodeIfPresent(domId, forKey: .domId)
    try c.encodeIfPresent(domClasses, forKey: .domClasses)
    try c.encodeIfPresent(chromeId, forKey: .chromeId)
    try c.encodeIfPresent(frame, forKey: .frame)
    try c.encodeIfPresent(minimized, forKey: .minimized)
    try c.encodeIfPresent(focused, forKey: .focused)
    try c.encodeIfPresent(unlisted, forKey: .unlisted)
    try c.encodeIfPresent(pid, forKey: .pid)
    try c.encodeIfPresent(omittedChildren, forKey: .omittedChildren)
    if !children.isEmpty { try c.encode(children, forKey: .children) }
  }

  public static func == (a: AXNode, b: AXNode) -> Bool {
    a.role == b.role && a.subrole == b.subrole && a.title == b.title && a.desc == b.desc
      && a.value == b.value && a.identifier == b.identifier && a.domId == b.domId
      && a.domClasses == b.domClasses && a.chromeId == b.chromeId && a.frame == b.frame
      && a.minimized == b.minimized && a.focused == b.focused && a.unlisted == b.unlisted && a.pid == b.pid
      && a.omittedChildren == b.omittedChildren && a.children == b.children
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(contentHash)
  }

  /// Stable 64-bit content hash over the whole subtree (frames excluded so window moves don't count).
  public var contentHash: String {
    var h = FNV1a64()
    combine(into: &h)
    return h.hex
  }

  private func combine(into h: inout FNV1a64) {
    h.combine(role); h.combine(subrole); h.combine(title); h.combine(desc); h.combine(value)
    h.combine(identifier); h.combine(domId); h.combine(domClasses?.joined(separator: " ")); h.combine(chromeId)
    h.combine(minimized.map { $0 ? "1" : "0" })
    if unlisted == true { h.combine("unlisted") }
    h.combine(children.count)
    for child in children { child.combine(into: &h) }
  }

  // MARK: queries over the snapshot

  /// All nodes in depth-first pre-order, including self.
  public var descendants: [AXNode] {
    var out: [AXNode] = []
    func walk(_ n: AXNode) {
      out.append(n)
      for c in n.children { walk(c) }
    }
    walk(self)
    return out
  }

  public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

  public func first(_ query: AXQuery) -> AXNode? {
    if query.matches(self) { return self }
    for c in children { if let m = c.first(query) { return m } }
    return nil
  }

  public func all(_ query: AXQuery, limit: Int = .max) -> [AXNode] {
    var out: [AXNode] = []
    func walk(_ n: AXNode) {
      guard out.count < limit else { return }
      if query.matches(n) { out.append(n) }
      for c in n.children { walk(c) }
    }
    walk(self)
    return out
  }

  public func contains(_ query: AXQuery) -> Bool { first(query) != nil }

  /// The nearest node whose direct children include a match (e.g. "the list that holds caption rows").
  public func parent(ofChildMatching query: AXQuery) -> AXNode? {
    if children.contains(where: { query.matches($0) }) { return self }
    for c in children { if let p = c.parent(ofChildMatching: query) { return p } }
    return nil
  }

  /// Text content of static-text descendants, in order. Useful for "speaker, text" rows.
  public func texts(maxCount: Int = 64) -> [String] {
    var out: [String] = []
    func walk(_ n: AXNode) {
      guard out.count < maxCount else { return }
      if n.role == "AXStaticText" {
        let t = (n.value?.isEmpty == false ? n.value : n.title) ?? ""
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(trimmed) }
      }
      for c in n.children { walk(c) }
    }
    walk(self)
    return out
  }

  /// One-line label for debugging and inspect output.
  public var label: String {
    var parts: [String] = [role ?? "?"]
    if let s = subrole { parts.append("[\(s)]") }
    if let d = domId, !d.isEmpty { parts.append("#\(d)") }
    if let cls = domClasses, !cls.isEmpty { parts.append(cls.prefix(4).map { ".\($0)" }.joined()) }
    if let t = title, !t.isEmpty { parts.append("title=\(t.debugDescription)") }
    if let d = desc, !d.isEmpty { parts.append("desc=\(d.debugDescription)") }
    if let v = value, !v.isEmpty { parts.append("value=\(v.debugDescription)") }
    if let i = identifier, !i.isEmpty { parts.append("id=\(i)") }
    if let c = chromeId { parts.append("cid=\(c)") }
    if let p = pid { parts.append("pid=\(p)") }
    if minimized == true { parts.append("minimized") }
    if unlisted == true { parts.append("unlisted") }
    if let o = omittedChildren, o > 0 { parts.append("(+\(o) children omitted)") }
    return parts.joined(separator: " ")
  }

  /// Indented tree rendering.
  public func render(maxLines: Int = 2000) -> String {
    var lines: [String] = []
    func walk(_ n: AXNode, _ depth: Int) {
      guard lines.count < maxLines else { return }
      lines.append(String(repeating: "  ", count: depth) + n.label)
      for c in n.children { walk(c, depth + 1) }
    }
    walk(self, 0)
    if lines.count >= maxLines { lines.append("… (truncated at \(maxLines) lines)") }
    return lines.joined(separator: "\n")
  }

  /// Keep only subtrees matching `keep` (with their ancestor chains) plus shallow window nodes.
  /// Dropped branches are counted in `omittedChildren`. Returns nil when nothing under self is kept.
  public func pruned(keep: [AXQuery]) -> AXNode? {
    if keep.contains(where: { $0.matches(self) }) { return self }
    var copy = self
    copy.children = []
    var omitted = omittedChildren ?? 0
    for c in children {
      if let k = c.pruned(keep: keep) { copy.children.append(k) }
      else if c.role == "AXWindow" {
        var shallow = c
        shallow.omittedChildren = c.children.count + (c.omittedChildren ?? 0)
        shallow.children = []
        copy.children.append(shallow)
      } else { omitted += 1 }
    }
    copy.omittedChildren = omitted > 0 ? omitted : nil
    if copy.children.isEmpty && role != "AXApplication" && role != "AXWindow" { return nil }
    return copy
  }

  /// Return a copy with text fields transformed (for redaction / pseudonymization).
  public func mapTexts(_ transform: (_ field: String, _ role: String?, _ text: String) -> String?) -> AXNode {
    var n = self
    n.title = title.flatMap { transform("title", role, $0) }
    n.desc = desc.flatMap { transform("desc", role, $0) }
    n.value = value.flatMap { transform("value", role, $0) }
    n.children = children.map { $0.mapTexts(transform) }
    return n
  }
}

public enum TextMatch: Hashable, Sendable, CustomStringConvertible {
  case equals(String)
  case contains(String)
  case prefix(String)
  case suffix(String)
  case regex(String)

  public func matches(_ text: String?) -> Bool {
    guard let text else { return false }
    switch self {
    case .equals(let s): return text == s
    case .contains(let s): return text.contains(s)
    case .prefix(let s): return text.hasPrefix(s)
    case .suffix(let s): return text.hasSuffix(s)
    case .regex(let p): return text.range(of: p, options: .regularExpression) != nil
    }
  }

  public var description: String {
    switch self {
    case .equals(let s): return "=\(s.debugDescription)"
    case .contains(let s): return "~\(s.debugDescription)"
    case .prefix(let s): return "^\(s.debugDescription)"
    case .suffix(let s): return "$\(s.debugDescription)"
    case .regex(let s): return "/\(s)/"
    }
  }
}

/// Element matcher: all set fields must match.
public struct AXQuery: Hashable, Sendable, CustomStringConvertible {
  public var role: String?
  public var subrole: String?
  public var notSubrole: String?
  public var domId: String?
  public var domIdIn: Set<String>?
  public var domClass: String?
  /// Substring (case-insensitive) of the DOM id / of any DOM class.
  public var domIdContains: String?
  public var domClassContains: String?
  public var anyDomId: Bool?
  public var identifier: String?
  public var title: TextMatch?
  public var desc: TextMatch?
  public var value: TextMatch?

  public init(
    role: String? = nil, subrole: String? = nil, notSubrole: String? = nil, domId: String? = nil,
    domIdIn: Set<String>? = nil, domClass: String? = nil, domIdContains: String? = nil, domClassContains: String? = nil,
    anyDomId: Bool? = nil, identifier: String? = nil, title: TextMatch? = nil, desc: TextMatch? = nil, value: TextMatch? = nil
  ) {
    self.role = role; self.subrole = subrole; self.notSubrole = notSubrole; self.domId = domId
    self.domIdIn = domIdIn; self.domClass = domClass; self.domIdContains = domIdContains
    self.domClassContains = domClassContains; self.anyDomId = anyDomId; self.identifier = identifier
    self.title = title; self.desc = desc; self.value = value
  }

  /// Parse a compact selector: `#id`, `.class`, `#~part`, `.~part`, `role=AXButton`, `subrole=…`,
  /// `title^=prefix`, `title~=part`, `title==exact`; space-separated terms are AND-ed.
  public static func parse(_ text: String) throws -> AXQuery {
    var q = AXQuery()
    for term in text.split(separator: " ").map(String.init) where !term.isEmpty {
      if term.hasPrefix("#~") { q.domIdContains = String(term.dropFirst(2)) }
      else if term.hasPrefix(".~") { q.domClassContains = String(term.dropFirst(2)) }
      else if term == "#*" { q.anyDomId = true }
      else if term.hasPrefix("#") { q.domId = String(term.dropFirst()) }
      else if term.hasPrefix(".") { q.domClass = String(term.dropFirst()) }
      else if let r = term.range(of: "==") { try q.setText(String(term[..<r.lowerBound]), .equals(String(term[r.upperBound...]))) }
      else if let r = term.range(of: "^=") { try q.setText(String(term[..<r.lowerBound]), .prefix(String(term[r.upperBound...]))) }
      else if let r = term.range(of: "~=") { try q.setText(String(term[..<r.lowerBound]), .contains(String(term[r.upperBound...]))) }
      else if let r = term.range(of: "=") {
        let key = String(term[..<r.lowerBound]), value = String(term[r.upperBound...])
        switch key {
        case "role": q.role = value
        case "subrole": q.subrole = value
        case "id", "identifier": q.identifier = value
        default: try q.setText(key, .equals(value))
        }
      } else {
        throw ReflexError.invalidInput("cannot parse selector term \(term)")
      }
    }
    return q
  }

  private mutating func setText(_ field: String, _ m: TextMatch) throws {
    switch field {
    case "title": title = m
    case "desc", "description": desc = m
    case "value": value = m
    default: throw ReflexError.invalidInput("unknown selector field \(field)")
    }
  }

  public static func role(_ r: String) -> AXQuery { AXQuery(role: r) }
  public static func domId(_ id: String) -> AXQuery { AXQuery(domId: id) }
  public static func domId(in ids: Set<String>) -> AXQuery { AXQuery(domIdIn: ids) }
  public static func domClass(_ c: String) -> AXQuery { AXQuery(domClass: c) }
  public static var hasDomId: AXQuery { AXQuery(anyDomId: true) }
  public static func title(_ m: TextMatch) -> AXQuery { AXQuery(title: m) }

  public func matches(_ n: AXNode) -> Bool {
    if let role, n.role != role { return false }
    if let subrole, n.subrole != subrole { return false }
    if let notSubrole, n.subrole == notSubrole { return false }
    if let domId, n.domId != domId { return false }
    if let domIdIn { guard let d = n.domId, domIdIn.contains(d) else { return false } }
    if let domClass { guard n.domClasses?.contains(domClass) == true else { return false } }
    if let domIdContains { guard n.domId?.range(of: domIdContains, options: .caseInsensitive) != nil else { return false } }
    if let domClassContains {
      guard n.domClasses?.contains(where: { $0.range(of: domClassContains, options: .caseInsensitive) != nil }) == true else { return false }
    }
    if anyDomId == true { guard let d = n.domId, !d.isEmpty else { return false } }
    if let identifier, n.identifier != identifier { return false }
    if let title, !title.matches(n.title) { return false }
    if let desc, !desc.matches(n.desc) { return false }
    if let value, !value.matches(n.value) { return false }
    return true
  }

  /// Attributes a live search must read to evaluate this query.
  var neededAttributes: Set<String> {
    var s: Set<String> = [AXAttr.role]
    if subrole != nil || notSubrole != nil { s.insert(AXAttr.subrole) }
    if domId != nil || domIdIn != nil || anyDomId != nil || domIdContains != nil { s.insert(AXAttr.domId) }
    if domClass != nil || domClassContains != nil { s.insert(AXAttr.domClassList) }
    if identifier != nil { s.insert(AXAttr.identifier) }
    if title != nil { s.insert(AXAttr.title) }
    if desc != nil { s.insert(AXAttr.description) }
    if value != nil { s.insert(AXAttr.value) }
    return s
  }

  public var description: String {
    var p: [String] = []
    if let role { p.append("role=\(role)") }
    if let subrole { p.append("subrole=\(subrole)") }
    if let notSubrole { p.append("subrole!=\(notSubrole)") }
    if let domId { p.append("#\(domId)") }
    if let domIdIn { p.append("#{\(domIdIn.sorted().joined(separator: ","))}") }
    if let domClass { p.append(".\(domClass)") }
    if let domIdContains { p.append("#~\(domIdContains)") }
    if let domClassContains { p.append(".~\(domClassContains)") }
    if anyDomId == true { p.append("#*") }
    if let identifier { p.append("id=\(identifier)") }
    if let title { p.append("title\(title)") }
    if let desc { p.append("desc\(desc)") }
    if let value { p.append("value\(value)") }
    return p.isEmpty ? "*" : p.joined(separator: " ")
  }
}

/// Attribute names used by ReflexKit.
public enum AXAttr {
  public static let role = kAXRoleAttribute as String
  public static let subrole = kAXSubroleAttribute as String
  public static let title = kAXTitleAttribute as String
  public static let description = kAXDescriptionAttribute as String
  public static let value = kAXValueAttribute as String
  public static let identifier = kAXIdentifierAttribute as String
  public static let children = kAXChildrenAttribute as String
  public static let windows = kAXWindowsAttribute as String
  public static let focusedWindow = kAXFocusedWindowAttribute as String
  public static let mainWindow = kAXMainWindowAttribute as String
  public static let position = kAXPositionAttribute as String
  public static let size = kAXSizeAttribute as String
  public static let minimized = kAXMinimizedAttribute as String
  public static let focused = kAXFocusedAttribute as String
  public static let parent = kAXParentAttribute as String
  public static let domId = "AXDOMIdentifier"
  public static let domClassList = "AXDOMClassList"
  public static let chromeNodeId = "ChromeAXNodeId"
  public static let manualAccessibility = "AXManualAccessibility"
  public static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// Notification names (Chromium does not send AXCreated / AXLayoutChanged).
public enum AXNotification {
  public static let valueChanged = kAXValueChangedNotification as String
  public static let titleChanged = kAXTitleChangedNotification as String
  public static let uiElementDestroyed = kAXUIElementDestroyedNotification as String
  public static let created = kAXCreatedNotification as String
  public static let rowCountChanged = kAXRowCountChangedNotification as String
  public static let liveRegionChanged = "AXLiveRegionChanged"
  public static let liveRegionCreated = "AXLiveRegionCreated"
  public static let layoutChanged = "AXLayoutChanged"
  public static let selectedChildrenChanged = kAXSelectedChildrenChangedNotification as String
  public static let focusedUIElementChanged = kAXFocusedUIElementChangedNotification as String
  public static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
  public static let mainWindowChanged = kAXMainWindowChangedNotification as String
  public static let windowCreated = kAXWindowCreatedNotification as String
  public static let windowMiniaturized = kAXWindowMiniaturizedNotification as String
  public static let windowDeminiaturized = kAXWindowDeminiaturizedNotification as String
  public static let windowMoved = kAXWindowMovedNotification as String
  public static let windowResized = kAXWindowResizedNotification as String

  /// The set the dev recorder subscribes to.
  public static let recorderSet: [String] = [
    valueChanged, titleChanged, uiElementDestroyed, created, rowCountChanged, liveRegionChanged,
    liveRegionCreated, layoutChanged, selectedChildrenChanged, focusedUIElementChanged,
    focusedWindowChanged, mainWindowChanged, windowCreated, windowMiniaturized, windowDeminiaturized,
  ]
}
