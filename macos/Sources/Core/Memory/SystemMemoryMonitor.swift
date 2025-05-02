import Foundation

/// Responsible for monitoring system-wide memory usage.
final class SystemMemoryMonitor {
    /// Holds the system-wide memory breakdown calculated from vm_statistics64.
    struct MemoryBreakdown {
        let total_bytes: UInt64
        let active_bytes: UInt64
        let wired_bytes: UInt64
        let inactive_bytes: UInt64
        let compressed_bytes: UInt64
        let free_bytes: UInt64
        let used_bytes: UInt64
        let usage_percentage: Double
    }
    
    private let host_vm_info64_flavor: Int32 = HOST_VM_INFO64
    private let host_vm_info64_count: mach_msg_type_number_t = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    
    /// Fetches the total physical memory available on the system.
    /// Returns 0 if the operation fails.
    func fetchTotalPhysicalMemory() -> UInt64 {
        var physical_memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &physical_memory, &size, nil, 0)
        
        guard result == 0, size == MemoryLayout<UInt64>.size, physical_memory > 0 else {
            print("Error fetching hw.memsize. Result: \(result), Size: \(size), Errno: \(errno)")
            return 0
        }
        
        return physical_memory
    }
    
    /// Fetches current system memory statistics.
    /// Returns nil if the operation fails.
    func fetchMemoryBreakdown() -> MemoryBreakdown? {
        let total_physical_bytes = fetchTotalPhysicalMemory()
        guard total_physical_bytes > 0 else { return nil }
        
        var stats = vm_statistics64()
        var count = host_vm_info64_count
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_vm_info64_flavor, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS, count == host_vm_info64_count else {
            print("Error: host_statistics64 failed. Result: \(result), Count: \(count)")
            return nil
        }
        
        let page_size = UInt64(vm_kernel_page_size)
        guard page_size > 0 else {
            print("Error: vm_kernel_page_size is zero")
            return nil
        }
        
        let active_bytes = UInt64(stats.active_count) * page_size
        let wired_bytes = UInt64(stats.wire_count) * page_size
        let inactive_bytes = UInt64(stats.inactive_count) * page_size
        let compressed_bytes = UInt64(stats.compressor_page_count) * page_size
        
        // Count 25% of inactive memory as "used" - this matches macOS Activity Monitor behavior
        let inactive_weight = 0.25
        let used_bytes = active_bytes + wired_bytes + UInt64(Double(inactive_bytes) * inactive_weight)
        let free_bytes = (total_physical_bytes >= used_bytes) ? total_physical_bytes - used_bytes : 0
        
        let usage_fraction = (total_physical_bytes > 0) ? Double(used_bytes) / Double(total_physical_bytes) : 0.0
        let usage_percentage = max(0.0, min(100.0, usage_fraction * 100.0))
        
        return MemoryBreakdown(
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
}

