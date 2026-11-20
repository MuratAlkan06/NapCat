import CoreGraphics
@testable import NapCatPhone
import SwiftUI
import Testing

/// The theme seam: the owner's pick, Pixel Nap, as one complete `Theme` value.
@Suite struct ThemeTests {
    @Test func pixelNapIsTheOnlyStyle() {
        #expect(ThemeID.allCases == [.pixelNap])
        #expect(ThemeID.fallback == .pixelNap)
        #expect(ThemeID.pixelNap.theme.id == .pixelNap)
    }

    /// Charter: the entrance spring stays at or under 0.3 s.
    @Test(arguments: ThemeID.allCases)
    func theEntranceSpringIsAtMostThreeTenths(_ id: ThemeID) {
        let theme = id.theme
        #expect(theme.entranceDuration > 0 && theme.entranceDuration <= 0.3)
        #expect(theme.entranceBounce >= 0 && theme.entranceBounce < 0.3)
        #expect(theme.entranceOffset > 0)
    }

    /// The owner's hybrid pick: the empty state is Night Groom's large
    /// grooming-cat watermark behind the message, not the pixel sprite.
    @Test func theEmptyStateWatermarksTheGroomingCat() {
        switch Theme.pixelNap.emptyArt {
        case .groomWatermark(let height):
            #expect(height >= 256, "the watermark is large, behind the message")
        }
    }

    /// A watermark stays faint in both schemes, so the message over it reads.
    @Test(arguments: [ColorScheme.light, .dark])
    func theWatermarkIsFaintInEachScheme(_ scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let opacity = Theme.pixelNap.artTint.resolve(in: environment).opacity
        #expect(opacity > 0 && opacity <= 0.2, "\(scheme) watermark opacity \(opacity)")
    }

    /// Pixel Nap keeps an 8 pt rhythm: every spacing token is a multiple of 8.
    @Test func pixelNapSpacingIsOnTheEightPointRhythm() {
        let theme = Theme.pixelNap
        let insets = theme.pillInsets
        let spacings: [CGFloat] = [theme.margin, theme.rowPadding, theme.rowGap, theme.innerGap,
                                   insets.top, insets.leading, insets.bottom, insets.trailing]
        for spacing in spacings {
            #expect(spacing.truncatingRemainder(dividingBy: 8) == 0, "\(spacing) is off the 8 pt rhythm")
        }
        #expect(theme.cornerRadius == 0 && theme.pillCornerRadius == 0)
    }
}
