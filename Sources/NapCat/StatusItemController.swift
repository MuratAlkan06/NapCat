import AppKit

/// Creates and owns the NSStatusItem and its menu.
/// Phase 1: static placeholder template icon. Real animated pixel-art cat
/// frames arrive in Phase 4 (AnimationEngine).
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menuContent: MenuContentView

    init(menuContent: MenuContentView) {
        self.menuContent = menuContent
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.placeholderIcon()
        statusItem.menu = menuContent.menu
    }

    /// Simple cat-ish silhouette (head + two ears) drawn in code at 18x18pt.
    /// Template image (black + alpha) so the system tints it for the menu bar.
    /// Internal (not private) so tests can inspect it.
    static func placeholderIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let head = NSBezierPath(ovalIn: NSRect(x: 3, y: 2, width: 12, height: 11))

            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 4, y: 9))
            leftEar.line(to: NSPoint(x: 5, y: 16))
            leftEar.line(to: NSPoint(x: 9, y: 12))
            leftEar.close()

            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 14, y: 9))
            rightEar.line(to: NSPoint(x: 13, y: 16))
            rightEar.line(to: NSPoint(x: 9, y: 12))
            rightEar.close()

            NSColor.black.setFill()
            head.fill()
            leftEar.fill()
            rightEar.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
