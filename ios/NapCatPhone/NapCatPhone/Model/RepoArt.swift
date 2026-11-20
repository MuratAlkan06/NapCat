import CoreGraphics

/// The repository's own committed art, bundled in place by project.yml
/// (never copied, never redrawn here).
enum RepoArt {
    /// art/groom-source.png: the grooming cat drawing (transparent ground,
    /// grey fill, black line).
    static let groom = "groom-source"

    /// Resources/frames/idle0…16@2x.png: the menu-bar idle cycle, grooming
    /// (frame 0) through settling into a sit (frame 16). Template images:
    /// opaque cat, transparent detail lines.
    static let idleFrames = 0...16
    static let idleSettledFrame = 16
    /// The @2x frames are 42 × 42 px.
    static let idleFramePixels: CGFloat = 42

    static func idleFrameName(_ index: Int) -> String {
        "idle\(min(max(index, idleFrames.lowerBound), idleFrames.upperBound))"
    }
}
