import AppKit

/// Main application class that manages the status bar item and menu.
final class NanoStatsApp: NSObject, NSMenuDelegate {
  // MARK: - Properties
  private let status_bar: NSStatusBar
  private let status_item: NSStatusItem
  private let app: NSApplication
  private var memory_update_timer: Timer?
  private let process_menu: NSMenu
  private var total_physical_memory_bytes: UInt64 = 0
  private var status_view: MemoryStatusView?

  // Monitors
  private let memory_monitor = SystemMemoryMonitor()
  private let process_monitor = ProcessMemoryMonitor()

  // Configuration
  private let memory_update_interval_seconds: TimeInterval = 2.0
  private let top_process_count: Int = 10
  private let status_item_width: CGFloat = 40.0

  // MARK: - Initialization
  init(withTitle title: String) {
    assert(Thread.isMainThread, "NanoStatsApp must be initialized on the main thread.")

    self.app = NSApplication.shared
    self.status_bar = NSStatusBar.system
    self.status_item = self.status_bar.statusItem(withLength: status_item_width)
    self.process_menu = NSMenu()

    super.init()

    self.total_physical_memory_bytes = memory_monitor.fetchTotalPhysicalMemory()
    assert(self.total_physical_memory_bytes > 0, "Failed to fetch total physical memory at init.")

    setupStatusItem()
    setupMenu()

    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
      self.app.setActivationPolicy(.accessory)
    }

    updateMemoryDisplay()
  }

  // MARK: - Setup Methods
  private func setupStatusItem() {
    guard let button = self.status_item.button else {
      assertionFailure("Failed to get status item button.")
      return
    }

    // Create and configure custom view
    let custom_view = MemoryStatusView(
      frame: NSRect(x: 5, y: 0, width: status_item_width, height: 20))
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
  }

  private func setupMenu() {
    self.process_menu.delegate = self
    self.status_item.menu = self.process_menu
  }

  // MARK: - Public API
  func run() {
    assert(Thread.isMainThread, "run() must be called on the main thread.")

    self.memory_update_timer = Timer.scheduledTimer(
      withTimeInterval: memory_update_interval_seconds,
      repeats: true
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let strongSelf = self else { return }
        strongSelf.updateMemoryDisplay()
      }
    }

    if let timer = self.memory_update_timer {
      RunLoop.main.add(timer, forMode: .common)
    } else {
      assertionFailure("Failed to create memory update timer.")
    }

    self.app.run()
  }

  func cleanup() {
    self.memory_update_timer?.invalidate()
    self.memory_update_timer = nil

    if self.status_bar.statusItem(withLength: status_item_width) === self.status_item {
      self.status_bar.removeStatusItem(self.status_item)
    }
  }

  // MARK: - Menu Delegate
  func menuWillOpen(_ menu: NSMenu) {
    assert(Thread.isMainThread, "menuWillOpen must be called on the main thread.")
    assert(menu === self.process_menu, "Delegate called for unexpected menu.")

    buildMenu()
  }

  // MARK: - Private Methods
  private func buildMenu() {
    process_menu.removeAllItems()

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .memory
    formatter.zeroPadsFractionDigits = false
    formatter.isAdaptive = true

    // System Memory Overview
    if let breakdown = memory_monitor.fetchMemoryBreakdown() {
      // Total RAM (header)
      let total_item = NSMenuItem(
        title: "Total RAM: \(formatter.string(fromByteCount: Int64(breakdown.total_bytes)))",
        action: nil,
        keyEquivalent: ""
      )
      total_item.isEnabled = false
      process_menu.addItem(total_item)

      // Separator
      process_menu.addItem(NSMenuItem.separator())

      // Memory breakdown
      addMemoryItem(title: "Active", value: breakdown.active_bytes, formatter: formatter)
      addMemoryItem(title: "Wired", value: breakdown.wired_bytes, formatter: formatter)
      addMemoryItem(title: "Inactive", value: breakdown.inactive_bytes, formatter: formatter)
      addMemoryItem(title: "Compressed", value: breakdown.compressed_bytes, formatter: formatter)
      addMemoryItem(title: "Used", value: breakdown.used_bytes, formatter: formatter)
      addMemoryItem(title: "Free", value: breakdown.free_bytes, formatter: formatter)
    } else {
      let error_item = NSMenuItem(
        title: "Could not fetch memory details", action: nil, keyEquivalent: "")
      error_item.isEnabled = false
      process_menu.addItem(error_item)
    }

    // Process List
    process_menu.addItem(NSMenuItem.separator())

    let processes_header = NSMenuItem(title: "Top Processes", action: nil, keyEquivalent: "")
    processes_header.isEnabled = false
    process_menu.addItem(processes_header)

    guard self.total_physical_memory_bytes > 0 else {
      let error_item = NSMenuItem(
        title: "Error: Invalid total memory for process list",
        action: nil,
        keyEquivalent: ""
      )
      error_item.isEnabled = false
      process_menu.addItem(error_item)

      // Quit item
      process_menu.addItem(NSMenuItem.separator())
      addQuitItem()
      return
    }

    // Get top processes
    let top_processes = process_monitor.fetchTopMemoryProcesses(
      limit: top_process_count,
      totalPhysicalMemory: self.total_physical_memory_bytes
    )

    if top_processes.isEmpty {
      let error_item = NSMenuItem(
        title: "Could not fetch processes", action: nil, keyEquivalent: "")
      error_item.isEnabled = false
      process_menu.addItem(error_item)
    } else {
      // Add processes with proper styling
      for process in top_processes {
        let memory_str = formatter.string(fromByteCount: Int64(process.memory_usage_bytes))

        // Create attributed string for process item
        let process_name = process.name
        let memory_info =
          "\(memory_str) (\(String(format: "%.1f%%", process.memory_usage_percentage)))"

        let attributed_string = NSMutableAttributedString()

        // Process name (regular weight)
        let process_attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: NSColor.labelColor,
        ]
        attributed_string.append(
          NSAttributedString(string: process_name, attributes: process_attributes))

        // Spacer
        attributed_string.append(NSAttributedString(string: " — ", attributes: process_attributes))

        // Memory info (lighter weight)
        let memory_attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 13, weight: .light),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
        attributed_string.append(
          NSAttributedString(string: memory_info, attributes: memory_attributes))

        // Create menu item with attributed string
        let menu_item = NSMenuItem()
        menu_item.attributedTitle = attributed_string

        // Add PID as tooltip
        menu_item.toolTip = "Process ID: \(process.pid)"

        // Add to menu
        process_menu.addItem(menu_item)
      }
    }

    // Quit item
    process_menu.addItem(NSMenuItem.separator())
    addQuitItem()
  }

  private func addMemoryItem(title: String, value: UInt64, formatter: ByteCountFormatter) {
    // Create attributed string for memory item
    let attributed_string = NSMutableAttributedString()

    // Title (regular weight)
    let title_attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: NSColor.labelColor,
    ]
    attributed_string.append(NSAttributedString(string: title, attributes: title_attributes))

    // Spacer
    attributed_string.append(NSAttributedString(string: ": ", attributes: title_attributes))

    // Value (lighter weight)
    let value_attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .light),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    attributed_string.append(
      NSAttributedString(
        string: formatter.string(fromByteCount: Int64(value)),
        attributes: value_attributes
      ))

    // Create menu item with attributed string
    let item = NSMenuItem()
    item.attributedTitle = attributed_string
    item.isEnabled = false

    process_menu.addItem(item)
  }

  private func addQuitItem() {
    let quit_item = NSMenuItem(
      title: "Quit NanoStats",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quit_item.target = NSApp
    process_menu.addItem(quit_item)
  }

  private func addSystemMemoryItems(
    breakdown: SystemMemoryMonitor.MemoryBreakdown, formatter: ByteCountFormatter
  ) {
    addDisabledMenuItem(
      title: "Total RAM: \(formatter.string(fromByteCount: Int64(breakdown.total_bytes)))")
    process_menu.addItem(NSMenuItem.separator())
    addDisabledMenuItem(
      title: "Active: \(formatter.string(fromByteCount: Int64(breakdown.active_bytes)))")
    addDisabledMenuItem(
      title: "Wired: \(formatter.string(fromByteCount: Int64(breakdown.wired_bytes)))")
    addDisabledMenuItem(
      title: "Inactive: \(formatter.string(fromByteCount: Int64(breakdown.inactive_bytes)))")
    addDisabledMenuItem(
      title: "Compressed: \(formatter.string(fromByteCount: Int64(breakdown.compressed_bytes)))")
    addDisabledMenuItem(
      title: "Used (A+I+W): \(formatter.string(fromByteCount: Int64(breakdown.used_bytes)))")
    addDisabledMenuItem(
      title: "Free: \(formatter.string(fromByteCount: Int64(breakdown.free_bytes)))")
  }

  private func addProcessItems(
    processes: [ProcessMemoryMonitor.ProcessDetails], formatter: ByteCountFormatter
  ) {
    for process in processes {
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
      process_menu.addItem(menu_item)
    }
  }

  private func addDisabledMenuItem(title: String) {
    let menu_item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menu_item.isEnabled = false
    process_menu.addItem(menu_item)
  }

  private func updateMemoryDisplay() {
    if let breakdown = memory_monitor.fetchMemoryBreakdown() {
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
}
