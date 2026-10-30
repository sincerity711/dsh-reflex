import AppKit
import Foundation

public struct RecordOptions: Sendable {
  public var bundleIds: [String]
  public var duration: Double
  /// Minimum spacing of tree snapshots; notifications trigger earlier re-reads (debounced).
  public var interval: Double
  public var limits: ReadLimits
  public var redaction: RedactionMode
  public var notifications: [String]
  public var note: String?
  /// When non-empty, frames keep only these subtrees (plus ancestors and shallow windows),
  /// and a full keyframe is written every `keyframeEvery` seconds.
  public var keep: [AXQuery]
  public var keyframeEvery: Double
  /// Words kept verbatim by the redactor (scripted speech in probes).
  public var keepWords: [String] = []

  public init(bundleIds: [String], duration: Double, interval: Double = 0.5, limits: ReadLimits = ReadLimits(maxDepth: 40, maxNodes: 6000, maxTextLength: 400, timeBudget: 4),
              redaction: RedactionMode = .pseudo, notifications: [String] = AXNotification.recorderSet, note: String? = nil,
              keep: [AXQuery] = [], keyframeEvery: Double = 15)
  {
    self.bundleIds = bundleIds
    self.duration = duration
    self.interval = interval
    self.limits = limits
    self.redaction = redaction
    self.notifications = notifications
    self.note = note
    self.keep = keep
    self.keyframeEvery = keyframeEvery
  }
}

public struct RecordSummary: Codable, Sendable {
  public var path: String
  public var durationSec: Double
  public var frames: Int
  public var notices: Int
  /// pid -> notification name -> count
  public var noticeCounts: [String: [String: Int]]
  /// pid -> how many tree frames contained nodes owned by it
  public var pids: [String]
  public var maxNodes: Int
  public var avgReadMs: Double
  public var trusted: Bool
  public var markers: [String]
}

/// Records snapshots and notifications of declared apps into a fixture (dev tool `ax record`).
public final class AXRecorder: @unchecked Sendable {
  private let source: AXSource
  private let options: RecordOptions
  private let out: LineAppender
  private let redactor: Redactor
  private let signal = WakeSignal()
  private let pending = Locked([AXNotice]())
  private let markers = Locked([(Date, String)]())
  private let stopped = Locked(false)
  private var subscriptions: [Int32: AXSubscription] = [:]
  private var start = Date()

  public init(source: AXSource, options: RecordOptions, out: URL) {
    self.source = source
    self.options = options
    self.out = LineAppender(url: out)
    self.redactor = Redactor(mode: options.redaction, keep: Set(options.keepWords))
  }

  public func mark(_ label: String) {
    markers.withLock { $0.append((Date(), label)) }
    signal.fire()
  }

  public func stop() {
    stopped.withLock { $0 = true }
    signal.fire()
  }

  public func run() async throws -> RecordSummary {
    start = Date()
    var versions: [String: String] = [:]
    for id in options.bundleIds {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), let b = Bundle(url: url) {
        versions[id] = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
      }
    }
    let meta = FixtureMeta(bundleIds: options.bundleIds, startedAt: start, redaction: options.redaction,
                           limits: options.limits, tool: "ax record", note: options.note, appVersions: versions)
    try out.append(try FixtureLine.meta(meta).line())

    var lastHash: [Int32: String] = [:]
    var lastApps: [AppInfo] = []
    var frames = 0
    var noticesWritten = 0
    var counts: [String: [String: Int]] = [:]
    var pidsSeen = Set<Int32>()
    var maxNodes = 0
    var readMs: [Double] = []
    var markerLabels: [String] = []
    var lastKeyframe: [Int32: Date] = [:]
    let deadline = start.addingTimeInterval(options.duration)
    var nextRead = start

    while Date() < deadline, !stopped.current {
      _ = await signal.wait(until: min(deadline, nextRead))
      let now = Date()
      let t = { (d: Date) in (d.timeIntervalSince(self.start) * 1000).rounded() / 1000 }

      for (at, label) in markers.withLock({ m -> [(Date, String)] in defer { m.removeAll() }; return m }) {
        try out.append(try FixtureLine.marker(t: t(at), label: label).line())
        markerLabels.append(label)
      }

      let notices = pending.withLock { p -> [AXNotice] in defer { p.removeAll() }; return p }
      for (i, n) in notices.enumerated() {
        counts[String(n.pid), default: [:]][n.name, default: 0] += 1
        var element: AXNode?
        if i < 40, let ref = n.ref, let node = try? source.read(ref, ReadLimits(maxDepth: 0, maxNodes: 1, maxTextLength: 80, timeBudget: 0.2)) {
          element = redactor.apply(node)
        }
        try out.append(try FixtureLine.notice(t: t(n.at), pid: n.pid, name: n.name, element: element).line())
        noticesWritten += 1
      }

      guard now >= nextRead || !notices.isEmpty else { continue }
      if !notices.isEmpty && now < nextRead {
        // Debounce bursts: re-read at most every interval/2 after a notification.
        try? await Task.sleep(nanoseconds: UInt64(options.interval / 2 * 1e9))
      }
      nextRead = Date().addingTimeInterval(options.interval)

      let apps = source.runningApps(Set(options.bundleIds))
      if apps != lastApps {
        try out.append(try FixtureLine.apps(t: t(Date()), apps: apps).line())
        lastApps = apps
      }
      for app in apps {
        let readStart = Date()
        guard let root = try? source.readApp(app, options.limits) else { continue }
        readMs.append(Date().timeIntervalSince(readStart) * 1000)
        var pids: Set<Int32> = [app.pid]
        for n in root.descendants { if let p = n.pid { pids.insert(p) } }
        pidsSeen.formUnion(pids)
        subscribe(pids)
        maxNodes = max(maxNodes, root.nodeCount)
        var frame = root
        let keyframeDue = Date().timeIntervalSince(lastKeyframe[app.pid] ?? .distantPast) >= options.keyframeEvery
        if !options.keep.isEmpty && !keyframeDue {
          frame = root.pruned(keep: options.keep) ?? AXNode(role: "AXApplication", title: root.title, pid: root.pid)
        } else {
          lastKeyframe[app.pid] = Date()
        }
        let redacted = redactor.apply(frame)
        let hash = redacted.contentHash
        if lastHash[app.pid] != hash || (keyframeDue && !options.keep.isEmpty) {
          lastHash[app.pid] = hash
          try out.append(try FixtureLine.tree(t: t(readStart), pid: app.pid, root: redacted).line())
          frames += 1
        }
      }
    }
    for s in subscriptions.values { s.cancel() }
    subscriptions.removeAll()
    out.sync()
    out.close()
    return RecordSummary(
      path: out.url.path, durationSec: Date().timeIntervalSince(start), frames: frames, notices: noticesWritten,
      noticeCounts: counts, pids: pidsSeen.sorted().map(String.init), maxNodes: maxNodes,
      avgReadMs: readMs.isEmpty ? 0 : readMs.reduce(0, +) / Double(readMs.count), trusted: source.isTrusted(),
      markers: markerLabels)
  }

  private func subscribe(_ pids: Set<Int32>) {
    for pid in pids where subscriptions[pid] == nil {
      if let sub = try? source.subscribe(pid: pid, notifications: options.notifications, handler: { [weak self] n in
        guard let self else { return }
        self.pending.withLock { if $0.count < 5000 { $0.append(n) } }
        self.signal.fire()
      }) {
        subscriptions[pid] = sub
      }
    }
  }
}

/// Inspect helper: bounded, redacted snapshot of all windows of the running instances of an app.
public enum AXInspector {
  public static func inspect(source: AXSource, bundleId: String, limits: ReadLimits = .inspect, redaction: RedactionMode = .ui) throws -> [AXNode] {
    let redactor = Redactor(mode: redaction)
    return try source.runningApps([bundleId]).map { app in
      redactor.apply(try source.readApp(app, limits))
    }
  }
}
