import AppKit
import CoreGraphics
import ReflexKit
import ReflexVirtualDisplayBridge

final class NativeBackgroundWindow: BackgroundWindow {
  let ax: LiveAX
  let ref: AXRef
  init(ax: LiveAX, ref: AXRef) { self.ax = ax; self.ref = ref }
  func frame() throws -> CGRect { try ax.windowFrame(ref) }
  func move(to frame: CGRect) throws {
    // The user may have minimized it while parked. Restore before changing geometry.
    if ax.getBool(ref, "AXMinimized") == true { _ = ax.setBool(ref, "AXMinimized", false) }
    try ax.moveWindow(ref, to: frame)
  }
  func activate() {
    let pid = ref.pid
    DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) }
    try? ax.perform(ref, "AXRaise")
  }
}

final class NativeBackgroundEnvironment: BackgroundEnvironment {
  private let ax = LiveAX()
  private var display: VSCGVirtualDisplayHandle?

  func displays() throws -> [Monitor] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
    guard CGGetActiveDisplayList(64, &ids, &count) == .success else { throw BackgroundMeetingError.noDisplays }
    return ids.prefix(Int(count)).map { Monitor(id: $0, frame: CGDisplayBounds($0)) }
  }

  func meetingWindow() throws -> any BackgroundWindow {
    guard ax.isTrusted() else { throw ReflexError.notTrusted }
    var matches: [AXRef] = []
    for app in ax.runningApps(["com.microsoft.teams2", "com.microsoft.teams"]) {
      guard !app.isHidden else { continue }
      for ref in try ax.windows(app).prefix(16) {
        let node = try ax.read(ref, ReadLimits(maxDepth: 0, maxNodes: 1, maxTextLength: 128, timeBudget: 0.4))
        guard node.subrole != "AXSystemDialog", node.minimized != true, node.unlisted != true,
              ax.getBool(ref, "AXFullScreen") != true else { continue }
        let anchors = try ax.find(in: ref, .domId(in: ["hangup-button", "call-duration-custom"]),
                                 FindLimits(maxNodes: 6000, maxMatches: 4, timeBudget: 1))
        let ids = Set(anchors.compactMap(\.domId))
        if ids.contains("hangup-button") && ids.contains("call-duration-custom") { matches.append(ref) }
      }
    }
    guard matches.count == 1, let ref = matches.first else {
      throw matches.isEmpty ? BackgroundMeetingError.noMeetingWindow : BackgroundMeetingError.multipleMeetings
    }
    return NativeBackgroundWindow(ax: ax, ref: ref)
  }

  func createDisplay(at frame: CGRect) throws -> UInt32 {
    guard display == nil, VSCGVirtualDisplayHandle.isAPIAvailable else { throw BackgroundMeetingError.unsupported }
    let mode = VSCGVirtualDisplayModeSpec(width: UInt32(frame.width), height: UInt32(frame.height), refreshRate: 60)
    let handle = try VSCGVirtualDisplayHandle.create(withName: "Reflex Background", vendorID: 0x5246,
      productID: 0x2026, serialNumber: 1029, maxWidth: 1920, maxHeight: 1080, modes: [mode], terminationHandler: {})
    display = handle
    do {
      var transaction: CGDisplayConfigRef?
      guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else {
        throw BackgroundMeetingError.unsafeLayout
      }
      guard CGConfigureDisplayOrigin(transaction, handle.displayID, Int32(frame.minX), Int32(frame.minY)) == .success else {
        CGCancelDisplayConfiguration(transaction)
        throw BackgroundMeetingError.unsafeLayout
      }
      guard CGCompleteDisplayConfiguration(transaction, .forSession) == .success else {
        throw BackgroundMeetingError.unsafeLayout
      }
      return handle.displayID
    } catch { removeDisplay(); throw error }
  }

  func removeDisplay() {
    guard let display else { return }
    let id = display.displayID
    display.invalidate()
    self.display = nil
    let deadline = Date().addingTimeInterval(2)
    while CGDisplayIsOnline(id) != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
  }
  deinit { removeDisplay(); ax.shutdown() }
}
