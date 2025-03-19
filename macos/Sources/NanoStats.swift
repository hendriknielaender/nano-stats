import AppKit
import Foundation
import Darwin // for sysctl, host_statistics, etc.

private typealias mach_flavor_t = Int32
private let HOST_VM_INFO64: mach_flavor_t = 4 

private let HOST_VM_INFO64_COUNT: mach_msg_type_number_t =
    mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size
        / MemoryLayout<integer_t>.size
    )

@objc public class NanoStatsApp: NSObject {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var app: NSApplication
    private var memoryTimer: Timer?

    @objc public init(withTitle title: String) {
        self.app = NSApplication.shared
        self.statusBar = NSStatusBar.system
        self.statusItem = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        // Set activation policy before doing UI work
        self.app.setActivationPolicy(.accessory)

        if let button = self.statusItem.button {
            button.title = title
        }
    }

    @objc public func run() {
        // Timer to update RAM usage in menu bar.
        self.memoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            let usage = strongSelf.fetchMemoryUsagePercent()
            if let button = strongSelf.statusItem.button {
                button.title = String(format: "RAM: %.1f%%", usage)
            }
        }
        self.app.run()
    }

    private func fetchMemoryUsagePercent() -> Double {
        // 1. Fetch total physical memory.
        var physicalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0) != 0 {
            return 0.0
        }

        // 2. Get vm_statistics64 via host_statistics64.
        var stats = vm_statistics64()
        var count = HOST_VM_INFO64_COUNT

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result != KERN_SUCCESS {
            return 0.0
        }

        // 3. Calculate "used" memory in bytes.
        let pageSize = UInt64(vm_kernel_page_size)
        let usedBytes = (UInt64(stats.active_count)
                         + UInt64(stats.inactive_count)
                         + UInt64(stats.wire_count))
                         * pageSize

        // 4. Convert to fraction of total memory, then percent.
        let usageFraction = Double(usedBytes) / Double(physicalMemory)
        return usageFraction * 100.0
    }
}

// C-compatible interface
@_cdecl("nano_stats_create")
public func nano_stats_create(title: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    
    let swiftTitle = String(cString: title)
    let app = NanoStatsApp(withTitle: swiftTitle)
    return Unmanaged.passRetained(app).toOpaque()
}

@_cdecl("nano_stats_run")
public func nano_stats_run(appPtr: UnsafeMutableRawPointer) {
    let app = Unmanaged<NanoStatsApp>.fromOpaque(appPtr).takeUnretainedValue()
    app.run()
}

@_cdecl("nano_stats_destroy")
public func nano_stats_destroy(appPtr: UnsafeMutableRawPointer) {
    Unmanaged<NanoStatsApp>.fromOpaque(appPtr).release()
}

