import SwiftUI
import UIKit

/// The peak-end hero: no alerts is the good outcome, so the empty list ends
/// on the cat and one calm sentence.
struct EmptyStateView: View {
    nonisolated static let message = "No alerts. Your Mac hasn't needed you."

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch theme.emptyArt {
            case .groomWatermark(let height):
                ZStack {
                    GroomArt(rendering: .drawing)
                        .frame(height: height)
                    messageText
                }
            case .groomGlyph(let height):
                VStack(spacing: theme.innerGap * 4) {
                    GroomArt(rendering: .line)
                        .frame(height: height)
                    messageText
                }
            case .pixelFlip(let pointsPerPixel, let frameMilliseconds):
                VStack(spacing: theme.innerGap * 4) {
                    PixelCatFlip(pointsPerPixel: pointsPerPixel, frameMilliseconds: frameMilliseconds)
                    messageText
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.message)
    }

    private var messageText: some View {
        Text(Self.message)
            .font(theme.emptyFont)
            .foregroundStyle(theme.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.innerGap * 4)
    }
}

extension Image {
    /// The repository's art is bundled as loose PNGs (no asset catalog), which
    /// `UIImage(named:)` resolves (including the @2x frames) and SwiftUI's
    /// `Image(_:)` does not.
    init(repoArt name: String) {
        self.init(uiImage: UIImage(named: name) ?? UIImage())
    }
}

/// The grooming cat (art/groom-source.png) in the theme's art tint: its line
/// work alone, or the whole drawing (the filled shape with the line work
/// drawn over it in the same tint, so the lines read darker).
struct GroomArt: View {
    enum Rendering { case line, drawing }
    let rendering: Rendering

    @Environment(\.theme) private var theme

    var body: some View {
        switch rendering {
        case .line:
            lineWork
        case .drawing:
            ZStack {
                Image(repoArt: RepoArt.groom)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.artTint)
                lineWork
            }
        }
    }

    /// The drawing is black line over grey fill on a clear ground. Laid on
    /// white and inverted, the ground goes black, the fill near-black and the
    /// line white, so its luminance masks the tint down to the line work.
    private var lineWork: some View {
        theme.artTint
            .mask {
                ZStack {
                    Color.white
                    Image(repoArt: RepoArt.groom)
                        .resizable()
                        .scaledToFit()
                }
                .compositingGroup()
                .colorInvert()
                .luminanceToAlpha()
            }
            .aspectRatio(1, contentMode: .fit)
    }
}

/// The menu-bar idle cycle, nearest-neighbour scaled: it flips through once,
/// grooming to settled, on each appearance, then rests on the settled frame.
/// Under Reduce Motion it shows the settled frame only.
struct PixelCatFlip: View {
    let pointsPerPixel: CGFloat
    let frameMilliseconds: Int

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = RepoArt.idleFrames.lowerBound

    var body: some View {
        let side = RepoArt.idleFramePixels * pointsPerPixel
        Image(repoArt: RepoArt.idleFrameName(reduceMotion ? RepoArt.idleSettledFrame : frame))
            .renderingMode(.template)
            .interpolation(.none)
            .resizable()
            .frame(width: side, height: side)
            .foregroundStyle(theme.artTint)
            .task {
                guard !reduceMotion else { return }
                for index in RepoArt.idleFrames {
                    frame = index
                    do {
                        try await Task.sleep(for: .milliseconds(frameMilliseconds))
                    } catch {
                        frame = RepoArt.idleSettledFrame
                        return
                    }
                }
            }
    }
}
