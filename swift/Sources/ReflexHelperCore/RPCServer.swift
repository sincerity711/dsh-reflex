import Foundation
import ReflexKit

public struct RPCError: Error, Sendable, CustomStringConvertible {
  public var code: Int
  public var message: String
  public var data: JSON?

  public init(_ code: Int, _ message: String, data: JSON? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public static let parseError = RPCError(-32700, "parse error")
  public static func invalidRequest(_ m: String) -> RPCError { RPCError(-32600, m) }
  public static func methodNotFound(_ m: String) -> RPCError { RPCError(-32601, "method not found: \(m)") }
  public static func invalidParams(_ m: String) -> RPCError { RPCError(-32602, m) }
  public static func unauthorized(_ m: String) -> RPCError { RPCError(-32001, m) }
  public static func failed(_ m: String) -> RPCError { RPCError(-32000, m) }
  public static func notAllowed(_ m: String) -> RPCError { RPCError(-32003, m) }

  public var description: String { "RPC \(code): \(message)" }

  var json: JSON {
    var o: [String: JSON] = ["code": JSON(code), "message": .string(message)]
    if let data { o["data"] = data }
    return .object(o)
  }
}

/// One client connection: NDJSON framing over a non-blocking unix socket.
public final class RPCConnection: @unchecked Sendable, Hashable {
  public let id: Int
  let fd: Int32
  private let queue: DispatchQueue
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var inbound = Data()
  private var outbound = Data()
  private var writeSuspended = true
  private(set) var closed = false
  public var authenticated = false
  public var clientInfo: JSON = .null
  /// Per-connection subscriptions (e.g. "outbox", "logs").
  public var subscriptions = Set<String>()
  var onLine: ((RPCConnection, String) -> Void)?
  var onClose: ((RPCConnection) -> Void)?
  static let maxBuffer = 16 * 1024 * 1024

  init(id: Int, fd: Int32, queue: DispatchQueue) {
    self.id = id
    self.fd = fd
    self.queue = queue
  }

  public static func == (a: RPCConnection, b: RPCConnection) -> Bool { a.id == b.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }

  func start() {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    rs.setEventHandler { [weak self] in self?.readAvailable() }
    rs.setCancelHandler { [fd] in Darwin.close(fd) }
    readSource = rs
    let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    ws.setEventHandler { [weak self] in self?.flush() }
    writeSource = ws
    rs.resume()
  }

  private func readAvailable() {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(fd, &buf, buf.count)
      if n > 0 {
        inbound.append(buf, count: n)
        if inbound.count > RPCConnection.maxBuffer { close(); return }
        continue
      }
      if n == 0 { close(); return }
      if errno == EAGAIN || errno == EWOULDBLOCK { break }
      if errno == EINTR { continue }
      close()
      return
    }
    while let nl = inbound.firstIndex(of: 0x0A) {
      let lineData = inbound.subdata(in: inbound.startIndex..<nl)
      inbound.removeSubrange(inbound.startIndex...nl)
      if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine?(self, line) }
      if closed { return }
    }
  }

  /// Queue one JSON line. Must be called on the server queue.
  func sendLine(_ line: String) {
    guard !closed else { return }
    outbound.append(Data((line + "\n").utf8))
    if outbound.count > RPCConnection.maxBuffer { close(); return }
    flush()
  }

  private func flush() {
    while !outbound.isEmpty {
      let n = outbound.withUnsafeBytes { raw in write(fd, raw.baseAddress!, raw.count) }
      if n > 0 {
        outbound.removeSubrange(0..<n)
        continue
      }
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        if writeSuspended { writeSuspended = false; writeSource?.resume() }
        return
      }
      if n < 0 && errno == EINTR { continue }
      close()
      return
    }
    if !writeSuspended { writeSuspended = true; writeSource?.suspend() }
  }

  public func close() {
    guard !closed else { return }
    closed = true
    if writeSuspended { writeSource?.resume() }
    writeSource?.cancel()
    readSource?.cancel()
    onClose?(self)
  }

  public func respond(id: JSON, result: Result<JSON, RPCError>) {
    var o: [String: JSON] = ["jsonrpc": "2.0", "id": id]
    switch result {
    case .success(let r): o["result"] = r
    case .failure(let e): o["error"] = e.json
    }
    sendLine(JSON.object(o).serialized())
  }

  public func notify(_ method: String, _ params: JSON) {
    sendLine(JSON.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).serialized())
  }
}

public struct RPCRequest: Sendable {
  public let id: JSON?
  public let method: String
  public let params: JSON

  public var isNotification: Bool { id == nil }
}

/// Unix-socket JSON-RPC 2.0 server (NDJSON). All callbacks run on `queue`.
public final class RPCServer: @unchecked Sendable {
  public let path: String
  let queue: DispatchQueue
  private var listenFd: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var nextId = 0
  public private(set) var connections = Set<RPCConnection>()
  /// Return a result, or nil to answer later via `connection.respond`.
  public var handler: ((RPCConnection, RPCRequest, @escaping (Result<JSON, RPCError>) -> Void) -> Void)?
  public var onDisconnect: ((RPCConnection) -> Void)?

  public init(path: String, queue: DispatchQueue) {
    self.path = path
    self.queue = queue
  }

  public func start() throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RPCError.failed("socket(): \(String(cString: strerror(errno)))") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      close(fd)
      throw RPCError.failed("socket path too long: \(path)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (i, b) in bytes.enumerated() { raw[i] = b }
      raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let oldMask = umask(0o077)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    umask(oldMask)
    guard bound == 0 else {
      let msg = String(cString: strerror(errno))
      close(fd)
      throw RPCError.failed("bind(\(path)): \(msg)")
    }
    chmod(path, 0o600)
    guard listen(fd, 16) == 0 else {
      close(fd)
      throw RPCError.failed("listen(): \(String(cString: strerror(errno)))")
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    listenFd = fd
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    src.setEventHandler { [weak self] in self?.acceptAll() }
    src.setCancelHandler { close(fd) }
    acceptSource = src
    src.resume()
  }

  public func stop() {
    for c in connections { c.close() }
    acceptSource?.cancel()
    acceptSource = nil
    unlink(path)
  }

  private func acceptAll() {
    while true {
      let cfd = accept(listenFd, nil, nil)
      if cfd < 0 { return }
      // Only the same user may connect (the socket is 0600 in a 0700 dir; double-check the peer).
      var uid: uid_t = 0
      var gid: gid_t = 0
      if getpeereid(cfd, &uid, &gid) != 0 || uid != getuid() {
        close(cfd)
        continue
      }
      nextId += 1
      let conn = RPCConnection(id: nextId, fd: cfd, queue: queue)
      conn.onLine = { [weak self] c, line in self?.receive(c, line) }
      conn.onClose = { [weak self] c in
        self?.connections.remove(c)
        self?.onDisconnect?(c)
      }
      connections.insert(conn)
      conn.start()
    }
  }

  private func receive(_ conn: RPCConnection, _ line: String) {
    guard let json = try? JSON.parse(line), case .object(let o) = json else {
      conn.respond(id: .null, result: .failure(.parseError))
      return
    }
    guard let method = o["method"]?.string else {
      // Responses from clients are not used by this server.
      return
    }
    let request = RPCRequest(id: o["id"], method: method, params: o["params"] ?? .object([:]))
    guard let handler else {
      if let id = request.id { conn.respond(id: id, result: .failure(.methodNotFound(method))) }
      return
    }
    handler(conn, request) { [weak conn] result in
      guard let conn, let id = request.id else { return }
      conn.queueRespond(id: id, result: result)
    }
  }

  public func broadcast(_ method: String, _ params: JSON, subscription: String) {
    for c in connections where c.authenticated && c.subscriptions.contains(subscription) {
      c.notify(method, params)
    }
  }
}

extension RPCConnection {
  /// Respond from any thread (hops to the server queue).
  func queueRespond(id: JSON, result: Result<JSON, RPCError>) {
    queue.async { [weak self] in self?.respond(id: id, result: result) }
  }
}
