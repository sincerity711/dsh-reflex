import Foundation
import CoreGraphics
import ReflexKit

struct Monitor: Equatable {
  let id: UInt32
  let frame: CGRect
}

enum BackgroundMeetingError: String, Error {
  case noDisplays, unsafeLayout, noMeetingWindow, multipleMeetings, windowNotReady
  case moveFailed, restoreFailed, staleMeeting, unsupported
}

/// Quartz coordinates: y increases downwards. Attach to the left end of the topmost edge,
/// with one pixel of horizontal contact. A detached bounding-box corner is not a valid layout.
enum CornerPlacement {
  static func frame(for displays: [Monitor], size: CGSize = CGSize(width: 1920, height: 1080)) throws -> CGRect {
    guard let anchor = displays.sorted(by: {
      $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
    }).first, size.width > 1, size.height > 1 else { throw BackgroundMeetingError.noDisplays }
    return CGRect(x: anchor.frame.minX - size.width + 1, y: anchor.frame.minY - size.height,
                  width: size.width, height: size.height)
  }

  static func restore(_ original: CGRect, displays: [Monitor]) throws -> CGRect {
    guard !displays.isEmpty else { throw BackgroundMeetingError.noDisplays }
    if displays.contains(where: { $0.frame.contains(original) }) { return original }
    let target = displays.max { a, b in
      area(a.frame.intersection(original)) < area(b.frame.intersection(original))
    }!.frame
    let size = CGSize(width: min(original.width, target.width), height: min(original.height, target.height))
    return CGRect(x: min(max(original.minX, target.minX), target.maxX - size.width),
                  y: min(max(original.minY, target.minY), target.maxY - size.height),
                  width: size.width, height: size.height)
  }

  static func area(_ frame: CGRect) -> CGFloat { frame.isNull ? 0 : max(0, frame.width) * max(0, frame.height) }
  static func isSafe(_ actual: CGRect, requested: CGRect, physical: [Monitor]) -> Bool {
    // macOS may snap a one-pixel edge contact to a corner contact (observed on 27.2).
    actual.size == requested.size && abs(actual.minX - requested.minX) <= 1 &&
    abs(actual.minY - requested.minY) <= 1 &&
    physical.allSatisfy { area(actual.intersection($0.frame)) == 0 }
  }
  static func sameLayout(_ a: [Monitor], _ b: [Monitor]) -> Bool {
    a.sorted { $0.id < $1.id } == b.sorted { $0.id < $1.id }
  }
}

protocol BackgroundWindow: AnyObject {
  func frame() throws -> CGRect
  func move(to: CGRect) throws
  func activate()
}

protocol BackgroundEnvironment: AnyObject {
  func displays() throws -> [Monitor]
  func meetingWindow() throws -> any BackgroundWindow
  func createDisplay(at: CGRect) throws -> UInt32
  func removeDisplay()
}

/// All calls run on the helper's serial queue. Owns one virtual display and one exact AX window
/// handle. No title matching, meeting events, recording, screen capture, or input interception.
final class BackgroundMeeting {
  struct Session {
    let correlation: String
    let window: any BackgroundWindow
    let original: CGRect
    let originalDisplays: [Monitor]
    let displayID: UInt32
  }
  private let environment: any BackgroundEnvironment
  private(set) var session: Session?
  private(set) var error: String?
  var log: (String) -> Void = { _ in }
  var isActive: Bool { session != nil }

  init(environment: any BackgroundEnvironment) { self.environment = environment }

  var snapshot: JSON {
    ["active": JSON(isActive), "correlationId": session.map { .string($0.correlation) } ?? .null,
     "error": error.map(JSON.string) ?? .null]
  }

  func park(correlation: String) throws {
    if let session {
      guard session.correlation == correlation else { throw BackgroundMeetingError.staleMeeting }
      return
    }
    error = nil
    let window = try environment.meetingWindow()
    let original = try window.frame()
    let displays = try environment.displays()
    let target = try CornerPlacement.frame(for: displays)
    let id = try environment.createDisplay(at: target)
    // Keep ownership before touching Teams: even a partial AX move must be recoverable.
    session = Session(correlation: correlation, window: window, original: original,
                      originalDisplays: displays, displayID: id)
    do {
      let after = try environment.displays()
      guard CornerPlacement.sameLayout(displays, after.filter { $0.id != id }),
            let actualDisplay = after.first(where: { $0.id == id })?.frame,
            CornerPlacement.isSafe(actualDisplay, requested: target, physical: displays) else {
        throw BackgroundMeetingError.unsafeLayout
      }
      let destination = actualDisplay.insetBy(dx: 24, dy: 24)
      try window.move(to: destination)
      guard actualDisplay.contains(try window.frame()) else { throw BackgroundMeetingError.moveFailed }
      log("background entered display=\(id) x=\(actualDisplay.minX) y=\(actualDisplay.minY) cornerContact<=2px")
    } catch {
      let originalError = error
      // Bring back before releasing a display which may already contain the window.
      do { try bringBack(activate: false) }
      catch { self.error = BackgroundMeetingError.restoreFailed.rawValue }
      if self.error == nil { self.error = code(originalError) }
      throw originalError
    }
  }

  func bringBack(activate: Bool = true) throws {
    guard let session else { error = nil; return }
    error = nil
    do {
      let displays = try environment.displays().filter { $0.id != session.displayID }
      let target = try CornerPlacement.restore(session.original, displays: displays)
      do {
        _ = try session.window.frame()
      } catch ReflexError.elementGone {
        finish(reason: "window_closed")
        return
      }
      if try session.window.frame() != target { try session.window.move(to: target) }
      let actual = try session.window.frame()
      guard displays.contains(where: { $0.frame.contains(actual) }) else {
        throw BackgroundMeetingError.restoreFailed
      }
      if activate { session.window.activate() }
      finish(reason: "brought_back")
    } catch {
      self.error = code(error)
      log("background restore failed reason=\(code(error)); display retained")
      throw error
    }
  }

  /// Handles manual drag-out, unplug/wake, closed windows and meeting transitions.
  /// An unreadable AX tree is not proof that the window or meeting ended.
  func reconcile(currentCorrelation: String?, meetingEnded: Bool = false) {
    guard let session else { return }
    do {
      let displays = try environment.displays()
      let physical = displays.filter { $0.id != session.displayID }
      let frame = try session.window.frame()
      if physical.contains(where: { $0.frame.contains(frame) }) {
        finish(reason: "window_moved_out")
      } else if meetingEnded || (currentCorrelation != nil && currentCorrelation != session.correlation)
                  || !CornerPlacement.sameLayout(physical, session.originalDisplays)
                  || !displays.contains(where: { $0.id == session.displayID }) {
        try bringBack(activate: false)
      }
    } catch ReflexError.elementGone {
      finish(reason: "window_closed")
    } catch {
      self.error = code(error)
    }
  }

  func shutdown() {
    try? bringBack(activate: false)
    // Process termination releases CGVirtualDisplay even if Teams stopped answering AX.
    // macOS then moves its windows to remaining screens; never persist a headless display.
    if session != nil { log("background shutdown: AX restore unavailable; releasing display") }
    environment.removeDisplay()
    session = nil
  }

  private func finish(reason: String) {
    environment.removeDisplay()
    session = nil
    error = nil
    log("background released reason=\(reason)")
  }
  private func code(_ error: Error) -> String {
    (error as? BackgroundMeetingError)?.rawValue ?? "window_unavailable"
  }
}
