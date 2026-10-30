import AppKit
import ApplicationServices
import Foundation

/// Real Accessibility backend.
///
/// - Batch-reads attributes with `AXUIElementCopyMultipleAttributeValues`.
/// - Never activates the target app; every element call has a short messaging timeout.
/// - Observers live on a dedicated CFRunLoop thread (see `AXObserverHub`).
public final class LiveAX: AXSource, @unchecked Sendable {
  public let clock: ReflexClock
  let hub = AXObserverHub()
  private let statsBox = Locked(AXStats())
  /// Original values of web-accessibility switches we changed: [pid: [attribute: original]].
  private let modified = Locked([Int32: [String: Bool?]]())
  /// Windows returned by the last `windows` call, per pid.
  private let returned = Locked([Int32: [AXRef]]())
  private let messagingTimeout: Float

  public init(clock: ReflexClock = LiveClock(), messagingTimeout: Float = 0.4) {
    self.clock = clock
    self.messagingTimeout = messagingTimeout
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
  }

  public func isTrusted() -> Bool { AXIsProcessTrusted() }

  public func runningApps(_ bundleIds: Set<String>) -> [AppInfo] {
    var out: [AppInfo] = []
    for bundleId in bundleIds.sorted() {
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) where !app.isTerminated {
        out.append(AppInfo(pid: app.processIdentifier, bundleId: bundleId, name: app.localizedName ?? bundleId,
                           isActive: app.isActive, isHidden: app.isHidden))
      }
    }
    return out
  }

  public func appRef(_ app: AppInfo) -> AXRef {
    let el = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(el, messagingTimeout)
    return AXRef(live: el, pid: app.pid)
  }

  /// The app's AXWindows list plus the windows it leaves out. AXWindows only holds windows on Spaces
  /// that are on screen (and minimized ones), so a full-screen window the user switched away from drops
  /// out of it. Added after the listed ones, marked `unlisted`: the app's focused and main windows, and
  /// every window returned last time whose handle still answers as a window.
  public func windows(_ app: AppInfo) throws -> [AXRef] {
    let root = appRef(app)
    guard let el = root.element else { return [] }
    let (value, err) = timed { copyAttribute(el, AXAttr.windows) }
    if err == .apiDisabled { throw ReflexError.notTrusted }
    var out: [AXRef] = ((value as? [AnyObject]) ?? []).compactMap { item in
      guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
      let w = item as! AXUIElement
      return AXRef(live: w, pid: pidOf(w) ?? app.pid)
    }
    var candidates: [AXUIElement] = []
    for name in [AXAttr.focusedWindow, AXAttr.mainWindow] {
      let (v, _) = timed { copyAttribute(el, name) }
      if let v, CFGetTypeID(v) == AXUIElementGetTypeID() { candidates.append(v as! AXUIElement) }
    }
    candidates += (returned.current[app.pid] ?? []).compactMap(\.element)
    for w in candidates where !out.contains(where: { $0.element.map { CFEqual($0, w) } ?? false }) {
      let (role, roleErr) = timed { copyAttribute(w, AXAttr.role) }
      guard roleErr == .success, role as? String == "AXWindow" else { continue }
      out.append(AXRef(live: w, pid: pidOf(w) ?? app.pid, unlisted: true))
    }
    returned.withLock { $0[app.pid] = out }
    return out
  }

  public func read(_ ref: AXRef, _ limits: ReadLimits) throws -> AXNode {
    guard let el = ref.element else { throw ReflexError.axFailure("not a live element") }
    let deadline = Date().addingTimeInterval(limits.timeBudget)
    var remaining = max(1, limits.maxNodes)
    var names = [AXAttr.role, AXAttr.subrole, AXAttr.title, AXAttr.description, AXAttr.value,
                 AXAttr.identifier, AXAttr.domId, AXAttr.domClassList, AXAttr.chromeNodeId,
                 AXAttr.minimized, AXAttr.children]
    if limits.includeFrames { names += [AXAttr.position, AXAttr.size] }

    func visit(_ el: AXUIElement, pid: Int32, parentPid: Int32?, depth: Int) throws -> AXNode {
      remaining -= 1
      let attrs = batch(el, names)
      if attrs.apiDisabled { throw ReflexError.notTrusted }
      if attrs.invalid && depth == 0 { throw ReflexError.elementGone }
      var node = makeNode(attrs, limits: limits)
      node.ref = AXRef(live: el, pid: pid, unlisted: depth == 0 && ref.unlisted)
      if depth == 0 && ref.unlisted { node.unlisted = true }
      if let parentPid, parentPid != pid { node.pid = pid }
      if parentPid == nil { node.pid = pid }
      let kids = attrs.children
      guard !kids.isEmpty else { return node }
      if depth >= limits.maxDepth || remaining <= 0 || Date() > deadline {
        node.omittedChildren = kids.count
        return node
      }
      let ordered = limits.tailFirst == true ? Array(kids.reversed()) : kids
      for (i, child) in ordered.enumerated() {
        if remaining <= 0 || Date() > deadline {
          node.omittedChildren = kids.count - i
          break
        }
        let childPid = pidOf(child) ?? pid
        node.children.append(try visit(child, pid: childPid, parentPid: pid, depth: depth + 1))
      }
      if limits.tailFirst == true { node.children.reverse() }
      return node
    }
    return try visit(el, pid: pidOf(el) ?? ref.pid, parentPid: nil, depth: 0)
  }

  public func find(in ref: AXRef, _ query: AXQuery, _ limits: FindLimits) throws -> [AXNode] {
    guard let root = ref.element else { throw ReflexError.axFailure("not a live element") }
    let deadline = Date().addingTimeInterval(limits.timeBudget)
    var names = Array(query.neededAttributes.union([AXAttr.role, AXAttr.domId, AXAttr.chromeNodeId]))
    names.append(AXAttr.children)
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    var out: [AXNode] = []
    while let (el, depth) = stack.popLast() {
      visited += 1
      if visited > limits.maxNodes || Date() > deadline { break }
      let attrs = batch(el, names)
      if attrs.apiDisabled { throw ReflexError.notTrusted }
      var node = makeNode(attrs, limits: ReadLimits())
      if query.matches(node) {
        node.ref = AXRef(live: el, pid: pidOf(el) ?? ref.pid)
        out.append(node)
        if out.count >= limits.maxMatches { break }
      }
      if depth < limits.maxDepth {
        // Reverse so the stack pops children in document order.
        for child in attrs.children.reversed() { stack.append((child, depth + 1)) }
      }
    }
    return out
  }

  public func subscribe(pid: Int32, notifications: [String], handler: @escaping @Sendable (AXNotice) -> Void) throws -> AXSubscription {
    try hub.subscribe(pid: pid, notifications: notifications, handler: handler)
  }

  public func parent(of ref: AXRef) throws -> AXRef? {
    guard let el = ref.element else { throw ReflexError.axFailure("not a live element") }
    let (value, err) = timed { copyAttribute(el, AXAttr.parent) }
    if err == .apiDisabled { throw ReflexError.notTrusted }
    if err == .invalidUIElement { throw ReflexError.elementGone }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let parent = value as! AXUIElement
    return AXRef(live: parent, pid: pidOf(parent) ?? ref.pid)
  }

  public func getBool(_ ref: AXRef, _ attribute: String) -> Bool? {
    guard let el = ref.element else { return nil }
    let (value, _) = timed { copyAttribute(el, attribute) }
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
  }

  @discardableResult
  public func setBool(_ ref: AXRef, _ attribute: String, _ value: Bool) -> AXResult {
    guard let el = ref.element else { return .failure }
    if attribute == AXAttr.enhancedUserInterface || attribute == AXAttr.manualAccessibility {
      let original = getBool(ref, attribute)
      modified.withLock { map in
        if map[ref.pid]?[attribute] == nil { map[ref.pid, default: [:]][attribute] = .some(original) }
      }
    }
    let (_, err) = timed { () -> (CFTypeRef?, AXError) in
      (nil, AXUIElementSetAttributeValue(el, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef))
    }
    switch err {
    case .success: return .success
    case .attributeUnsupported, .notImplemented: return .unsupported
    case .apiDisabled: return .notPermitted
    default: return .failure
    }
  }

  public func perform(_ ref: AXRef, _ action: String) throws {
    guard let el = ref.element else { throw ReflexError.axFailure("not a live element") }
    let (_, err) = timed { () -> (CFTypeRef?, AXError) in (nil, AXUIElementPerformAction(el, action as CFString)) }
    if err != .success { throw ReflexError.axFailure("perform \(action) failed: \(err.rawValue)") }
  }

  public func stats() -> AXStats { statsBox.current }

  public func shutdown() {
    // Order matters for Chromium: remove notifications, restore switches, then tear down run loop sources.
    hub.removeAllNotifications()
    let changes = modified.withLock { map -> [Int32: [String: Bool?]] in
      let copy = map
      map.removeAll()
      return copy
    }
    for (pid, attrs) in changes {
      let el = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(el, messagingTimeout)
      for (attr, original) in attrs {
        let restore = original ?? false
        AXUIElementSetAttributeValue(el, attr as CFString, (restore ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
      }
    }
    hub.invalidate()
  }

  // MARK: helpers

  private func timed<T>(_ body: () -> (T, AXError)) -> (T, AXError) {
    let start = DispatchTime.now().uptimeNanoseconds
    let (value, err) = body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    statsBox.withLock {
      $0.calls += 1
      $0.millis += ms
      if err != .success && err != .noValue && err != .attributeUnsupported { $0.errors += 1 }
    }
    return (value, err)
  }

  private func copyAttribute(_ el: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return (value, err)
  }

  struct Batch {
    var values: [String: CFTypeRef] = [:]
    var children: [AXUIElement] = []
    var apiDisabled = false
    var invalid = false
  }

  private func batch(_ el: AXUIElement, _ names: [String]) -> Batch {
    var out = Batch()
    let (raw, err) = timed { () -> (CFArray?, AXError) in
      var values: CFArray?
      let e = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
      return (values, e)
    }
    if err == .apiDisabled { out.apiDisabled = true; return out }
    if err == .invalidUIElement { out.invalid = true; return out }
    guard err == .success, let array = raw as? [AnyObject] else { return out }
    for (i, name) in names.enumerated() where i < array.count {
      let item = array[i]
      if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError {
        var code: AXError = .success
        if AXValueGetValue(item as! AXValue, .axError, &code), code == .invalidUIElement { out.invalid = true }
        continue
      }
      if name == AXAttr.children {
        if let kids = item as? [AnyObject] {
          out.children = kids.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        continue
      }
      out.values[name] = item
    }
    return out
  }

  private func makeNode(_ b: Batch, limits: ReadLimits) -> AXNode {
    func str(_ name: String) -> String? {
      guard let v = b.values[name] else { return nil }
      var s: String?
      if let x = v as? String { s = x }
      else if let x = v as? NSAttributedString { s = x.string }
      else if let x = v as? URL { s = x.absoluteString }
      else if CFGetTypeID(v) == CFNumberGetTypeID() || CFGetTypeID(v) == CFBooleanGetTypeID() { s = "\(v)" }
      guard var text = s, !text.isEmpty else { return nil }
      if text.count > limits.maxTextLength { text = String(text.prefix(limits.maxTextLength)) + "…" }
      return text
    }
    var node = AXNode()
    node.role = str(AXAttr.role)
    node.subrole = str(AXAttr.subrole)
    node.title = str(AXAttr.title)
    node.desc = str(AXAttr.description)
    if node.role != "AXWindow" { node.value = str(AXAttr.value) }
    node.identifier = str(AXAttr.identifier)
    node.domId = str(AXAttr.domId)
    if let cls = b.values[AXAttr.domClassList] as? [String], !cls.isEmpty { node.domClasses = cls }
    node.chromeId = str(AXAttr.chromeNodeId)
    if let m = b.values[AXAttr.minimized] as? Bool, node.role == "AXWindow" { node.minimized = m }
    if limits.includeFrames, let p = b.values[AXAttr.position], let s = b.values[AXAttr.size],
       CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    {
      var point = CGPoint.zero
      var size = CGSize.zero
      AXValueGetValue(p as! AXValue, .cgPoint, &point)
      AXValueGetValue(s as! AXValue, .cgSize, &size)
      node.frame = Rect(x: point.x, y: point.y, w: size.width, h: size.height)
    }
    return node
  }

  private func pidOf(_ el: AXUIElement) -> Int32? {
    var pid: pid_t = 0
    return AXUIElementGetPid(el, &pid) == .success ? pid : nil
  }
}

// MARK: - observer hub

/// One AXObserver per pid on a dedicated CFRunLoop thread. Registrations are reference counted;
/// callbacks only enqueue (handlers must be cheap and non-blocking).
final class AXObserverHub: @unchecked Sendable {
  private final class PidObserver {
    let pid: Int32
    let observer: AXObserver
    let app: AXUIElement
    var counts: [String: Int] = [:]
    var handlers: [UInt64: (Set<String>, @Sendable (AXNotice) -> Void)] = [:]

    init(pid: Int32, observer: AXObserver, app: AXUIElement) {
      self.pid = pid
      self.observer = observer
      self.app = app
    }
  }

  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private let ready = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var observers: [Int32: PidObserver] = [:]
  private var nextId: UInt64 = 0

  private func ensureThread() -> CFRunLoop {
    lock.lock()
    if let rl = runLoop { lock.unlock(); return rl }
    let t = Thread { [weak self] in
      guard let self else { return }
      self.runLoop = CFRunLoopGetCurrent()
      // Keep the run loop alive with a dummy source.
      var ctx = CFRunLoopSourceContext()
      let src = CFRunLoopSourceCreate(nil, 0, &ctx)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
      self.ready.signal()
      CFRunLoopRun()
    }
    t.name = "ReflexKit.AXObserverHub"
    t.qualityOfService = .userInitiated
    thread = t
    t.start()
    lock.unlock()
    ready.wait()
    return runLoop!
  }

  /// Run a block synchronously on the hub thread.
  private func onHub<T>(_ body: @escaping () -> T) -> T {
    let rl = ensureThread()
    if CFRunLoopGetCurrent() === rl { return body() }
    var result: T?
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
      result = body()
      done.signal()
    }
    CFRunLoopWakeUp(rl)
    done.wait()
    return result!
  }

  func subscribe(pid: Int32, notifications: [String], handler: @escaping @Sendable (AXNotice) -> Void) throws -> AXSubscription {
    let result: Result<UInt64, Error> = onHub { [self] in
      let entry: PidObserver
      if let existing = observers[pid] {
        entry = existing
      } else {
        var obs: AXObserver?
        let err = AXObserverCreateWithInfoCallback(pid, axObserverCallback, &obs)
        guard err == .success, let obs else {
          return .failure(ReflexError.axFailure("AXObserverCreate(pid \(pid)) failed: \(err.rawValue)"))
        }
        let app = AXUIElementCreateApplication(pid)
        entry = PidObserver(pid: pid, observer: obs, app: app)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = entry
      }
      let refcon = Unmanaged.passUnretained(self).toOpaque()
      for name in Set(notifications) {
        if entry.counts[name, default: 0] == 0 {
          let err = AXObserverAddNotification(entry.observer, entry.app, name as CFString, refcon)
          if err != .success && err != .notificationAlreadyRegistered {
            // Unsupported notifications are not fatal; the poll fallback covers them.
            continue
          }
        }
        entry.counts[name, default: 0] += 1
      }
      nextId &+= 1
      entry.handlers[nextId] = (Set(notifications), handler)
      return .success(nextId)
    }
    let id = try result.get()
    return AXSubscription { [weak self] in self?.unsubscribe(pid: pid, id: id) }
  }

  private func unsubscribe(pid: Int32, id: UInt64) {
    onHub { [self] in
      guard let entry = observers[pid], let (names, _) = entry.handlers.removeValue(forKey: id) else { return }
      for name in names {
        let c = entry.counts[name, default: 1] - 1
        if c <= 0 {
          entry.counts.removeValue(forKey: name)
          AXObserverRemoveNotification(entry.observer, entry.app, name as CFString)
        } else {
          entry.counts[name] = c
        }
      }
      if entry.handlers.isEmpty {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        observers.removeValue(forKey: pid)
      }
    }
  }

  fileprivate func deliver(observer: AXObserver, element: AXUIElement, name: String) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    // Find the observer entry (callbacks run on the hub thread, so no lock needed).
    guard let entry = observers.values.first(where: { $0.observer === observer }) else { return }
    let owner = pid == 0 ? entry.pid : pid
    let notice = AXNotice(name: name, pid: owner, at: Date(), ref: AXRef(live: element, pid: owner))
    for (_, (names, handler)) in entry.handlers where names.contains(name) {
      handler(notice)
    }
  }

  func removeAllNotifications() {
    guard runLoop != nil else { return }
    onHub { [self] in
      for entry in observers.values {
        for name in entry.counts.keys {
          AXObserverRemoveNotification(entry.observer, entry.app, name as CFString)
        }
        entry.counts.removeAll()
        entry.handlers.removeAll()
      }
    }
  }

  func invalidate() {
    guard let rl = runLoop else { return }
    onHub { [self] in
      for entry in observers.values {
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(entry.observer))
      }
      observers.removeAll()
    }
    CFRunLoopStop(rl)
    lock.lock()
    runLoop = nil
    thread = nil
    lock.unlock()
  }

  var observedPids: [Int32] { onHub { [self] in Array(observers.keys) } }
}

private func axObserverCallback(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ info: CFDictionary?, _ refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
  hub.deliver(observer: observer, element: element, name: notification as String)
}
