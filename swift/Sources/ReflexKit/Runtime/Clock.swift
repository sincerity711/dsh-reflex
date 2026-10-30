import Foundation

/// Time source. Programs must use `ctx.clock` (or tick sequences) instead of `Date()` / `Task.sleep`,
/// so replay tests can run on virtual time.
public protocol ReflexClock: AnyObject, Sendable {
  func now() -> Date
  func sleep(until date: Date) async throws
  var isVirtual: Bool { get }
}

extension ReflexClock {
  public func sleep(for duration: Duration) async throws {
    try await sleep(until: now().addingTimeInterval(duration.seconds))
  }
}

public final class LiveClock: ReflexClock, @unchecked Sendable {
  public init() {}
  public func now() -> Date { Date() }
  public var isVirtual: Bool { false }

  public func sleep(until date: Date) async throws {
    let delta = date.timeIntervalSinceNow
    if delta > 0 { try await Task.sleep(nanoseconds: UInt64(delta * 1e9)) }
  }
}

/// Virtual time for replay. Advances only when a (single) consumer sleeps or asks for the next tick.
public final class VirtualClock: ReflexClock, @unchecked Sendable {
  private let current: Locked<Date>

  public init(start: Date) { current = Locked(start) }

  public func now() -> Date { current.current }
  public var isVirtual: Bool { true }

  public func sleep(until date: Date) async throws {
    try Task.checkCancellation()
    advance(to: date)
  }

  public func advance(to date: Date) {
    current.withLock { if date > $0 { $0 = date } }
  }
}

/// One-shot wake-up primitive with timeout. `fire()` before `wait` is remembered.
final class WakeSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var waiter: (id: UInt64, cont: CheckedContinuation<Bool, Never>)?
  private var timer: Task<Void, Never>?
  private var nextId: UInt64 = 0

  func fire() {
    lock.lock()
    if let w = waiter {
      waiter = nil
      timer?.cancel()
      timer = nil
      lock.unlock()
      w.cont.resume(returning: true)
    } else {
      pending = true
      lock.unlock()
    }
  }

  /// Returns true when fired, false on timeout. `deadline == nil` waits for a fire only.
  func wait(until deadline: Date?) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      lock.lock()
      if pending {
        pending = false
        lock.unlock()
        cont.resume(returning: true)
        return
      }
      nextId &+= 1
      let id = nextId
      waiter = (id, cont)
      if let deadline {
        let delay = max(0, deadline.timeIntervalSinceNow)
        timer = Task.detached { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
          if Task.isCancelled { return }
          self?.timeout(id)
        }
      }
      lock.unlock()
    }
  }

  private func timeout(_ id: UInt64) {
    lock.lock()
    guard let w = waiter, w.id == id else { lock.unlock(); return }
    waiter = nil
    timer = nil
    lock.unlock()
    w.cont.resume(returning: false)
  }
}
