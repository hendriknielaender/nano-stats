import AppKit

/// Responsible for building and managing the process list menu
final class ProcessListMenu {
    private let menu: NSMenu
    private let menu_builder: MenuBuilder
    private let process_monitor: ProcessMemoryMonitor
    
    init(menu: NSMenu, process_monitor: ProcessMemoryMonitor) {
        self.menu = menu
        self.menu_builder = MenuBuilder(menu: menu)
        self.process_monitor = process_monitor
    }
    
    /// Builds the process list section of the menu
    func buildProcessList(totalPhysicalMemory: UInt64, limit: Int) {
        menu_builder.addSeparator()
        menu_builder.addDisabledMenuItem(title: "Top Processes")
        
        guard totalPhysicalMemory > 0 else {
            menu_builder.addDisabledMenuItem(title: "Error: Invalid total memory for process list.")
            return
        }
        
        let top_processes = process_monitor.fetchTopMemoryProcesses(
            limit: limit,
            totalPhysicalMemory: totalPhysicalMemory
        )
        
        if top_processes.isEmpty {
            menu_builder.addDisabledMenuItem(title: "Could not fetch processes")
            return
        }
        
        let formatter = menu_builder.createMemoryFormatter()
        
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
}

