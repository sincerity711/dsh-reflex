import Foundation
import ReflexKit

public struct OutboxItem: Codable, Sendable, Hashable {
  public var seq: Int
  /// eventId for events, `result:<taskId>` for task results.
  public var id: String
  public var kind: String
  public var at: Date
  public var data: JSON

  public var json: JSON {
    ["seq": JSON(seq), "id": .string(id), "kind": .string(kind), "at": JSON(at), "data": data]
  }
}

/// Persistent, numbered queue of events and task results. Items are removed only after the
/// consumer acknowledges them (cumulative ack), so nothing is lost while DSH restarts.
public final class Outbox: @unchecked Sendable {
  private let fileURL: URL
  private let ackURL: URL
  private var appender: LineAppender
  private(set) var items: [OutboxItem] = []
  private(set) var nextSeq = 1
  private(set) var ackedSeq = 0
  private var linesInFile = 0
  private let lock = NSLock()
  public let maxItems: Int

  public init(directory: URL, maxItems: Int = 20000) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    fileURL = directory.appendingPathComponent("outbox.jsonl")
    ackURL = directory.appendingPathComponent("outbox.ack")
    appender = LineAppender(url: fileURL)
    self.maxItems = maxItems
    try load()
  }

  private func load() throws {
    if let text = try? String(contentsOf: ackURL, encoding: .utf8), let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
      ackedSeq = n
    }
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { nextSeq = ackedSeq + 1; return }
    for raw in text.split(separator: "\n") {
      linesInFile += 1
      guard let item = try? JSONCoding.decoder.decode(OutboxItem.self, from: Data(raw.utf8)) else { continue }
      nextSeq = max(nextSeq, item.seq + 1)
      if item.seq > ackedSeq { items.append(item) }
    }
    nextSeq = max(nextSeq, ackedSeq + 1)
    items.sort { $0.seq < $1.seq }
  }

  /// Persist a new item and return it (with its sequence number).
  @discardableResult
  public func append(kind: String, id: String, data: JSON, at: Date = Date()) throws -> OutboxItem {
    lock.lock(); defer { lock.unlock() }
    let item = OutboxItem(seq: nextSeq, id: id, kind: kind, at: at, data: data)
    try appender.append(try JSONCoding.line(item))
    appender.sync()
    nextSeq += 1
    linesInFile += 1
    items.append(item)
    if items.count > maxItems {
      // Bounded: drop the oldest unacknowledged items (reported in status as dropped).
      items.removeFirst(items.count - maxItems)
    }
    return item
  }

  public func pending(after seq: Int = 0) -> [OutboxItem] {
    lock.lock(); defer { lock.unlock() }
    return items.filter { $0.seq > seq }
  }

  public var depth: Int {
    lock.lock(); defer { lock.unlock() }
    return items.count
  }

  public var lastSeq: Int {
    lock.lock(); defer { lock.unlock() }
    return nextSeq - 1
  }

  /// Acknowledge everything up to and including `seq`.
  public func ack(upTo seq: Int) throws {
    lock.lock(); defer { lock.unlock() }
    guard seq > ackedSeq else { return }
    ackedSeq = min(seq, nextSeq - 1)
    items.removeAll { $0.seq <= ackedSeq }
    try AtomicFile.write(Data("\(ackedSeq)\n".utf8), to: ackURL)
    if linesInFile > 2000 && linesInFile > items.count * 4 { try compact() }
  }

  /// Rewrite the file with unacknowledged items only. Caller holds the lock.
  private func compact() throws {
    appender.close()
    let body = try items.map { try JSONCoding.line($0) }.joined(separator: "\n")
    try AtomicFile.write(Data((body.isEmpty ? "" : body + "\n").utf8), to: fileURL)
    linesInFile = items.count
    appender = LineAppender(url: fileURL)
  }
}
