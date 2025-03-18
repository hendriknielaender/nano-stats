import AppKit
import Foundation

@objc public class NanoStatsApp: NSObject {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var app: NSApplication
    
    @objc public init(withTitle title: String) {
        // Create shared application instance first
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
        // No need to call setActivationPolicy again
        self.app.run()
    }
}

// C-compatible interface
@_cdecl("nano_stats_create")
public func nano_stats_create(title: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    // Process must have a bundle to properly initialize AppKit
    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
        // Set activation policy at global level before creating any UI components
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

