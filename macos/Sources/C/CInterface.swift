import AppKit
// macos/Sources/C/CInterface.swift
import Foundation

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
