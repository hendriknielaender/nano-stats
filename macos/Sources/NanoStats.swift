import AppKit
import Foundation
import Darwin

// MARK: - Constants and Type Aliases

// Using explicit type aliases for Mach constants enhances clarity.
private typealias MachFlavor = Int32
private typealias MachMsgTypeNumber = mach_msg_type_number_t

// Constant for host_statistics64 vm_info flavor.
private let hostVmInfo64Flavor: MachFlavor = HOST_VM_INFO64 // = 4

// Expected count of integers in vm_statistics64_data_t.
// Calculated at compile time for safety.
private let hostVmInfo64Count: MachMsgTypeNumber =
    MachMsgTypeNumber(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )

// Constant for sysctl to get all process information.
private let sysctlKernProcAll: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]

// Constant for proc_pidinfo to get task information (memory).
private let procPidTaskInfoFlavor: Int32 = PROC_PIDTASKINFO

// MARK: - Data Structures

/// Holds information about a single running process for display.
/// Using a struct promotes value semantics and memory efficiency.
// Renamed from ProcessInfo to avoid collision with Foundation.ProcessInfo
private struct ProcessDetails: Comparable {
    let pid: pid_t
    let name: String
    let residentMemoryBytes: UInt64
    let memoryUsagePercentage: Double

    // Conformance to Comparable for sorting processes by memory usage (descending).
    static func < (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
        // Higher memory usage should come first.
        return lhs.residentMemoryBytes > rhs.residentMemoryBytes
    }

    // Static func for equality check if needed, though not strictly required for sorting.
    static func == (lhs: ProcessDetails, rhs: ProcessDetails) -> Bool {
        return lhs.pid == rhs.pid
    }
}

// MARK: - Main Application Class

@objc public final class NanoStatsApp: NSObject, NSMenuDelegate {
    // MARK: Properties

    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let app: NSApplication
    private var memoryUpdateTimer: Timer?
    private let processMenu: NSMenu
    private var totalPhysicalMemoryBytes: UInt64 = 0

    // Configuration
    private let memoryUpdateIntervalSeconds: TimeInterval = 2.0
    private let topProcessCount: Int = 10
    private let statusItemLength = NSStatusItem.variableLength

    // MARK: Initialization

    @objc public init(withTitle title: String) {
        // Precondition: Must be called on the main thread for AppKit.
        assert(Thread.isMainThread, "NanoStatsApp must be initialized on the main thread.")

        self.app = NSApplication.shared
        self.statusBar = NSStatusBar.system
        self.statusItem = self.statusBar.statusItem(withLength: statusItemLength)

        // Create the menu that will be populated later.
        self.processMenu = NSMenu()

        super.init()

        // Fetch total physical memory once at startup.
        self.totalPhysicalMemoryBytes = Self.fetchTotalPhysicalMemoryBytes()
        assert(self.totalPhysicalMemoryBytes > 0, "Failed to fetch total physical memory.")

        // Configure the status bar item button.
        if let button = self.statusItem.button {
            button.title = title // Initial title
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            self.statusItem.menu = self.processMenu
        } else {
            assertionFailure("Failed to get status item button.")
        }

        // Set the menu delegate to self to handle `menuWillOpen`.
        self.processMenu.delegate = self

        // Activation policy should be set early.
        // Check if running in sandbox, as it might restrict setting policy.
        if Foundation.ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
             // Only set if not sandboxed, otherwise it can cause issues.
            self.app.setActivationPolicy(.accessory)
        }

        self.updateMemoryDisplay()
    }

    // MARK: Public API

    /// Starts the application's run loop and memory update timer.
    @objc public func run() {
        // Precondition: Must be called on the main thread.
        assert(Thread.isMainThread, "run() must be called on the main thread.")

        // Schedule the timer for periodic memory updates.
        // Use [weak self] to prevent retain cycles.
        self.memoryUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: memoryUpdateIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            // Ensure self is still valid and execute on main thread.
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.updateMemoryDisplay()
            }
        }

        if let timer = self.memoryUpdateTimer {
            RunLoop.main.add(timer, forMode: .common)
        } else {
             assertionFailure("Failed to create memory update timer.")
        }

        self.app.run()
    }

    /// Stops the timer when the application is terminating or being destroyed.
    @objc public func cleanup() {
        self.memoryUpdateTimer?.invalidate()
        self.memoryUpdateTimer = nil
        self.statusBar.removeStatusItem(self.statusItem)
    }

    // MARK: UI Actions & Delegate Methods

    /// Action triggered when the status bar item is clicked.
    /// Note: If a menu is assigned, this action might not be called directly,
    /// as the system handles showing the menu. Kept for completeness or
    /// if menu assignment changes.
    @objc private func statusBarButtonClicked(_ sender: Any?) {
        print("Status bar item clicked.")
    }

    /// NSMenuDelegate method called just before the menu is displayed.
    /// This is where we dynamically populate the process list.
    public func menuWillOpen(_ menu: NSMenu) {
        assert(Thread.isMainThread, "menuWillOpen must be called on the main thread.")
        assert(menu === self.processMenu, "Delegate called for unexpected menu.")

        // Clear previous items except potentially persistent ones (like Quit).
        // Start from index 0 as we rebuild the list each time.
        menu.removeAllItems()

        // Add a title item showing total memory
        let totalMemoryMB = Double(totalPhysicalMemoryBytes) / (1024.0 * 1024.0)
        let titleItem = NSMenuItem(
            title: String(format: "Total RAM: %.1f MB", totalMemoryMB),
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false // Not selectable
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator()) // Visual separator

        // Fetch and add top memory consuming processes.
        // This is potentially slow, consider background thread if UI becomes unresponsive.
        // For now, keep it simple on the main thread.
        let topProcesses: [ProcessDetails] = Self.fetchTopMemoryProcesses(
            limit: topProcessCount,
            totalPhysicalMemory: totalPhysicalMemoryBytes
        )

        if topProcesses.isEmpty {
            let errorItem = NSMenuItem(
                title: "Could not fetch processes",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        } else {
            for process: ProcessDetails in topProcesses {
                let memoryMB = Double(process.residentMemoryBytes) / (1024.0 * 1024.0)
                let menuItem = NSMenuItem(
                    // Format: "Process Name - 123.4 MB (12.3%)"
                    title: String(format: "%@ - %.1f MB (%.1f%%)",
                                  process.name,
                                  memoryMB,
                                  process.memoryUsagePercentage),
                    action: nil,
                    keyEquivalent: ""
                )
                menu.addItem(menuItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "Quit NanoStats",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    // MARK: Core Logic - Memory Usage

    /// Fetches the current system-wide memory usage percentage.
    /// - Returns: Memory usage as a percentage (0.0 to 100.0), or `nil` on failure.
    private static func calculateMemoryUsagePercentage(totalPhysicalMemory: UInt64) -> Double? {
        // Precondition: Must have valid total physical memory.
        assert(totalPhysicalMemory > 0, "Total physical memory must be positive.")

        var stats = vm_statistics64()
        var count = hostVmInfo64Count // Use the predefined constant

        // Use `withUnsafeMutablePointer` for safe interaction with the C API.
        let result = withUnsafeMutablePointer(to: &stats) { statsPtr -> kern_return_t in
            // Rebind the memory to the type expected by host_statistics64.
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundedPtr in
                host_statistics64(mach_host_self(), hostVmInfo64Flavor, reboundedPtr, &count)
            }
        }

        // Check if the Mach call was successful.
        guard result == KERN_SUCCESS else {
            // Log the error for debugging. Use os_log in a real app.
            print("Error: host_statistics64 failed with kern_return_t: \(result)")
            return nil
        }

        // Ensure the count returned matches expected size. Safety check.
        guard count == hostVmInfo64Count else {
            print("Warning: host_statistics64 returned unexpected count: \(count)")
            return nil
        }


        // Get the system page size. This should not fail, but assert for safety.
        let pageSize = UInt64(vm_kernel_page_size)
        assert(pageSize > 0, "vm_kernel_page_size returned zero or negative.")

        // Calculate "used" memory based on Mach VM statistics.
        // This includes active, inactive, and wired memory pages.
        let usedBytes = (UInt64(stats.active_count) +
                         UInt64(stats.inactive_count) +
                         UInt64(stats.wire_count)) * pageSize

        // Calculate the usage fraction.
        // Avoid division by zero, although asserted earlier.
        guard totalPhysicalMemory > 0 else { return nil }
        let usageFraction = Double(usedBytes) / Double(totalPhysicalMemory)

        // Convert fraction to percentage. Clamp between 0 and 100 just in case.
        let usagePercentage = max(0.0, min(100.0, usageFraction * 100.0))

        return usagePercentage
    }

    /// Fetches the total physical memory installed on the system.
    /// - Returns: Total physical memory in bytes, or 0 on failure.
    private static func fetchTotalPhysicalMemoryBytes() -> UInt64 {
        var physicalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size

        // Use sysctlbyname to get hardware memory size.
        let result = sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0)

        guard result == 0 else {
            print("Error: sysctlbyname(\"hw.memsize\") failed with result: \(result), errno: \(errno)")
            return 0 // Indicate failure
        }
        // Postcondition: Ensure size matches expected size.
        guard size == MemoryLayout<UInt64>.size else {
             print("Warning: sysctlbyname(\"hw.memsize\") returned unexpected size: \(size)")
             // Return 0 as the value might be corrupted.
             return 0
        }

        // Postcondition: Memory size must be positive.
        guard physicalMemory > 0 else {
            print("Error: sysctlbyname(\"hw.memsize\") returned non-positive memory size.")
            return 0
        }

        return physicalMemory
    }

    /// Updates the status bar item title with the current RAM usage.
    private func updateMemoryDisplay() {
        // Ensure we have total memory; should have been fetched at init.
        guard totalPhysicalMemoryBytes > 0 else {
            // This case should ideally not happen after successful init.
            statusItem.button?.title = "RAM: N/A"
            assertionFailure("Total physical memory is zero during update.")
            return
        }

        // Calculate the current usage percentage.
        if let usagePercent = Self.calculateMemoryUsagePercentage(totalPhysicalMemory: totalPhysicalMemoryBytes) {
            // Update the button title, formatted to one decimal place.
            statusItem.button?.title = String(format: "RAM: %.1f%%", usagePercent)
        } else {
            // Handle failure to calculate usage.
            statusItem.button?.title = "RAM: Error"
            // Log this failure for diagnostics.
            print("Failed to calculate memory usage percentage during update.")
        }
    }

    // MARK: Core Logic - Process Info

    /// Fetches a list of running processes sorted by memory usage.
    /// - Parameter limit: The maximum number of processes to return.
    /// - Parameter totalPhysicalMemory: Total system memory in bytes for percentage calculation.
    /// - Returns: An array of `ProcessInfo` structs, sorted descending by memory usage,
    ///            or an empty array on failure.
    private static func fetchTopMemoryProcesses(limit: Int, totalPhysicalMemory: UInt64) -> [ProcessDetails] {
        // Preconditions
        assert(limit > 0, "Process limit must be positive.")
        assert(totalPhysicalMemory > 0, "Total physical memory must be positive.")

        var processDetails: [ProcessDetails] = []
        var pids: [pid_t] = []
        var C_pids_ptr: UnsafeMutablePointer<pid_t>? = nil // Renamed to avoid conflict
        var bufferSize: Int = 0

        // 1. Get the list of all Process IDs (PIDs) using sysctl KERN_PROC_ALL.
        // This requires determining the buffer size first.
        var mib = sysctlKernProcAll // Use predefined constant array
        var sysctlResult = sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0)

        guard sysctlResult == 0 else {
            print("Error: sysctl (size check) for KERN_PROC_ALL failed: \(errno)")
            return []
        }

        // Allocate buffer for PIDs. Need to handle potential allocation failure.
        let pidCount = bufferSize / MemoryLayout<pid_t>.size
        C_pids_ptr = UnsafeMutablePointer<pid_t>.allocate(capacity: pidCount)
        defer { C_pids_ptr?.deallocate() } // Ensure buffer is deallocated

        guard let C_pids = C_pids_ptr else {
             print("Error: Failed to allocate buffer for PIDs.")
             return []
        }

        // Now get the actual PIDs.
        sysctlResult = sysctl(&mib, UInt32(mib.count), C_pids, &bufferSize, nil, 0)

        guard sysctlResult == 0 else {
            print("Error: sysctl (data fetch) for KERN_PROC_ALL failed: \(errno)")
            return []
        }

        // Verify the returned size again.
        let actualPidCount = bufferSize / MemoryLayout<pid_t>.size
        guard actualPidCount <= pidCount else {
            print("Warning: PID buffer size mismatch after fetch.")
            // Handle potential overflow or unexpected data. Safest is to return empty.
            return []
        }

        // Convert C array to Swift array for easier handling.
        pids = Array(UnsafeBufferPointer(start: C_pids, count: actualPidCount))

        // 2. Iterate through PIDs and get info for each.
        for pid in pids {
            // Skip kernel process (pid 0) and potentially idle process.
            if pid <= 0 { continue }

            var taskInfo = proc_taskinfo()
            let taskInfoSize = MemoryLayout<proc_taskinfo>.size

            // Get task info (includes memory) using proc_pidinfo.
            let bytesCopied = proc_pidinfo(
                pid,
                procPidTaskInfoFlavor, // PROC_PIDTASKINFO
                0, // Argument (unused for this flavor)
                &taskInfo,
                Int32(taskInfoSize)
            )

            // Check if proc_pidinfo succeeded and returned the expected size.
            // It returns the number of bytes copied, or <= 0 on error.
            // Common errors: ESRCH (no such process - process terminated), EPERM (permission denied).
            guard bytesCopied > 0 else {
                // Process might have terminated between getting PID list and now. This is expected.
                // Or permission denied (e.g., for some system processes if not running as root).
                // Silently continue to the next PID.
                // if errno != ESRCH { print("proc_pidinfo for pid \(pid) failed: \(errno)") }
                continue
            }
            guard bytesCopied == taskInfoSize else {
                 print("Warning: proc_pidinfo for pid \(pid) returned unexpected size: \(bytesCopied)")
                 continue // Skip potentially corrupt data
            }


            // Get process name using proc_pidpath.
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathBytesCopied = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

            var processName = "Unknown"
            if pathBytesCopied > 0 {
                // Convert C string path to Swift string and extract filename.
                let path = String(cString: pathBuffer)
                if let url = URL(string: path), !url.lastPathComponent.isEmpty {
                    processName = url.lastPathComponent
                } else if !path.isEmpty {
                    // Fallback if URL parsing fails but path is not empty
                    processName = (path as NSString).lastPathComponent
                }
            } else {
                 // Failed to get path, might be zombie or restricted process.
                 // Keep name as "Unknown" or potentially use taskInfo.pti_name if available/reliable.
                 // print("Warning: proc_pidpath for pid \(pid) failed: \(errno)")
            }


            // Calculate memory percentage for this process.
            let residentBytes = taskInfo.pti_resident_size
            let percentage = (totalPhysicalMemory > 0)
                ? (Double(residentBytes) / Double(totalPhysicalMemory)) * 100.0
                : 0.0

            // Create the ProcessInfo struct.
            let info = ProcessDetails(
                pid: pid,
                name: processName,
                residentMemoryBytes: residentBytes,
                memoryUsagePercentage: max(0.0, min(100.0, percentage)) // Clamp percentage
            )
            processDetails.append(info)
        }

        // 3. Sort the collected process information (descending by memory).
        // The `Comparable` conformance on `ProcessInfo` handles the sorting logic.
        processDetails.sort()

        // 4. Return the top 'limit' processes.
        return Array(processDetails.prefix(limit))
    }

    // MARK: - Helper Functions (Example)

    /// Formats bytes into a human-readable string (KB, MB, GB).
    /// Example helper, not currently used in menu but could be useful.
    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - C Interface

// Keep the C interface for potential integration, ensuring ARC bridging is correct.

/// Creates an instance of the NanoStatsApp.
/// - Parameter title: The initial title for the status bar item (C string).
/// - Returns: An opaque pointer to the NanoStatsApp instance. The caller owns this pointer
///            and is responsible for calling nano_stats_destroy.
@_cdecl("nano_stats_create")
public func nano_stats_create(title: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    // Precondition: title must be a valid C string.
    // Note: Checking validity of C pointers is hard, rely on caller correctness.

    // Ensure AppKit is initialized on the main thread if not already running.
    // This check helps if called very early.
    _ = NSApplication.shared // Access shared to ensure initialization.

    let swiftTitle = String(cString: title)
    let app = NanoStatsApp(withTitle: swiftTitle)

    // Transfer ownership to the C caller using Unmanaged.passRetained.
    return Unmanaged.passRetained(app).toOpaque()
}

/// Runs the NanoStatsApp instance. This function blocks until the application terminates.
/// - Parameter appPtr: An opaque pointer previously returned by nano_stats_create.
@_cdecl("nano_stats_run")
public func nano_stats_run(appPtr: UnsafeMutableRawPointer) {
    // Precondition: appPtr must be a valid pointer returned by nano_stats_create.
    // Take an unretained reference because `run` doesn't consume ownership,
    // the caller still owns it until `destroy`.
    let app = Unmanaged<NanoStatsApp>.fromOpaque(appPtr).takeUnretainedValue()
    app.run()
}

/// Destroys the NanoStatsApp instance and releases associated resources.
/// - Parameter appPtr: An opaque pointer previously returned by nano_stats_create.
@_cdecl("nano_stats_destroy")
public func nano_stats_destroy(appPtr: UnsafeMutableRawPointer) {
    // Precondition: appPtr must be a valid pointer returned by nano_stats_create.
    // Take ownership back from the C caller and release the object.
    let app = Unmanaged<NanoStatsApp>.fromOpaque(appPtr).takeRetainedValue()
    app.cleanup() // Perform any necessary cleanup before ARC releases it.
    // ARC will automatically release 'app' at the end of this scope.
}

