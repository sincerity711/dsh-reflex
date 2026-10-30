import Foundation

/// ULID: 48-bit millisecond timestamp + 80 random bits, Crockford base32 (26 chars).
public enum ULID {
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  public static func make(date: Date = Date()) -> String {
    let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xff) }
    var rng = SystemRandomNumberGenerator()
    for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
    // 128 bits -> 26 base32 chars (first char carries 3 bits).
    var value = bytes.reduce(into: [UInt8]()) { $0.append($1) }
    var out = [Character](repeating: "0", count: 26)
    for i in stride(from: 25, through: 0, by: -1) {
      var carry: UInt16 = 0
      // divide the big number by 32
      var next = [UInt8](repeating: 0, count: value.count)
      for (j, b) in value.enumerated() {
        let cur = (carry << 8) | UInt16(b)
        next[j] = UInt8(cur / 32)
        carry = cur % 32
      }
      out[i] = alphabet[Int(carry)]
      value = next
    }
    return String(out)
  }
}

/// 64-bit FNV-1a, used for content hashes (not security).
public struct FNV1a64 {
  public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

  public init() {}

  public mutating func combine(_ string: String?) {
    guard let string else { combineByte(0xfe); return }
    for b in string.utf8 { combineByte(b) }
    combineByte(0xff)
  }

  public mutating func combine(_ int: Int) {
    var v = UInt64(bitPattern: Int64(int))
    for _ in 0..<8 { combineByte(UInt8(v & 0xff)); v >>= 8 }
  }

  public mutating func combine(_ u: UInt64) {
    var v = u
    for _ in 0..<8 { combineByte(UInt8(v & 0xff)); v >>= 8 }
  }

  public mutating func combineByte(_ b: UInt8) {
    value ^= UInt64(b)
    value = value &* 0x0000_0100_0000_01b3
  }

  public var hex: String { String(format: "%016llx", value) }

  public static func hash(_ s: String) -> String {
    var h = FNV1a64(); h.combine(s); return h.hex
  }
}

public enum AtomicFile {
  /// Write data atomically (temp file + rename). Creates parent directories.
  public static func write(_ data: Data, to url: URL, permissions: Int16 = 0o600) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max)).tmp")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(permissions))
    guard fd >= 0 else { throw POSIXError.current("open \(tmp.path)") }
    var ok = false
    defer { if !ok { unlink(tmp.path) } }
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          close(fd)
          throw POSIXError.current("write \(tmp.path)")
        }
        offset += n
      }
    }
    fsync(fd)
    close(fd)
    if rename(tmp.path, url.path) != 0 { throw POSIXError.current("rename \(url.path)") }
    ok = true
  }

  public static func writeJSON<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(ISO8601.format(date))
    }
    try write(enc.encode(value), to: url)
  }

  public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONCoding.decoder.decode(T.self, from: data)
  }
}

/// Append-only line writer (JSONL), opened lazily and fsync'd on demand.
public final class LineAppender: @unchecked Sendable {
  public let url: URL
  private var handle: FileHandle?
  private let lock = NSLock()

  public init(url: URL) { self.url = url }

  public func append(_ line: String) throws {
    lock.lock(); defer { lock.unlock() }
    if handle == nil {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      handle = try FileHandle(forWritingTo: url)
      try handle?.seekToEnd()
    }
    try handle?.write(contentsOf: Data((line + "\n").utf8))
  }

  public func sync() {
    lock.lock(); defer { lock.unlock() }
    try? handle?.synchronize()
  }

  public func close() {
    lock.lock(); defer { lock.unlock() }
    try? handle?.close()
    handle = nil
  }

  deinit { try? handle?.close() }
}

public enum JSONCoding {
  public static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(ISO8601.format(date))
    }
    return e
  }()

  public static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
      let c = try decoder.singleValueContainer()
      if let s = try? c.decode(String.self), let date = ISO8601.parse(s) { return date }
      if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n / 1000) }
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date")
    }
    return d
  }()

  /// Serialize to one compact line (no newlines are possible in JSON output).
  public static func line<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

extension POSIXError {
  static func current(_ context: String) -> Error {
    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue),
                   userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(errno)))"])
  }
}

extension Duration {
  public var seconds: Double {
    let c = components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }

  public static func secondsDouble(_ s: Double) -> Duration { .milliseconds(Int64((s * 1000).rounded())) }
}

/// Mutable box guarded by a lock.
public final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  public init(_ value: Value) { self.value = value }

  @discardableResult
  public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    lock.lock(); defer { lock.unlock() }
    return try body(&value)
  }

  public var current: Value { withLock { $0 } }
}
