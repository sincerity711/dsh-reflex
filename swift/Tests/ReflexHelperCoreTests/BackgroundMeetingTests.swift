import XCTest
import CoreGraphics
import ReflexKit
@testable import ReflexHelperCore

final class BackgroundMeetingTests: XCTestCase {
  final class Window: BackgroundWindow {
    var rect = CGRect(x: 80, y: 80, width: 900, height: 700)
    var gone = false, unreadable = false, rejectRestore = false, refuseMove = false
    var moves = 0, activations = 0
    func frame() throws -> CGRect {
      if gone { throw ReflexError.elementGone }
      if unreadable { throw ReflexError.axFailure("unreadable") }
      return rect
    }
    func move(to: CGRect) throws {
      if refuseMove || (rejectRestore && to.minY >= 0) { throw BackgroundMeetingError.moveFailed }
      moves += 1; rect = to
    }
    func activate() { activations += 1 }
  }
  final class Environment: BackgroundEnvironment {
    let window = Window()
    var monitors = [Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))]
    var creates = 0, removes = 0
    var badLayout = false
    var atRemoval: CGRect?
    func displays() throws -> [Monitor] { monitors }
    func meetingWindow() throws -> any BackgroundWindow { window }
    func createDisplay(at frame: CGRect) throws -> UInt32 {
      creates += 1
      monitors.append(Monitor(id: 9, frame: badLayout ? frame.offsetBy(dx: 20, dy: 0) : frame))
      return 9
    }
    func removeDisplay() {
      if monitors.contains(where: { $0.id == 9 }) { removes += 1; atRemoval = window.rect }
      monitors.removeAll { $0.id == 9 }
    }
  }

  func testTopLeftPlacementHasOnePixelContactAndNoOverlap() throws {
    let layouts: [[Monitor]] = [
      [Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))],
      [Monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169)),
       Monitor(id: 2, frame: CGRect(x: -1640, y: -1440, width: 3440, height: 1440)),
       Monitor(id: 3, frame: CGRect(x: 1800, y: -1440, width: 3440, height: 1440))],
      [Monitor(id: 1, frame: CGRect(x: -4000, y: 0, width: 2000, height: 1000)),
       Monitor(id: 2, frame: CGRect(x: -2000, y: -1000, width: 2000, height: 2000))],
    ]
    for layout in layouts {
      let frame = try CornerPlacement.frame(for: layout)
      XCTAssertEqual(frame.maxY, layout.map(\.frame.minY).min())
      XCTAssertTrue(layout.allSatisfy { CornerPlacement.area($0.frame.intersection(frame)) == 0 })
      let anchor = layout.filter { $0.frame.minY == frame.maxY }.min { $0.frame.minX < $1.frame.minX }!
      XCTAssertEqual(frame.maxX - anchor.frame.minX, 1)
      XCTAssertTrue(CornerPlacement.isSafe(frame.offsetBy(dx: -1, dy: 0), requested: frame, physical: layout))
      XCTAssertFalse(CornerPlacement.isSafe(frame.offsetBy(dx: 10, dy: 0), requested: frame, physical: layout))
      XCTAssertEqual(try CornerPlacement.frame(for: layout.reversed()), frame)
    }
    XCTAssertThrowsError(try CornerPlacement.frame(for: []))
  }

  func testBringBackRestoresBeforeDeletingAndDuplicateActionsAreSafe() throws {
    let env = Environment(), original = Environment().window.rect
    let manager = BackgroundMeeting(environment: env)
    try manager.park(correlation: "one")
    XCTAssertTrue(manager.isActive)
    XCTAssertEqual(env.creates, 1)
    try manager.park(correlation: "one")
    XCTAssertEqual(env.creates, 1)
    XCTAssertThrowsError(try manager.park(correlation: "two"))
    try manager.bringBack()
    XCTAssertEqual(env.atRemoval, original)
    XCTAssertEqual(env.window.activations, 1)
    XCTAssertFalse(manager.isActive)
    try manager.bringBack()
    XCTAssertEqual(env.removes, 1)
  }

  func testRestoreFailureRetainsDisplayUntilRetry() throws {
    let env = Environment()
    let tested = BackgroundMeeting(environment: env)
    try tested.park(correlation: "one")
    env.window.rejectRestore = true
    XCTAssertThrowsError(try tested.bringBack())
    XCTAssertTrue(tested.isActive)
    XCTAssertEqual(env.removes, 0)
    env.window.rejectRestore = false
    try tested.bringBack()
    XCTAssertFalse(tested.isActive)
    XCTAssertEqual(env.removes, 1)
  }

  func testWindowMovedOutOrClosedReleasesDisplay() throws {
    for closed in [false, true] {
      let env = Environment(), original = Environment().window.rect
      let manager = BackgroundMeeting(environment: env)
      try manager.park(correlation: "one")
      if closed { env.window.gone = true } else { env.window.rect = original }
      manager.reconcile(currentCorrelation: "one")
      XCTAssertFalse(manager.isActive)
      XCTAssertEqual(env.removes, 1)
    }
  }

  func testUnknownAXStateDoesNotDestroyDisplay() throws {
    let env = Environment(), manager: BackgroundMeeting
    manager = BackgroundMeeting(environment: env)
    try manager.park(correlation: "one")
    env.window.unreadable = true
    manager.reconcile(currentCorrelation: nil)
    XCTAssertTrue(manager.isActive)
    XCTAssertEqual(env.removes, 0)
  }

  func testUnexpectedPlacementRollsBackWithoutMovingTeamsOffscreen() {
    let env = Environment(), original = Environment().window.rect
    env.badLayout = true
    let manager = BackgroundMeeting(environment: env)
    XCTAssertThrowsError(try manager.park(correlation: "one"))
    XCTAssertFalse(manager.isActive)
    XCTAssertEqual(env.atRemoval, original)
  }

  func testRejectedInitialMoveReleasesUnusedDisplay() {
    let env = Environment()
    env.window.refuseMove = true
    let manager = BackgroundMeeting(environment: env)
    XCTAssertThrowsError(try manager.park(correlation: "one"))
    XCTAssertFalse(manager.isActive)
    XCTAssertEqual(env.removes, 1)
  }

  func testTopologyChangeAndMeetingEndRestoreWindow() throws {
    for transition in ["topology", "ended", "replaced", "shutdown"] {
      let env = Environment(), manager: BackgroundMeeting
      manager = BackgroundMeeting(environment: env)
      try manager.park(correlation: "one")
      switch transition {
      case "topology":
        env.monitors[0] = Monitor(id: 3, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        manager.reconcile(currentCorrelation: "one")
      case "ended": manager.reconcile(currentCorrelation: nil, meetingEnded: true)
      case "replaced": manager.reconcile(currentCorrelation: "two")
      default: manager.shutdown()
      }
      XCTAssertFalse(manager.isActive, transition)
      XCTAssertTrue(env.monitors[0].frame.contains(env.window.rect), transition)
      XCTAssertEqual(env.window.activations, 0)
    }
  }

  func testActualCornerDisplayWhenOptedIn() throws {
    guard ProcessInfo.processInfo.environment["REFLEX_DISPLAY_INTEGRATION"] == "1" else {
      throw XCTSkip("Opt in to creating a temporary display with REFLEX_DISPLAY_INTEGRATION=1")
    }
    let env = NativeBackgroundEnvironment()
    let before = try env.displays()
    let frame = try CornerPlacement.frame(for: before)
    let id = try env.createDisplay(at: frame)
    defer { env.removeDisplay() }
    let after = try env.displays()
    let actual = try XCTUnwrap(after.first { $0.id == id }?.frame)
    print("virtual-display requested=\(frame) actual=\(actual) physical=\(before)")
    XCTAssertTrue(CornerPlacement.isSafe(actual, requested: frame, physical: before))
    XCTAssertTrue(CornerPlacement.sameLayout(before, after.filter { $0.id != id }))
    env.removeDisplay()
    XCTAssertTrue(CornerPlacement.sameLayout(before, try env.displays()))
  }
}
