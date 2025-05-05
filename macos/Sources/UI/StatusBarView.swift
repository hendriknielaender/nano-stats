import AppKit

/// Custom view for displaying memory usage in the status bar.
final class MemoryStatusView: NSView {
  private let ram_label = NSTextField()
  private let percentage_label = NSTextField()

  override init(frame: NSRect) {
    super.init(frame: frame)

    // Configure RAM label
    ram_label.isEditable = false
    ram_label.isBordered = false
    ram_label.isSelectable = false
    ram_label.drawsBackground = false
    ram_label.font = NSFont.systemFont(ofSize: 8)
    ram_label.textColor = NSColor.labelColor.withAlphaComponent(0.85)
    ram_label.alignment = .center
    ram_label.stringValue = "RAM"

    // Configure percentage label
    percentage_label.isEditable = false
    percentage_label.isBordered = false
    percentage_label.isSelectable = false
    percentage_label.drawsBackground = false
    percentage_label.font = NSFont.boldSystemFont(ofSize: 12)
    percentage_label.textColor = NSColor.labelColor.withAlphaComponent(0.85)
    percentage_label.alignment = .center
    percentage_label.stringValue = "0%"

    addSubview(ram_label)
    addSubview(percentage_label)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()

    let bounds = self.bounds
    ram_label.frame = NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10)
    percentage_label.frame = NSRect(x: 2, y: 0, width: bounds.width, height: bounds.height - 10)
  }

  func updatePercentage(_ percentage: Double) {
    percentage_label.stringValue = String(format: "%d%%", Int(round(percentage)))
  }
}
