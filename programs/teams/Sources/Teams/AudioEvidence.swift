import CoreAudio
import Foundation
import Darwin

/// Presence, absence and an unavailable query are deliberately different observations.
/// No audio samples, device identifiers or speech content are accessed.
struct AudioEvidence: Equatable {
  enum State: String { case running, inactive, unknown, unsupported }
  var state: State
  var processes: [String] = []
  var error: String?
  static let unknown = AudioEvidence(state: .unknown)
}

struct TeamsAudioProbe {
  static func owns(bundle: String?, executable: String?) -> Bool {
    if let bundle, bundle == "com.microsoft.teams2" || bundle.hasPrefix("com.microsoft.teams2.") { return true }
    // A generic Edge/WebView helper name is insufficient: require containment in Teams' app bundle.
    return executable?.contains("/Microsoft Teams.app/Contents/") == true
  }

  func snapshot() -> AudioEvidence {
    guard #available(macOS 14.2, *) else { return AudioEvidence(state: .unsupported) }
    var address = addr(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectHasProperty(system, &address) else { return AudioEvidence(state: .unsupported) }
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
    guard status == noErr else { return AudioEvidence(state: .unknown, error: "enumerate_size:\(status)") }
    guard size > 0 else { return AudioEvidence(state: .inactive) }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let read = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
    guard read == noErr else { return AudioEvidence(state: .unknown, error: "enumerate:\(read)") }
    ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    var matches: [String] = []
    var failures: [String] = []
    for id in ids {
      let pid = uint(id, kAudioProcessPropertyPID)
      var bundleAddress = addr(kAudioProcessPropertyBundleID)
      var bundle: Unmanaged<CFString>?
      var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      let bundleStatus = AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle)
      let name = bundleStatus == noErr ? bundle?.takeRetainedValue() as String? : nil
      var path: String?
      if let pid {
        var bytes = [CChar](repeating: 0, count: 4096 /* PROC_PIDPATHINFO_MAXSIZE in libproc.h */)
        if proc_pidpath(Int32(bitPattern: pid), &bytes, UInt32(bytes.count)) > 0 { path = String(cString: bytes) }
      }
      let running = uint(id, kAudioProcessPropertyIsRunningInput)
      if Self.owns(bundle: name, executable: path) {
        if running == 1 { matches.append("pid:\(pid.map(String.init) ?? "unknown"):object:\(id)") }
        else if running == nil { failures.append("input_query:\(id)") }
      } else if name == nil && path == nil && running != 0 {
        failures.append("ownership_unknown:\(id)")
      }
    }
    if !matches.isEmpty { return AudioEvidence(state: .running, processes: matches.sorted(), error: failures.first) }
    return AudioEvidence(state: failures.isEmpty ? .inactive : .unknown, error: failures.first)
  }

  private func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }
  private func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = addr(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, size == 4 else { return nil }
    return value
  }
}
