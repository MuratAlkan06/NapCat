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
                    GroomArt()
                        .frame(height: height)
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

/// The grooming cat (art/groom-source.png) in the theme's art tint, the whole
/// drawing: the filled shape with the line work drawn over it in the same
/// tint, so the lines read darker.
struct GroomArt: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Image(repoArt: RepoArt.groom)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.artTint)
            lineWork
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
