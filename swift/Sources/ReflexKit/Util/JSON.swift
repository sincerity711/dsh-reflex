import Foundation

/// A dynamic JSON value. Used for program config, task input/output, and event payloads.
public enum JSON: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public subscript(key: String) -> JSON? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public subscript(index: Int) -> JSON? {
    if case .array(let a) = self, a.indices.contains(index) { return a[index] }
    return nil
  }

  public var string: String? { if case .string(let s) = self { return s }; return nil }
  public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var double: Double? { if case .number(let n) = self { return n }; return nil }
  public var int: Int? {
    if case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 { return Int(n) }
    return nil
  }
  public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
  public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
  public var isNull: Bool { if case .null = self { return true }; return false }

  /// Shallow merge: keys in `other` replace keys in `self` (objects only).
  public func merging(_ other: JSON) -> JSON {
    guard case .object(var base) = self, case .object(let over) = other else { return other }
    for (k, v) in over { base[k] = v }
    return .object(base)
  }

  /// Encode any Encodable value into JSON.
  public init<T: Encodable>(encoding value: T) throws {
    let data = try JSONEncoder().encode(value)
    self = try JSONDecoder().decode(JSON.self, from: data)
  }

  /// Decode this value into a Decodable type.
  public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
    let data = try JSONEncoder().encode(self)
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// Compact serialization with sorted keys (stable output).
  public func serialized() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  public static func parse(_ text: String) throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
  }

  public static func parse(_ data: Data) throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: data)
  }
}

extension JSON: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let b = try? c.decode(Bool.self) { self = .bool(b); return }
    if let n = try? c.decode(Double.self) { self = .number(n); return }
    if let s = try? c.decode(String.self) { self = .string(s); return }
    if let a = try? c.decode([JSON].self) { self = .array(a); return }
    if let o = try? c.decode([String: JSON].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n):
      if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    var o: [String: JSON] = [:]
    for (k, v) in elements { o[k] = v }
    self = .object(o)
  }
}

extension JSON {
  public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
  public init(_ value: Int) { self = .number(Double(value)) }
  public init(_ value: Double) { self = .number(value) }
  public init(_ value: Bool) { self = .bool(value) }
  public init(_ values: [String]) { self = .array(values.map(JSON.string)) }
  public init(_ date: Date) { self = .string(ISO8601.format(date)) }
}

/// ISO-8601 with milliseconds, UTC.
public enum ISO8601 {
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let lock = NSLock()

  public static func format(_ date: Date) -> String {
    lock.lock(); defer { lock.unlock() }
    return formatter.string(from: date)
  }

  public static func parse(_ text: String) -> Date? {
    lock.lock(); defer { lock.unlock() }
    if let d = formatter.date(from: text) { return d }
    let plain = ISO8601DateFormatter()
    return plain.date(from: text)
  }
}
