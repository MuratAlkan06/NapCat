import SwiftUI

extension Theme {
    /// Night Groom: the app icon's night. A deep navy ground, a moonlit
    /// accent and cream ink. It is designed dark-first, with a derived light
    /// mode (the site's light hero wash, navy ink, the AA navy accent). The
    /// grooming cat sits behind the empty state as a large, faint watermark.
    /// Timestamps use monospaced digits.
    static var nightGroom: Theme {
        Theme(
            id: .nightGroom,
            displayName: "Night Groom",
            ground: Color(light: 0xEDF0F7, dark: 0x10213F),
            surface: Color(light: 0xFFFFFF, dark: 0x182C52),
            ink: Color(light: 0x10213F, dark: 0xECE9E3),
            inkSecondary: Color(light: 0x56607A, dark: 0xA9B3C6),
            accent: Color(light: 0x2C4896, dark: 0x7EA6EC),
            hairline: Color(light: 0xD5DBE8, dark: 0x24395F),
            pillFill: Color(light: 0xDCE3F3, dark: 0x1D3560),
            artTint: Color(light: 0x2C4896, dark: 0x7EA6EC, lightAlpha: 0.08, darkAlpha: 0.10),
            warning: Color(light: 0x8F5300, dark: 0xF2B35D),
            error: Color(light: 0xB3261E, dark: 0xF2877C),
            titleFont: .system(.largeTitle, design: .rounded, weight: .bold),
            sectionFont: .system(.footnote, design: .rounded, weight: .semibold),
            bodyFont: .body,
            metaFont: .system(.subheadline, design: .rounded, weight: .semibold),
            detailFont: .subheadline,
            timestampFont: .subheadline.monospacedDigit(),
            pillFont: .system(.subheadline, design: .rounded, weight: .semibold),
            emptyFont: .system(.title3, design: .rounded, weight: .semibold),
            chrome: .cards,
            margin: 16,
            rowPadding: 16,
            rowGap: 12,
            innerGap: 6,
            pillInsets: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12),
            cornerRadius: 18,
            pillCornerRadius: 999,
            borderWidth: 0,
            hardShadow: 0,
            symbolVariant: .fill,
            symbolWeight: .semibold,
            emptyArt: .groomWatermark(height: 340),
            entranceDuration: 0.3,
            entranceBounce: 0.12,
            entranceOffset: 10
        )
    }
}
