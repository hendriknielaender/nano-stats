import AppKit

/// Application delegate for handling application lifecycle events
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: NanoStatsApp?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the app with a title
        app = NanoStatsApp(withTitle: "NanoStats")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources
        app?.cleanup()
        app = nil
    }
}

