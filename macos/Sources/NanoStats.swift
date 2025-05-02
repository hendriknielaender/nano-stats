import AppKit
import Darwin
import Foundation

// MARK: - Constants and Type Aliases

private typealias MachFlavor = Int32
private typealias MachMsgTypeNumber = mach_msg_type_number_t
private let host_vm_info64_flavor: MachFlavor = HOST_VM_INFO64
private let host_vm_info64_count: MachMsgTypeNumber =
  MachMsgTypeNumber(
    MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
  )
private let sysctl_kern_proc_all: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
private let proc_pid_task_all_info_flavor: Int32 = PROC_PIDTASKALLINFO

// MARK: - Data Structures

/// Holds information about a single running process for display.
private struct ProcessDetails: Comparable, Hashable {
  let pid: pid_t
  let name: String
  let memory_usage_bytes: UInt64
  let memory_usage_percentage: Double

  // Sort by usage descending
  static func < (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
    return lhs.memory_usage_bytes > rhs.memory_usage_bytes
  }

  static func == (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
    return lhs.pid == rhs.pid
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(pid)
  }
}

/// Holds the system-wide memory breakdown calculated from vm_statistics64.
private struct SystemMemoryBreakdown {
  let total_bytes: UInt64
  let active_bytes: UInt64
  let wired_bytes: UInt64
  let inactive_bytes: UInt64
  let compressed_bytes: UInt64
  let free_bytes: UInt64
  let used_bytes: UInt64
  let usage_percentage: Double
}

// MARK: - Custom Status Item View

private class MemoryStatusView: NSView {
  private let ram_label = NSTextField()
  private let percentage_label = NSTextField()

  override init(frame: NSRect) {
    super.init(frame: frame)

    ram_label.isEditable = false
    ram_label.isBordered = false
    ram_label.isSelectable = false
    ram_label.drawsBackground = false
    ram_label.font = NSFont.systemFont(ofSize: 8)
    ram_label.alignment = .left
    ram_label.stringValue = "RAM"

    percentage_label.isEditable = false
    percentage_label.isBordered = false
    percentage_label.isSelectable = false
    percentage_label.drawsBackground = false
    percentage_label.font = NSFont.systemFont(ofSize: 12)
    percentage_label.alignment = .left
    percentage_label.stringValue = "0.0%"

    addSubview(ram_label)
    addSubview(percentage_label)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()

    let bounds = self.bounds
    ram_label.frame = NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10)
    percentage_label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 10)
  }

  func updatePercentage(_ percentage: Double) {
    percentage_label.stringValue = String(format: "%d%%", Int(round(percentage)))
  }
}

// MARK: - Main Application Class

@objc public final class NanoStatsApp: NSObject, NSMenuDelegate {
  // MARK: Properties
  private let status_bar: NSStatusBar
  private let status_item: NSStatusItem
  private let app: NSApplication
  private var memory_update_timer: Timer?
  private let process_menu: NSMenu
  private var total_physical_memory_bytes: UInt64 = 0
  private var status_view: MemoryStatusView?

  // Configuration
  private let memory_update_interval_seconds: TimeInterval = 2.0
  private let top_process_count: Int = 10
  private let status_item_width: CGFloat = 35.0

  // MARK: Initialization
  @objc public init(withTitle title: String) {
    assert(Thread.isMainThread, "NanoStatsApp must be initialized on the main thread.")
    self.app = NSApplication.shared
    self.status_bar = NSStatusBar.system
    self.status_item = self.status_bar.statusItem(withLength: status_item_width)
    self.process_menu = NSMenu()
    super.init()

    self.total_physical_memory_bytes = Self.fetch_total_physical_memory_bytes()
    assert(self.total_physical_memory_bytes > 0, "Failed to fetch total physical memory at init.")

    if let button = self.status_item.button {
      // Create a custom view for the status item
      let custom_view = MemoryStatusView(
        frame: NSRect(x: 0, y: 0, width: status_item_width, height: 22))
      self.status_view = custom_view

      // Set the custom view as the status item's view
      button.subviews.forEach { $0.removeFromSuperview() }
      button.addSubview(custom_view)

      // Make the custom view resize with the button
      custom_view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        custom_view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
        custom_view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        custom_view.topAnchor.constraint(equalTo: button.topAnchor),
        custom_view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
      ])

      self.status_item.menu = self.process_menu
    } else {
      assertionFailure("Failed to get status item button.")
    }

    self.process_menu.delegate = self

    if Foundation.ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
      self.app.setActivationPolicy(.accessory)
    }

    self.update_memory_display()
  }

  // MARK: Public API
  @objc public func run() {
    assert(Thread.isMainThread, "run() must be called on the main thread.")
    self.memory_update_timer = Timer.scheduledTimer(
      withTimeInterval: memory_update_interval_seconds,
      repeats: true
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let strongSelf = self else { return }
        strongSelf.update_memory_display()
      }
    }

    if let timer = self.memory_update_timer {
      RunLoop.main.add(timer, forMode: .common)
    } else {
      assertionFailure("Failed to create memory update timer.")
    }

    self.app.run()
  }

  @objc public func cleanup() {
    self.memory_update_timer?.invalidate()
    self.memory_update_timer = nil

    if self.status_bar.statusItem(withLength: status_item_width) === self.status_item {
      self.status_bar.removeStatusItem(self.status_item)
    }
  }

  // MARK: UI Actions & Delegate Methods
  public func menuWillOpen(_ menu: NSMenu) {
    assert(Thread.isMainThread, "menuWillOpen must be called on the main thread.")
    assert(menu === self.process_menu, "Delegate called for unexpected menu.")
    menu.removeAllItems()

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .memory
    formatter.zeroPadsFractionDigits = false
    formatter.isAdaptive = true

    // Helper for disabled items
    func add_disabled_menu_item(title: String) {
      let menu_item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      menu_item.isEnabled = false
      menu.addItem(menu_item)
    }

    // 1. System Memory Breakdown
    if let breakdown = Self.fetch_system_memory_breakdown() {
      add_disabled_menu_item(
        title: "Total RAM: \(formatter.string(fromByteCount: Int64(breakdown.total_bytes)))")
      menu.addItem(NSMenuItem.separator())
      add_disabled_menu_item(
        title: "Active: \(formatter.string(fromByteCount: Int64(breakdown.active_bytes)))")
      add_disabled_menu_item(
        title: "Wired: \(formatter.string(fromByteCount: Int64(breakdown.wired_bytes)))")
      add_disabled_menu_item(
        title: "Inactive: \(formatter.string(fromByteCount: Int64(breakdown.inactive_bytes)))")
      add_disabled_menu_item(
        title: "Compressed: \(formatter.string(fromByteCount: Int64(breakdown.compressed_bytes)))")
      add_disabled_menu_item(
        title: "Used (A+I+W): \(formatter.string(fromByteCount: Int64(breakdown.used_bytes)))")
      add_disabled_menu_item(
        title: "Free: \(formatter.string(fromByteCount: Int64(breakdown.free_bytes)))")
    } else {
      add_disabled_menu_item(title: "Could not fetch memory details")
    }

    // 2. Top Processes List
    menu.addItem(NSMenuItem.separator())
    add_disabled_menu_item(title: "Top Processes")

    guard self.total_physical_memory_bytes > 0 else {
      add_disabled_menu_item(title: "Error: Invalid total memory for process list.")
      menu.addItem(NSMenuItem.separator())
      add_quit_item(to: menu)
      return
    }

    let top_processes: [ProcessDetails] = Self.fetch_top_memory_processes(
      limit: top_process_count,
      total_physical_memory: self.total_physical_memory_bytes
    )

    if top_processes.isEmpty {
      add_disabled_menu_item(title: "Could not fetch processes")
    } else {
      for process in top_processes {
        let memory_str = formatter.string(fromByteCount: Int64(process.memory_usage_bytes))
        let menu_item = NSMenuItem(
          title: String(
            format: "%@ - %@ (%.1f%%)",
            process.name,
            memory_str,
            process.memory_usage_percentage),
          action: nil,
          keyEquivalent: ""
        )

        // Add PID as tooltip
        menu_item.toolTip = "PID: \(process.pid)"
        menu.addItem(menu_item)
      }
    }

    // 3. Quit Item
    menu.addItem(NSMenuItem.separator())
    add_quit_item(to: menu)
  }

  private func add_quit_item(to menu: NSMenu) {
    let quit_item = NSMenuItem(
      title: "Quit NanoStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit_item.target = NSApp
    menu.addItem(quit_item)
  }

  // MARK: Core Logic - Memory Usage
  private static func fetch_system_memory_breakdown() -> SystemMemoryBreakdown? {
    let total_physical_bytes = fetch_total_physical_memory_bytes()
    guard total_physical_bytes > 0 else { return nil }

    var stats = vm_statistics64()
    var count = host_vm_info64_count
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), host_vm_info64_flavor, $0, &count)
      }
    }

    guard result == KERN_SUCCESS, count == host_vm_info64_count else {
      print(
        "Error/Warning: host_statistics64 failed or returned unexpected count. Result: \(result), Count: \(count)"
      )
      return nil
    }

    let page_size = UInt64(vm_kernel_page_size)
    guard page_size > 0 else {
      assertionFailure("vm_kernel_page_size is zero")
      return nil
    }

    let active_bytes = UInt64(stats.active_count) * page_size
    let wired_bytes = UInt64(stats.wire_count) * page_size
    let inactive_bytes = UInt64(stats.inactive_count) * page_size
    let compressed_bytes = UInt64(stats.compressor_page_count) * page_size
    let inactive_weight = 0.25  // Count 25% of inactive memory as "used"
    let used_bytes = active_bytes + wired_bytes + UInt64(Double(inactive_bytes) * inactive_weight)
    let free_bytes = (total_physical_bytes >= used_bytes) ? total_physical_bytes - used_bytes : 0
    let usage_fraction =
      (total_physical_bytes > 0) ? Double(used_bytes) / Double(total_physical_bytes) : 0.0
    let usage_percentage = max(0.0, min(100.0, usage_fraction * 100.0))

    return SystemMemoryBreakdown(
      total_bytes: total_physical_bytes,
      active_bytes: active_bytes,
      wired_bytes: wired_bytes,
      inactive_bytes: inactive_bytes,
      compressed_bytes: compressed_bytes,
      free_bytes: free_bytes,
      used_bytes: used_bytes,
      usage_percentage: usage_percentage
    )
  }

  private static func fetch_total_physical_memory_bytes() -> UInt64 {
    var physical_memory: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &physical_memory, &size, nil, 0)

    guard result == 0, size == MemoryLayout<UInt64>.size, physical_memory > 0 else {
      print(
        "Error fetching/validating hw.memsize. Result: \(result), Size: \(size), Errno: \(errno)")
      return 0
    }

    return physical_memory
  }

  private func update_memory_display() {
    if let breakdown = Self.fetch_system_memory_breakdown() {
      if let status_view = self.status_view {
        status_view.updatePercentage(breakdown.usage_percentage)
      } else if let button = self.status_item.button {
        // Fallback if custom view isn't available
        button.title = String(format: "RAM: %.1f%%", breakdown.usage_percentage)
      }
    } else {
      if let button = self.status_item.button {
        button.title = "RAM: Error"
      }
    }
  }

  // MARK: Core Logic - Process Info
  /// Fetches a list of running processes sorted by resident memory size.
  private static func fetch_top_memory_processes(limit: Int, total_physical_memory: UInt64)
    -> [ProcessDetails]
  {
    assert(limit > 0 && total_physical_memory > 0)
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
        (total_physical_memory > 0)
        ? (Double(memory_bytes) / Double(total_physical_memory)) * 100.0 : 0.0

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

// MARK: - C Interface
@_cdecl("nano_stats_create")
public func nano_stats_create(title: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
  _ = NSApplication.shared
  let swift_title = String(cString: title)
  let app = NanoStatsApp(withTitle: swift_title)
  return Unmanaged.passRetained(app).toOpaque()
}

@_cdecl("nano_stats_run")
public func nano_stats_run(app_ptr: UnsafeMutableRawPointer) {
  let app = Unmanaged<NanoStatsApp>.fromOpaque(app_ptr).takeUnretainedValue()
  app.run()
}

@_cdecl("nano_stats_destroy")
public func nano_stats_destroy(app_ptr: UnsafeMutableRawPointer) {
  let app = Unmanaged<NanoStatsApp>.fromOpaque(app_ptr).takeRetainedValue()
  app.cleanup()
}
