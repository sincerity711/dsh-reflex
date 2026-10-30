import AppKit
import Foundation

public struct Tick: Sendable {
  public enum Reason: String, Sendable {
    case initial
    case timer
    case notification
    case appsChanged
  }

  public let at: Date
  public let reason: Reason
  /// AX notices collected since the previous tick (empty for timer ticks).
  public let notices: [AXNotice]
}

/// Tick loop: `for try await tick in ctx.ticks(...)`. Ends (returns nil) when the context stops.
///
/// Live: wakes on the timer, on AX notifications from the declared apps' processes (debounced),
/// and on app launch/quit. Replay: steps virtual time to the next timer or recorded notice.
public final class Ticks: AsyncSequence, AsyncIteratorProtocol, @unchecked Sendable {
  public typealias Element = Tick

  let ctx: ProgramContext
  let interval: Double
  let notifications: Set<String>
  let debounce: Double
  let tracker: LoopTracker
  private let signal = WakeSignal()
  private let pending = Locked([AXNotice]())
  private let appsChanged = Locked(false)
  private var subscriptions: [Int32: AXSubscription] = [:]
  private var workspaceObservers: [NSObjectProtocol] = []
  private var started = false
  private var lastTickAt: Date?
  /// Replay: one last tick is delivered exactly at the stop time so the final state is observed.
  private var finalTickDelivered = false

  init(ctx: ProgramContext, name: String, interval: Double, notifications: Set<String>, debounce: Double) {
    self.ctx = ctx
    self.interval = Swift.max(0.05, interval)
    self.notifications = notifications
    self.debounce = Swift.max(0, debounce)
    self.tracker = ctx.core.tracker(name, interval: interval)
    ctx.stop.register(signal)
  }

  deinit {
    for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    for s in subscriptions.values { s.cancel() }
  }

  public func makeAsyncIterator() -> Ticks { self }

  public func next() async throws -> Tick? {
    tracker.beginWait()
    let tick = try await nextTick()
    if let tick { tracker.delivered(at: tick.at) }
    return tick
  }

  private func nextTick() async throws -> Tick? {
    if ctx.stop.isStopped { return nil }
    let clock = ctx.clock
    if !started {
      started = true
      startAppWatch()
      refreshSubscriptions()
      if let replay = ctx.core.source as? ReplayAX, let stopAt = ctx.stopAt, clock.now() >= stopAt {
        replay.advance(to: stopAt)
        ctx.stop.request(ctx.stopAtReason)
        return nil
      }
      lastTickAt = clock.now()
      return Tick(at: clock.now(), reason: .initial, notices: [])
    }
    refreshSubscriptions()
    if let replay = ctx.core.source as? ReplayAX { return replayNext(replay) }

    let deadline = (lastTickAt ?? Date()).addingTimeInterval(interval)
    while true {
      if ctx.stop.isStopped { return nil }
      let fired = await signal.wait(until: deadline)
      if ctx.stop.isStopped { return nil }
      if !fired {
        lastTickAt = Date()
        return Tick(at: lastTickAt!, reason: .timer, notices: drain())
      }
      let changedApps = appsChanged.withLock { v -> Bool in defer { v = false }; return v }
      if changedApps {
        refreshSubscriptions()
        lastTickAt = Date()
        return Tick(at: lastTickAt!, reason: .appsChanged, notices: drain())
      }
      if pending.withLock({ !$0.isEmpty }) {
        if debounce > 0 {
          try? await Task.sleep(nanoseconds: UInt64(debounce * 1e9))
          if ctx.stop.isStopped { return nil }
        }
        lastTickAt = Date()
        return Tick(at: lastTickAt!, reason: .notification, notices: drain())
      }
      // Spurious wake (e.g. stop of a sibling); keep waiting for the same deadline.
      if Date() >= deadline {
        lastTickAt = Date()
        return Tick(at: lastTickAt!, reason: .timer, notices: [])
      }
    }
  }

  private func replayNext(_ replay: ReplayAX) -> Tick? {
    let now = replay.clock.now()
    let timerAt = (lastTickAt ?? now).addingTimeInterval(interval)
    var next = timerAt
    if !notifications.isEmpty,
       let noticeAt = replay.nextNotice(after: now, pids: Set(subscriptions.keys), names: notifications)
    {
      next = Swift.min(next, noticeAt.addingTimeInterval(debounce))
    }
    if let stopAt = ctx.stopAt, next >= stopAt {
      replay.advance(to: stopAt)
      if !finalTickDelivered && now < stopAt {
        finalTickDelivered = true
        lastTickAt = stopAt
        let notices = drain()
        return Tick(at: stopAt, reason: notices.isEmpty ? .timer : .notification, notices: notices)
      }
      ctx.stop.request(ctx.stopAtReason)
      return nil
    }
    if ctx.stopAt == nil, now >= replay.endTime { return nil }
    replay.advance(to: next)
    lastTickAt = next
    let notices = drain()
    return Tick(at: next, reason: notices.isEmpty ? .timer : .notification, notices: notices)
  }

  private func drain() -> [AXNotice] {
    pending.withLock { p -> [AXNotice] in defer { p.removeAll() }; return p }
  }

  /// Subscribe to the declared apps' pids and any child pids seen in snapshots.
  private func refreshSubscriptions() {
    guard !notifications.isEmpty, ctx.ax.isTrusted else { return }
    var pids = Set(ctx.ax.apps().map(\.pid))
    pids.formUnion(ctx.ax.knownPids)
    for pid in subscriptions.keys where !pids.contains(pid) {
      subscriptions.removeValue(forKey: pid)?.cancel()
    }
    for pid in pids where subscriptions[pid] == nil {
      let names = Array(notifications)
      if let sub = try? ctx.core.source.subscribe(pid: pid, notifications: names, handler: { [weak self] notice in
        guard let self else { return }
        self.pending.withLock { p in
          if p.count < 1000 { p.append(notice) }
        }
        self.signal.fire()
      }) {
        subscriptions[pid] = sub
      }
    }
  }

  private func startAppWatch() {
    guard !(ctx.core.source is ReplayAX) else { return }
    let bundles = Set(ctx.manifest.apps)
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      let o = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
        guard let self,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, bundles.contains(id)
        else { return }
        self.appsChanged.withLock { $0 = true }
        self.signal.fire()
      }
      workspaceObservers.append(o)
    }
  }
}

public struct WatchUpdate: Sendable {
  public let at: Date
  /// The located subtree, or nil when it cannot be found.
  public let node: AXNode?
  /// False for idle heartbeats (`idleEvery`) where nothing changed.
  public let changed: Bool
  public let reason: Tick.Reason
  /// Seconds since the content last changed.
  public let unchangedFor: Double
}

/// `for try await update in ctx.watch(...)`: yields only on content change (hash) or presence change,
/// plus idle heartbeats.
public final class Watch: AsyncSequence, AsyncIteratorProtocol, @unchecked Sendable {
  public typealias Element = WatchUpdate

  private let ticks: Ticks
  private let idleEvery: Double?
  private let locate: () throws -> AXNode?
  private var lastHash: String?
  private var lastChangeAt: Date?
  private var lastYieldAt: Date?

  init(ticks: Ticks, idleEvery: Double?, locate: @escaping () throws -> AXNode?) {
    self.ticks = ticks
    self.idleEvery = idleEvery
    self.locate = locate
  }

  public func makeAsyncIterator() -> Watch { self }

  public func next() async throws -> WatchUpdate? {
    while let tick = try await ticks.next() {
      let node: AXNode?
      do { node = try locate() } catch ReflexError.notTrusted { throw ReflexError.notTrusted } catch { node = nil }
      let hash = node?.contentHash ?? "missing"
      if hash != lastHash {
        lastHash = hash
        lastChangeAt = tick.at
        lastYieldAt = tick.at
        return WatchUpdate(at: tick.at, node: node, changed: true, reason: tick.reason, unchangedFor: 0)
      }
      if let idleEvery, tick.at.timeIntervalSince(lastYieldAt ?? tick.at) >= idleEvery {
        lastYieldAt = tick.at
        return WatchUpdate(at: tick.at, node: node, changed: false, reason: tick.reason,
                           unchangedFor: tick.at.timeIntervalSince(lastChangeAt ?? tick.at))
      }
    }
    return nil
  }
}
