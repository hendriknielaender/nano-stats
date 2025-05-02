import Foundation

/// Constants and type aliases for memory monitoring
enum MemoryTypes {
    typealias MachFlavor = Int32
    typealias MachMsgTypeNumber = mach_msg_type_number_t
    
    static let host_vm_info64_flavor: MachFlavor = HOST_VM_INFO64
    static let host_vm_info64_count: MachMsgTypeNumber =
      MachMsgTypeNumber(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
      )
}

