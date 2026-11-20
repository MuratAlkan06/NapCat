import CoreGraphics
@testable import NapCatPhone
import Testing

/// The theme seam: three variants, each a complete `Theme` value.
@Suite struct ThemeTests {
    /// The raw values are the `-NapCatTheme` launch-argument spellings.
    @Test func theVariantsAreTheThreeOnOffer() {
        #expect(ThemeID.allCases.map(\.rawValue) == ["nightGroom", "systemPaper", "pixelNap"])
    }

    @Test(arguments: ThemeID.allCases)
    func eachVariantResolvesToItsOwnTheme(_ id: ThemeID) {
        #expect(id.theme.id == id)
    }

    @Test func theFallbackIsSystemPaper() {
        #expect(ThemeID.fallback == .systemPaper)
    }

    /// Charter: the entrance spring stays at or under 0.3 s in every variant.
    @Test(arguments: ThemeID.allCases)
    func theEntranceSpringIsAtMostThreeTenths(_ id: ThemeID) {
        let theme = id.theme
        #expect(theme.entranceDuration > 0 && theme.entranceDuration <= 0.3)
        #expect(theme.entranceBounce >= 0 && theme.entranceBounce < 0.3)
        #expect(theme.entranceOffset > 0)
    }

    @Test func eachVariantFramesTheScreenItsOwnWay() {
        #expect(Theme.nightGroom.chrome == .cards)
        #expect(Theme.systemPaper.chrome == .insetGrouped)
        #expect(Theme.pixelNap.chrome == .cards)
    }

    @Test func eachVariantDrawsTheEmptyStateCatItsOwnWay() {
        guard case .groomWatermark = Theme.nightGroom.emptyArt else {
            Issue.record("Night Groom must watermark the grooming cat"); return
        }
        guard case .groomGlyph = Theme.systemPaper.emptyArt else {
            Issue.record("System Paper must draw the grooming cat as a glyph"); return
        }
        guard case .pixelFlip(let pointsPerPixel, let frameMilliseconds) = Theme.pixelNap.emptyArt else {
            Issue.record("Pixel Nap must flip the idle frames"); return
        }
        // The @2x frames at 2x, nearest-neighbour; one pass well under 5 s.
        #expect(pointsPerPixel == 2)
        #expect(frameMilliseconds * RepoArt.idleFrames.count < 5_000)
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
