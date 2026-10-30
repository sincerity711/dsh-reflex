import Darwin
import Foundation

/// Resident memory and CPU of a process (from proc_pid_rusage).
public struct ProcSample: Sendable {
  public var rssBytes: UInt64
  public var footprintBytes: UInt64
  public var cpuNanos: UInt64
  public var at: Date
}

public enum ProcStats {
  public static func sample(pid: Int32) -> ProcSample? {
    var info = rusage_info_v2()
    let r = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard r == 0 else { return nil }
    // ri_user_time/ri_system_time are in mach absolute time units.
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let ticks = info.ri_user_time + info.ri_system_time
    let nanos = ticks * UInt64(tb.numer) / UInt64(max(1, tb.denom))
    return ProcSample(rssBytes: info.ri_resident_size, footprintBytes: info.ri_phys_footprint, cpuNanos: nanos, at: Date())
  }
}

/// CPU percentage between consecutive samples.
public final class CPUMeter: @unchecked Sendable {
  private var last: ProcSample?
  public private(set) var percent: Double = 0
  public private(set) var latest: ProcSample?

  public init() {}

  public func update(pid: Int32) {
    guard let s = ProcStats.sample(pid: pid) else { return }
    if let last, s.at > last.at, s.cpuNanos >= last.cpuNanos {
      let wall = s.at.timeIntervalSince(last.at) * 1e9
      percent = wall > 0 ? Double(s.cpuNanos - last.cpuNanos) / wall * 100 : 0
    }
    last = s
    latest = s
  }

  public func reset() {
    last = nil
    latest = nil
    percent = 0
  }
}
