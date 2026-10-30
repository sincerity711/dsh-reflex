import AppKit
import ApplicationServices

extension LiveAX {
  /// Geometry only: never reads or stores the window's text.
  public func windowFrame(_ ref: AXRef) throws -> CGRect {
    guard let element = ref.element else { throw ReflexError.elementGone }
    var p: CFTypeRef?, s: CFTypeRef?
    let pe = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p)
    let se = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
    if pe == .invalidUIElement || se == .invalidUIElement { throw ReflexError.elementGone }
    guard pe == .success, se == .success, let p, let s,
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else {
      throw ReflexError.axFailure("window geometry unavailable")
    }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else {
      throw ReflexError.axFailure("invalid window geometry")
    }
    return CGRect(origin: point, size: size)
  }

  public func moveWindow(_ ref: AXRef, to frame: CGRect) throws {
    guard let element = ref.element else { throw ReflexError.elementGone }
    var point = frame.origin, size = frame.size
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
      throw ReflexError.axFailure("invalid window frame")
    }
    // Set position again after resizing; Teams may clamp the first move to its old display.
    let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
    let last = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    guard (first == .success || last == .success), resize == .success, last == .success else {
      throw ReflexError.axFailure("window move rejected")
    }
  }
}
