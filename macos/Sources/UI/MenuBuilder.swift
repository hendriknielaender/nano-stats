import AppKit

/// Responsible for building and configuring menu items
final class MenuBuilder {
  private let menu: NSMenu

  init(menu: NSMenu) {
    self.menu = menu
  }

  /// Adds a disabled menu item with the specified title
  func addDisabledMenuItem(title: String) {
    let menu_item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menu_item.isEnabled = false
    menu.addItem(menu_item)
  }

  /// Adds a separator to the menu
  func addSeparator() {
    menu.addItem(NSMenuItem.separator())
  }

  /// Adds a quit item to the menu
  func addQuitItem(title: String = "Quit NanoStats") {
    let quit_item = NSMenuItem(
      title: title,
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quit_item.target = NSApp
    menu.addItem(quit_item)
  }

  /// Formats a memory value using the provided formatter
  func formatMemory(_ bytes: Int64, with formatter: ByteCountFormatter) -> String {
    return formatter.string(fromByteCount: bytes)
  }

  /// Creates a standard ByteCountFormatter for memory display
  func createMemoryFormatter() -> ByteCountFormatter {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .memory
    formatter.zeroPadsFractionDigits = false
    formatter.isAdaptive = true
    return formatter
  }
}
