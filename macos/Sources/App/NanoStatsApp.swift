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
    private let status_item_width: CGFloat = 35.0
    
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
        
        // Add system memory breakdown
        if let breakdown = memory_monitor.fetchMemoryBreakdown() {
            addSystemMemoryItems(breakdown: breakdown, formatter: formatter)
        } else {
            addDisabledMenuItem(title: "Could not fetch memory details")
        }
        
        // Add top processes list
        process_menu.addItem(NSMenuItem.separator())
        addDisabledMenuItem(title: "Top Processes")
        
        guard self.total_physical_memory_bytes > 0 else {
            addDisabledMenuItem(title: "Error: Invalid total memory for process list.")
            process_menu.addItem(NSMenuItem.separator())
            addQuitItem()
            return
        }
        
        let top_processes = process_monitor.fetchTopMemoryProcesses(
            limit: top_process_count,
            totalPhysicalMemory: self.total_physical_memory_bytes
        )
        
        if top_processes.isEmpty {
            addDisabledMenuItem(title: "Could not fetch processes")
        } else {
            addProcessItems(processes: top_processes, formatter: formatter)
        }
        
        // Add quit item
        process_menu.addItem(NSMenuItem.separator())
        addQuitItem()
    }
    
    private func addSystemMemoryItems(breakdown: SystemMemoryMonitor.MemoryBreakdown, formatter: ByteCountFormatter) {
        addDisabledMenuItem(title: "Total RAM: \(formatter.string(fromByteCount: Int64(breakdown.total_bytes)))")
        process_menu.addItem(NSMenuItem.separator())
        addDisabledMenuItem(title: "Active: \(formatter.string(fromByteCount: Int64(breakdown.active_bytes)))")
        addDisabledMenuItem(title: "Wired: \(formatter.string(fromByteCount: Int64(breakdown.wired_bytes)))")
        addDisabledMenuItem(title: "Inactive: \(formatter.string(fromByteCount: Int64(breakdown.inactive_bytes)))")
        addDisabledMenuItem(title: "Compressed: \(formatter.string(fromByteCount: Int64(breakdown.compressed_bytes)))")
        addDisabledMenuItem(title: "Used (A+I+W): \(formatter.string(fromByteCount: Int64(breakdown.used_bytes)))")
        addDisabledMenuItem(title: "Free: \(formatter.string(fromByteCount: Int64(breakdown.free_bytes)))")
    }
    
    private func addProcessItems(processes: [ProcessMemoryMonitor.ProcessDetails], formatter: ByteCountFormatter) {
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
}

