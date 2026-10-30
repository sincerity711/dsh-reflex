import Foundation

/// How text found in UI trees is treated before it leaves the process (inspect output, fixtures).
public enum RedactionMode: String, Codable, Sendable, CaseIterable {
  /// Keep everything (only for local debugging; never commit such fixtures).
  case none
  /// Keep control labels (buttons, menu items, tabs…); pseudonymize all other text.
  case ui
  /// Pseudonymize all text except a small UI vocabulary.
  case pseudo
  /// Replace all text with its length.
  case mask
}

/// Deterministic text redaction. Pseudonymization maps each word to a fake word of the same length,
/// so prefix relations ("All right" ⊂ "All right, so…") survive — caption tests rely on that.
public struct Redactor: Sendable {
  public let mode: RedactionMode
  private let salt: String
  /// Extra words kept verbatim (lowercased), e.g. a scripted test utterance.
  private let keep: Set<String>

  static let controlRoles: Set<String> = [
    "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXTab", "AXPopUpButton",
    "AXMenuButton", "AXDisclosureTriangle", "AXToolbar", "AXSplitter", "AXIncrementor", "AXColorWell",
  ]

  /// Words kept verbatim in pseudo mode (UI chrome vocabulary, not user content).
  static let vocabulary: Set<String> = [
    "microsoft", "teams", "meeting", "meetings", "captions", "caption", "compact", "view", "with", "chat",
    "call", "calendar", "activity", "join", "leave", "mute", "unmute", "camera", "share", "more", "people",
    "react", "raise", "hand", "settings", "window", "live", "transcript", "edge", "chrome", "safari", "google",
    "new", "tab", "the", "and", "of", "a", "to", "in", "on", "for", "is", "you", "your", "elapsed", "time",
    "close", "minimize", "zoom", "back", "forward", "reload", "search", "address", "bar", "toolbar", "menu",
    "pop", "out", "turn", "off", "speaker", "notes", "files", "apps", "help",
  ]

  public init(mode: RedactionMode, salt: String = UUID().uuidString, keep: Set<String> = []) {
    self.mode = mode
    self.salt = salt
    self.keep = Set(keep.map { $0.lowercased() })
  }

  public func apply(_ node: AXNode) -> AXNode {
    guard mode != .none else { return node }
    return node.mapTexts { _, role, text in redact(text, role: role) }
  }

  public func redact(_ text: String, role: String?) -> String {
    switch mode {
    case .none: return text
    case .mask: return "‹\(text.count) chars›"
    case .ui:
      if let role, Redactor.controlRoles.contains(role) { return text }
      return pseudonymize(text)
    case .pseudo: return pseudonymize(text)
    }
  }

  /// Word-wise pseudonymization: letters are replaced deterministically, punctuation/digits/spaces kept.
  public func pseudonymize(_ text: String) -> String {
    var out = ""
    var word = ""
    func flush() {
      guard !word.isEmpty else { return }
      let lower = word.lowercased()
      if Redactor.vocabulary.contains(lower) || keep.contains(lower) { out += word } else { out += fake(word) }
      word = ""
    }
    for ch in text {
      if ch.isLetter { word.append(ch) } else {
        flush()
        out.append(ch)
      }
    }
    flush()
    return out
  }

  /// Character i of the fake depends only on characters 0...i of the word, so the fake of a prefix
  /// is a prefix of the fake ("oth" -> "qzm", "other" -> "qzmvd").
  private func fake(_ word: String) -> String {
    var h = FNV1a64()
    h.combine(salt)
    let lower = Array("abcdefghijklmnopqrstuvwxyz")
    var out = ""
    for (i, ch) in word.enumerated() {
      for b in String(ch).lowercased().utf8 { h.combineByte(b) }
      let isCJK = ch.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false
      if isCJK {
        out.append("某")
        continue
      }
      let c = lower[Int((h.value >> 33) % 26)]
      out.append(i == 0 && ch.isUppercase ? Character(c.uppercased()) : c)
    }
    return out
  }
}
