import SwiftUI
import UIKit

/// The receiver's style. The owner picked Pixel Nap (#71), with Night
/// Groom's grooming-cat watermark as its empty state; the other variants
/// were removed. The screen is written once against `Theme`, so a style is
/// nothing but a `Theme` value.
enum ThemeID: String, CaseIterable, Sendable {
    case pixelNap

    /// The style the screen uses.
    static let fallback: ThemeID = .pixelNap

    var theme: Theme {
        switch self {
        case .pixelNap: return .pixelNap
        }
    }
}

/// How the empty state's cat is drawn. It uses the repository's own art
/// only (see `RepoArt`).
enum EmptyArtTreatment: Sendable, Equatable {
    /// The grooming cat (art/groom-source.png), the whole drawing, large and
    /// faint, behind the message.
    case groomWatermark(height: CGFloat)
}

/// Every styling decision on the receiver screen. Views read ONLY these
/// tokens. No view hard-codes a color, font, spacing, surface, icon variant,
/// art treatment or entrance curve. The stagger cadence (40 ms per row, first
/// eight rows) is product behaviour, not style, and lives in `StaggerTiming`.
struct Theme: Sendable {
    let id: ThemeID
    let displayName: String

    // MARK: Color (each adapts to light and dark)

    /// The screen background.
    let ground: Color
    /// Card and pill fill.
    let surface: Color
    /// Primary text.
    let ink: Color
    /// Secondary text and timestamps.
    let inkSecondary: Color
    /// The one accent: tint, nominal glyphs.
    let accent: Color
    /// Card borders and hard shadows.
    let hairline: Color
    /// The connection pill's fill.
    let pillFill: Color
    /// The empty-state cat. A watermark, so it stays faint in both schemes
    /// (its alpha is part of the token).
    let artTint: Color
    /// Severity tints. Always paired with a glyph and text, never alone.
    let warning: Color
    let error: Color

    // MARK: Type

    let titleFont: Font
    let sectionFont: Font
    let bodyFont: Font
    /// The lane label on a row ("Session alert").
    let metaFont: Font
    /// Secondary explanatory text (the permission row's detail).
    let detailFont: Font
    let timestampFont: Font
    let pillFont: Font
    let emptyFont: Font

    // MARK: Surfaces and rhythm

    /// Horizontal screen margin.
    let margin: CGFloat
    /// Padding inside a card.
    let rowPadding: CGFloat
    /// Gap between cards / blocks.
    let rowGap: CGFloat
    /// Gap between elements inside a row.
    let innerGap: CGFloat
    let pillInsets: EdgeInsets
    let cornerRadius: CGFloat
    let pillCornerRadius: CGFloat
    let borderWidth: CGFloat
    /// Offset of a blur-free shadow; 0 = no shadow.
    let hardShadow: CGFloat

    // MARK: Icon family

    let symbolVariant: SymbolVariants
    let symbolWeight: Font.Weight

    // MARK: Art

    let emptyArt: EmptyArtTreatment

    // MARK: Motion

    /// The per-row entrance spring: duration (kept at or under 0.3 s) and
    /// bounce (0 = critically damped, the system's `.smooth`).
    let entranceDuration: TimeInterval
    let entranceBounce: Double
    /// How far a row rises while it fades in.
    let entranceOffset: CGFloat

    var entrance: Animation { .spring(duration: entranceDuration, bounce: entranceBounce) }

    /// A severity's tint. Nominal and info share the secondary ink, as on
    /// the Mac panel.
    func tint(for severity: PhoneSeverity) -> Color {
        switch severity {
        case .nominal, .info: return inkSecondary
        case .warning: return warning
        case .error: return error
        }
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = ThemeID.fallback.theme
}

extension Color {
    /// A color that follows the interface style: sRGB `0xRRGGBB` per mode.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark, alpha: darkAlpha)
                : UIColor(rgb: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}
