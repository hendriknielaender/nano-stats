import Darwin
// macos/Sources/Core/Memory/ProcessMemoryMonitor.swift
import Foundation

/// Responsible for monitoring process-specific memory usage.
public final class ProcessMemoryMonitor {
  /// Holds information about a single running process for display.
  public struct ProcessDetails: Comparable, Hashable {
    public let pid: pid_t
    public let name: String
    public let memory_usage_bytes: UInt64
    public let memory_usage_percentage: Double

    public init(
      pid: pid_t, name: String, memory_usage_bytes: UInt64, memory_usage_percentage: Double
    ) {
      self.pid = pid
      self.name = name
      self.memory_usage_bytes = memory_usage_bytes
      self.memory_usage_percentage = memory_usage_percentage
    }

    // Sort by usage descending
    public static func < (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
      return lhs.memory_usage_bytes > rhs.memory_usage_bytes
    }

    public static func == (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
      return lhs.pid == rhs.pid
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(pid)
    }
  }

  private let sysctl_kern_proc_all: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
  private let proc_pid_task_all_info_flavor: Int32 = PROC_PIDTASKALLINFO

  public init() {}

  /// Fetches a list of running processes sorted by resident memory size.
  /// - Parameters:
  ///   - limit: Maximum number of processes to return
  ///   - totalPhysicalMemory: Total physical memory in bytes for percentage calculation
  /// - Returns: Array of ProcessDetails sorted by memory usage (descending)
  public func fetchTopMemoryProcesses(limit: Int, totalPhysicalMemory: UInt64) -> [ProcessDetails] {
    assert(limit > 0 && totalPhysicalMemory > 0)
    var process_details: [ProcessDetails] = []
    var process_dict: [pid_t: ProcessDetails] = [:]

    // Use the original sysctl approach which is more reliable
    var mib = sysctl_kern_proc_all
    var buffer_size: Int = 0

    // First get the buffer size needed
    var sysctl_result = sysctl(&mib, UInt32(mib.count), nil, &buffer_size, nil, 0)
    guard sysctl_result == 0, buffer_size > 0 else { return [] }

    // Allocate buffer for process info
    let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: buffer_size)
    defer { buffer.deallocate() }

    // Get the actual process info
    sysctl_result = sysctl(&mib, UInt32(mib.count), buffer, &buffer_size, nil, 0)
    guard sysctl_result == 0 else { return [] }

    // Calculate how many processes we got
    let process_count = buffer_size / MemoryLayout<kinfo_proc>.size

    // Process each process
    for i in 0..<process_count {
      let info = buffer.advanced(by: i).pointee
      let pid = info.kp_proc.p_pid

      // Skip kernel processes and processes with PID 0
      if pid <= 0 {
        continue
      }

      // Get task info
      var task_info = proc_taskallinfo()
      let task_info_size = MemoryLayout<proc_taskallinfo>.size

      let bytes_copied = proc_pidinfo(
        pid, proc_pid_task_all_info_flavor, 0, &task_info, Int32(task_info_size)
      )

      guard bytes_copied == task_info_size else { continue }

      // Get process name
      var name_buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let path_result = proc_pidpath(pid, &name_buffer, UInt32(name_buffer.count))

      var process_name: String
      if path_result > 0 {
        let path = String(cString: name_buffer)
        process_name = URL(fileURLWithPath: path).lastPathComponent
      } else {
        // Use the name from kinfo_proc as fallback
        process_name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
          let ptr = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
          return String(cString: ptr)
        }

        if process_name.isEmpty {
          process_name = "pid-\(pid)"
        }
      }

      // Calculate memory usage
      let memory_bytes = task_info.ptinfo.pti_resident_size
      let percentage =
        (totalPhysicalMemory > 0)
        ? (Double(memory_bytes) / Double(totalPhysicalMemory)) * 100.0 : 0.0

      // Only add if memory usage is significant
      if memory_bytes > 1024 * 1024 {  // At least 1MB
        let details = ProcessDetails(
          pid: pid,
          name: process_name,
          memory_usage_bytes: memory_bytes,
          memory_usage_percentage: max(0.0, min(100.0, percentage))
        )

        // Use dictionary to ensure unique PIDs
        process_dict[pid] = details
      }
    }

    // Convert dictionary to array and sort
    process_details = Array(process_dict.values)
    process_details.sort()

    // Return top processes
    return Array(process_details.prefix(limit))
  }
}
