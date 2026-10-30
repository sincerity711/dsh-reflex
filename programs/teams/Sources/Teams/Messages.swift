import Foundation
import ReflexKit

// Teams messages: RESERVED interface (not part of the v1 manifest).
//
// Planned additions to the `teams` program:
// - event `teams.message.received` with payload `TeamsMessage`;
// - tasks `draftReply` and `sendReply`. Sending needs a declared action in the manifest
//   (`ActionDecl("sendMessage", …)`), capability `.perform`, and the user's confirmation.
// v1 ships the types, the send guard and its tests, and stubs that refuse to run.

/// Payload of the future `teams.message.received` event. All text is untrusted UI data.
struct TeamsMessage: Codable, Equatable {
  var chatKey: String
  var chatTitle: String
  var sender: String
  var isSelf: Bool
  var text: String
  var ts: Date
}

struct SendGuardConfig {
  /// Only these chats (by key) may ever receive a message.
  var allowedChats: Set<String>
  var maxPerMinute = 3
  var maxPerChatPerHour = 10
  /// Identical text to the same chat is refused for this long (reply loops).
  var repeatWindow: TimeInterval = 24 * 3600
}

struct SendRequest: Equatable {
  var chatKey: String
  var expectedChatTitle: String
  var text: String
}

/// What the program re-reads from the UI right before sending.
struct SendTarget: Equatable {
  var currentChatTitle: String
  var inputFocused: Bool
  var inputBelongsToChat: Bool
}

enum SendDecision: Equatable {
  case allow
  case deny(String)
}

/// Checks every precondition before a message may be sent, and filters our own messages.
struct SendGuard {
  var config: SendGuardConfig
  private(set) var sent: [(hash: String, chatKey: String, at: Date)] = []

  init(config: SendGuardConfig) { self.config = config }

  static func hash(_ chatKey: String, _ text: String) -> String {
    FNV1a64.hash("\(chatKey)\u{0}\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
  }

  func check(_ r: SendRequest, target: SendTarget, now: Date) -> SendDecision {
    guard config.allowedChats.contains(r.chatKey) else { return .deny("chat \(r.chatKey) is not whitelisted") }
    guard target.currentChatTitle == r.expectedChatTitle else { return .deny("the open chat changed (expected \(r.expectedChatTitle))") }
    guard target.inputFocused, target.inputBelongsToChat else { return .deny("the message box is not the open chat's input") }
    guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .deny("empty message") }
    let h = Self.hash(r.chatKey, r.text)
    if sent.contains(where: { $0.hash == h && now.timeIntervalSince($0.at) < config.repeatWindow }) {
      return .deny("the same text was already sent to this chat (loop guard)")
    }
    if sent.filter({ now.timeIntervalSince($0.at) < 60 }).count >= config.maxPerMinute { return .deny("rate limit (per minute)") }
    if sent.filter({ $0.chatKey == r.chatKey && now.timeIntervalSince($0.at) < 3600 }).count >= config.maxPerChatPerHour {
      return .deny("rate limit (per chat per hour)")
    }
    return .allow
  }

  mutating func recordSent(_ r: SendRequest, at now: Date) {
    sent.append((Self.hash(r.chatKey, r.text), r.chatKey, now))
    sent.removeAll { now.timeIntervalSince($0.at) > config.repeatWindow }
  }

  /// Our own messages (and echoes of what we sent) never become `teams.message.received`.
  func shouldEmit(_ m: TeamsMessage, now: Date) -> Bool {
    if m.isSelf { return false }
    let h = Self.hash(m.chatKey, m.text)
    return !sent.contains { $0.hash == h && now.timeIntervalSince($0.at) < config.repeatWindow }
  }
}

/// Stubs for the reserved tasks: they are not declared in the manifest and refuse to run.
enum TeamsMessageTasks {
  static func draftReply(_ input: JSON) -> TaskResult { .failed("draftReply is reserved and not available in v1") }
  static func sendReply(_ input: JSON) -> TaskResult { .failed("sendReply is reserved and not available in v1") }
}
