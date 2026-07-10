import AppKit
import Combine
import os

/// Creates and owns the NSStatusItem and its menu, and drives the animated
/// pixel-art cat icon through AnimationEngine (P4). If the frame PNGs are
/// missing from the bundle, the P1 placeholder icon stays and no animation
/// runs — the app remains fully functional.
@MainActor
final class StatusItemController {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "statusitem")

    private let statusItem: NSStatusItem
    private let menuContent: MenuContentView
    /// nil when the bundle lacks Resources/frames (placeholder fallback).
    private(set) var animationEngine: AnimationEngine?
    private var cancellables: Set<AnyCancellable> = []

    init(menuContent: MenuContentView) {
        self.menuContent = menuContent
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.placeholderIcon()
        statusItem.menu = menuContent.menu

        guard
            let framesDirectory = Bundle.main.resourceURL?
                .appendingPathComponent("frames", isDirectory: true),
            let frames = Self.loadFrameImages(from: framesDirectory)
        else {
            Self.logger.error("frame PNGs missing from bundle Resources/frames — keeping the static placeholder icon")
            return
        }

        let engine = AnimationEngine()
        animationEngine = engine
        engine.onFrame = { [weak self] set, index in
            guard let images = frames[set], images.indices.contains(index) else { return }
            self?.statusItem.button?.image = images[index]
        }
        engine.start()

        // The icon renders from the SAME observed state the menu shows
        // (MenuStateModel's published mirrors, ADR §6): observed pmset state
        // drives run, ChargeLimiter featureState == .paused drives sit
        // (locked mapping, 2026-07-09). Unknown observed state (nil) is
        // never guessed as active.
        menuContent.model.$stayAwakeObserved
            .combineLatest(menuContent.model.$featureState)
            .sink { [weak engine] observed, feature in
                MainActor.assumeIsolated {
                    engine?.setAppState(
                        stayAwakeOn: observed == true,
                        chargePaused: feature == .paused
                    )
                }
            }
            .store(in: &cancellables)
    }

    /// Loads every animation frame from a frames directory as an 18pt
    /// template image with @1x and @2x bitmap representations. ANY missing
    /// or undecodable file fails the whole load (nil → caller keeps the
    /// placeholder icon). Internal so tests can point it at the repo's
    /// Resources/frames.
    static func loadFrameImages(from directory: URL) -> [FrameSet: [NSImage]]? {
        let pointSize = NSSize(width: 18, height: 18)
        var result: [FrameSet: [NSImage]] = [:]
        for set in FrameSet.allCases {
            var images: [NSImage] = []
            for name in set.frameNames {
                guard
                    let data1x = try? Data(contentsOf: directory.appendingPathComponent("\(name).png")),
                    let rep1x = NSBitmapImageRep(data: data1x),
                    let data2x = try? Data(contentsOf: directory.appendingPathComponent("\(name)@2x.png")),
                    let rep2x = NSBitmapImageRep(data: data2x)
                else { return nil }
                // 18px and 36px backings both cover 18×18 points → 1x + 2x.
                rep1x.size = pointSize
                rep2x.size = pointSize
                let image = NSImage(size: pointSize)
                image.addRepresentation(rep1x)
                image.addRepresentation(rep2x)
                // Black + alpha template: the system tints it for the
                // menu bar in light/dark/selected states.
                image.isTemplate = true
                images.append(image)
            }
            result[set] = images
        }
        return result
    }

    /// Simple cat-ish silhouette (head + two ears) drawn in code at 18x18pt.
    /// Template image (black + alpha) so the system tints it for the menu bar.
    /// Kept as the fallback icon when the frame assets cannot be loaded.
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
