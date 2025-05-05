// macos/Sources/App/NanoStatsApp.swift
import AppKit
import Foundation

/// Main application class that manages the status bar item and menu.
public final class NanoStatsApp: NSObject, NSMenuDelegate {
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

  // State
  private var showingDetails: Bool = false

  // MARK: - Initialization
  public init(withTitle title: String) {
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
  }

  private func setupMenu() {
    self.process_menu.delegate = self
    self.status_item.menu = self.process_menu
  }

  // MARK: - Public API
  public func run() {
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

  public func cleanup() {
    self.memory_update_timer?.invalidate()
    self.memory_update_timer = nil

    if self.status_bar.statusItem(withLength: status_item_width) === self.status_item {
      self.status_bar.removeStatusItem(self.status_item)
    }
  }

  // MARK: - Menu Delegate
  public func menuWillOpen(_ menu: NSMenu) {
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

    // Memory Overview - Simplified
    if let breakdown = memory_monitor.fetchMemoryBreakdown() {
      // Total with usage percentage
      let total_item = NSMenuItem(
        title: "Memory: \(formatter.string(fromByteCount: Int64(breakdown.total_bytes)))",
        action: nil,
        keyEquivalent: ""
      )
      total_item.isEnabled = false
      process_menu.addItem(total_item)

      // Visual indicator
      addMemoryUsageBar(percentage: breakdown.usage_percentage)

      // Key metrics users care about
      addDisabledMenuItem(
        title: "Used: \(formatter.string(fromByteCount: Int64(breakdown.used_bytes)))")
      addDisabledMenuItem(
        title: "Available: \(formatter.string(fromByteCount: Int64(breakdown.free_bytes)))")

      // Add "Show Details..." option for power users
      if showingDetails {
        process_menu.addItem(NSMenuItem.separator())
        addDisabledMenuItem(title: "Memory Details")
        addDisabledMenuItem(
          title: "  Active: \(formatter.string(fromByteCount: Int64(breakdown.active_bytes)))")
        addDisabledMenuItem(
          title: "  Wired: \(formatter.string(fromByteCount: Int64(breakdown.wired_bytes)))")
        addDisabledMenuItem(
          title: "  Inactive: \(formatter.string(fromByteCount: Int64(breakdown.inactive_bytes)))")
        addDisabledMenuItem(
          title:
            "  Compressed: \(formatter.string(fromByteCount: Int64(breakdown.compressed_bytes)))")
      }

      // Toggle for showing details
      process_menu.addItem(NSMenuItem.separator())
      let details_item = NSMenuItem(
        title: showingDetails ? "Hide Details" : "Show Details...",
        action: #selector(toggleDetails),
        keyEquivalent: ""
      )
      details_item.target = self
      process_menu.addItem(details_item)
    } else {
      addDisabledMenuItem(title: "Could not fetch memory details")
    }

    // Process List - Streamlined
    process_menu.addItem(NSMenuItem.separator())
    addDisabledMenuItem(title: "Apps Using Memory")

    guard self.total_physical_memory_bytes > 0 else {
      addDisabledMenuItem(title: "Error: Could not determine memory usage")
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
      addDisabledMenuItem(title: "No significant memory usage detected")
    } else {
      // Add processes - Apple style with subtitles
      for process in top_processes {
        let memory_str = formatter.string(fromByteCount: Int64(process.memory_usage_bytes))

        // Create menu item with app name and memory as subtitle
        let menu_item = NSMenuItem(title: process.name, action: nil, keyEquivalent: "")

        // Use subtitle if available (macOS 11+), otherwise fall back to title with dash
        if #available(macOS 11.0, *) {
          menu_item.subtitle = memory_str
        } else {
          menu_item.title = "\(process.name) — \(memory_str)"
        }

        // Add to menu
        process_menu.addItem(menu_item)
      }

      // Option to open Activity Monitor
      process_menu.addItem(NSMenuItem.separator())
      let activity_monitor_item = NSMenuItem(
        title: "Open Activity Monitor...",
        action: #selector(openActivityMonitor),
        keyEquivalent: ""
      )
      activity_monitor_item.target = self
      process_menu.addItem(activity_monitor_item)
    }

    // Add memory pressure warning if needed
    if let breakdown = memory_monitor.fetchMemoryBreakdown(), breakdown.usage_percentage > 85 {
      process_menu.addItem(NSMenuItem.separator())

      let high_usage_item = NSMenuItem(
        title: "Memory pressure is high",
        action: #selector(showMemoryTips),
        keyEquivalent: ""
      )
      high_usage_item.target = self
      process_menu.addItem(high_usage_item)
    }

    // Quit item
    process_menu.addItem(NSMenuItem.separator())
    addQuitItem()
  }

  private func addMemoryUsageBar(percentage: Double) {
    // Create a visual indicator of memory usage
    let bar_view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 18))

    // Background track
    let track = NSView(frame: NSRect(x: 16, y: 7, width: 168, height: 4))
    track.wantsLayer = true
    track.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
    track.layer?.cornerRadius = 2

    // Filled portion
    let fill_width = Int((percentage / 100.0) * 168)
    let fill = NSView(frame: NSRect(x: 16, y: 7, width: fill_width, height: 4))
    fill.wantsLayer = true

    // Color based on usage
    if percentage > 85 {
      fill.layer?.backgroundColor = NSColor.systemRed.cgColor
    } else if percentage > 60 {
      fill.layer?.backgroundColor = NSColor.systemOrange.cgColor
    } else {
      fill.layer?.backgroundColor = NSColor.systemBlue.cgColor
    }

    fill.layer?.cornerRadius = 2

    bar_view.addSubview(track)
    bar_view.addSubview(fill)

    let menu_item = NSMenuItem()
    menu_item.view = bar_view
    process_menu.addItem(menu_item)
  }

  private func addDisabledMenuItem(title: String) {
    let menu_item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menu_item.isEnabled = false
    process_menu.addItem(menu_item)
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

  @objc private func openActivityMonitor() {
    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleDetails() {
    showingDetails = !showingDetails
    // Refresh menu
    if let menu = status_item.menu {
      self.menuWillOpen(menu)
    }
  }

  @objc private func showMemoryTips() {
    // In a full implementation, this would show a window with memory optimization tips
    let alert = NSAlert()
    alert.messageText = "Memory Usage Tips"
    alert.informativeText =
      "• Close applications you're not using\n• Restart applications that have been running for a long time\n• Check Activity Monitor for memory-intensive processes"
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Open Activity Monitor")

    let response = alert.runModal()
    if response == NSApplication.ModalResponse.alertSecondButtonReturn {
      openActivityMonitor()
    }
  }
}
