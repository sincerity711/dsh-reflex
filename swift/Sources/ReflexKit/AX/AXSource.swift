import Foundation

public struct AppInfo: Codable, Hashable, Sendable {
  public var pid: Int32
  public var bundleId: String
  public var name: String
  public var isActive: Bool
  public var isHidden: Bool

  public init(pid: Int32, bundleId: String, name: String, isActive: Bool = false, isHidden: Bool = false) {
    self.pid = pid
    self.bundleId = bundleId
    self.name = name
    self.isActive = isActive
    self.isHidden = isHidden
  }
}

/// Bounds for reading a subtree.
public struct ReadLimits: Hashable, Sendable, Codable {
  public var maxDepth: Int
  public var maxNodes: Int
  public var maxTextLength: Int
  /// Wall-clock budget for one read.
  public var timeBudget: Double
  public var includeFrames: Bool
  /// Prioritize the newest end of growing lists, while returning children in document order.
  /// Optional for compatibility with saved fixture limits from earlier versions.
  public var tailFirst: Bool?

  public init(maxDepth: Int = 24, maxNodes: Int = 2000, maxTextLength: Int = 400, timeBudget: Double = 2.0, includeFrames: Bool = false, tailFirst: Bool? = nil) {
    self.maxDepth = maxDepth
    self.maxNodes = maxNodes
    self.maxTextLength = maxTextLength
    self.timeBudget = timeBudget
    self.includeFrames = includeFrames
    self.tailFirst = tailFirst
  }

  /// For a small target subtree such as a caption list.
  public static let small = ReadLimits(maxDepth: 8, maxNodes: 200, maxTextLength: 2000, timeBudget: 0.5)
  /// For dev inspection of a whole app.
  public static let inspect = ReadLimits(maxDepth: 40, maxNodes: 8000, maxTextLength: 200, timeBudget: 10, includeFrames: false)
}

/// Bounds for searching.
public struct FindLimits: Hashable, Sendable {
  public var maxDepth: Int
  public var maxNodes: Int
  public var maxMatches: Int
  public var timeBudget: Double

  public init(maxDepth: Int = 40, maxNodes: Int = 6000, maxMatches: Int = 1, timeBudget: Double = 1.5) {
    self.maxDepth = maxDepth
    self.maxNodes = maxNodes
    self.maxMatches = maxMatches
    self.timeBudget = timeBudget
  }

  public static let first = FindLimits()
  public static func all(_ max: Int = 200) -> FindLimits { FindLimits(maxMatches: max) }
}

/// One AX notification as delivered to a subscriber.
public struct AXNotice: Sendable, Hashable {
  public var name: String
  public var pid: Int32
  public var at: Date
  /// Light description of the element that changed (role/domId/chromeId), filled by recorders/replay.
  public var element: AXNode?
  /// Handle of the element that changed (live: retained AXUIElement).
  public var ref: AXRef?

  public init(name: String, pid: Int32, at: Date, element: AXNode? = nil, ref: AXRef? = nil) {
    self.name = name
    self.pid = pid
    self.at = at
    self.element = element
    self.ref = ref
  }
}

public final class AXSubscription: @unchecked Sendable {
  private let cancelBlock: () -> Void
  private let cancelled = Locked(false)

  init(_ cancel: @escaping () -> Void) { self.cancelBlock = cancel }

  public func cancel() {
    let first = cancelled.withLock { (done: inout Bool) -> Bool in
      if done { return false }
      done = true
      return true
    }
    if first { cancelBlock() }
  }

  deinit { cancel() }
}

public struct AXStats: Sendable, Codable, Hashable {
  public var calls: Int = 0
  public var millis: Double = 0
  public var errors: Int = 0

  public init() {}
}

public enum AXResult: String, Sendable, Codable {
  case success
  case failure
  case unsupported
  case notPermitted
}

public enum ReflexError: Error, CustomStringConvertible {
  case notTrusted
  case appNotDeclared(String)
  case capabilityMissing(Capability)
  case actionNotGranted(String)
  case eventNotDeclared(String)
  case unknownTask(String)
  case pathOutsideAllowedDirs(String)
  case axFailure(String)
  case elementGone
  case invalidInput(String)

  public var description: String {
    switch self {
    case .notTrusted: return "accessibility permission is not granted"
    case .appNotDeclared(let b): return "app \(b) is not declared in the manifest"
    case .capabilityMissing(let c): return "capability .\(c.rawValue) is not declared in the manifest"
    case .actionNotGranted(let a): return "action \(a) is not declared in the manifest or not confirmed by the user"
    case .eventNotDeclared(let e): return "event type \(e) is not declared in manifest.emits"
    case .unknownTask(let t): return "unknown task \(t)"
    case .pathOutsideAllowedDirs(let p): return "path \(p) is outside the program's data/task directory"
    case .axFailure(let m): return "AX failure: \(m)"
    case .elementGone: return "element no longer exists"
    case .invalidInput(let m): return "invalid input: \(m)"
    }
  }
}

/// The AX backend: live (real AX API) or replay (recorded fixture).
public protocol AXSource: AnyObject, Sendable {
  var clock: ReflexClock { get }
  func isTrusted() -> Bool
  func runningApps(_ bundleIds: Set<String>) -> [AppInfo]
  func appRef(_ app: AppInfo) -> AXRef
  /// The app's windows: its AXWindows list first, then windows that list leaves out (on a Space that is
  /// not on screen), which read with `unlisted: true`.
  func windows(_ app: AppInfo) throws -> [AXRef]
  /// Read a bounded subtree snapshot (every node carries its `ref`).
  func read(_ ref: AXRef, _ limits: ReadLimits) throws -> AXNode
  /// Depth-first search with early exit; returns shallow nodes (no children) with refs.
  func find(in ref: AXRef, _ query: AXQuery, _ limits: FindLimits) throws -> [AXNode]
  /// The parent element (nil at the top).
  func parent(of ref: AXRef) throws -> AXRef?
  /// Subscribe to notifications of one process (application-wide).
  func subscribe(pid: Int32, notifications: [String], handler: @escaping @Sendable (AXNotice) -> Void) throws -> AXSubscription
  func getBool(_ ref: AXRef, _ attribute: String) -> Bool?
  @discardableResult func setBool(_ ref: AXRef, _ attribute: String, _ value: Bool) -> AXResult
  func perform(_ ref: AXRef, _ action: String) throws
  func stats() -> AXStats
  /// Release observers and restore modified attributes.
  func shutdown()
}

extension AXSource {
  /// Read every window of an app (bounded) as children of a synthetic application node.
  public func readApp(_ app: AppInfo, _ limits: ReadLimits) throws -> AXNode {
    var root = AXNode(role: "AXApplication", title: app.name, pid: app.pid, ref: appRef(app))
    var budget = limits
    for w in try windows(app) {
      guard budget.maxNodes > 0 else { root.omittedChildren = (root.omittedChildren ?? 0) + 1; continue }
      let node = try read(w, budget)
      budget.maxNodes -= node.nodeCount
      root.children.append(node)
    }
    return root
  }

  /// Window snapshots (shallow: title, subrole, minimized) for cheap detection.
  public func windowList(_ app: AppInfo) throws -> [AXNode] {
    try windows(app).map { try read($0, ReadLimits(maxDepth: 0, maxNodes: 1, maxTextLength: 300, timeBudget: 0.5)) }
  }
}
