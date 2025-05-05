import Darwin
// macos/Sources/Core/Memory/MemoryTypes.swift
import Foundation

/// Constants and type aliases for memory monitoring
public enum MemoryTypes {
  public typealias MachFlavor = Int32
  public typealias MachMsgTypeNumber = mach_msg_type_number_t

  public static let host_vm_info64_flavor: MachFlavor = HOST_VM_INFO64
  public static let host_vm_info64_count: MachMsgTypeNumber =
    MachMsgTypeNumber(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
}
