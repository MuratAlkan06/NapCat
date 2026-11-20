import SwiftUI
import UIKit

/// The style variants offered for the owner's pick (#71). The screen is
/// written once against `Theme`; a variant is nothing but a `Theme` value.
/// Applying the pick is a small change: point `fallback` at the chosen case,
/// then delete the other two `Theme` statics, their cases and the
/// `-NapCatTheme` launch argument.
enum ThemeID: String, CaseIterable, Sendable {
    case nightGroom
    case systemPaper
    case pixelNap

    /// The variant used when none (or an unknown one) is requested.
    static let fallback: ThemeID = .systemPaper

    var theme: Theme {
        switch self {
        case .nightGroom: return .nightGroom
        case .systemPaper: return .systemPaper
        case .pixelNap: return .pixelNap
        }
    }
}

/// How the screen is framed.
enum ListChrome: Sendable, Equatable {
    /// The system inset-grouped `List` under a large navigation title: system
    /// backgrounds, separators and row chrome.
    case insetGrouped
    /// Themed cards on the theme's own ground, in a plain vertical scroll
    /// (system scroll physics), with an in-content title.
    case cards
}

/// How the empty state's cat is drawn. Every treatment uses the
/// repository's own art only (see `RepoArt`).
enum EmptyArtTreatment: Sendable, Equatable {
    /// The grooming cat (art/groom-source.png), the whole drawing, large and
    /// faint, behind the message.
    case groomWatermark(height: CGFloat)
    /// The grooming cat as a monochrome line drawing above the message.
    case groomGlyph(height: CGFloat)
    /// The menu-bar idle cycle (Resources/frames/idle*@2x.png), nearest-
    /// neighbour at `pointsPerPixel`, flipped through once from groom to sit
    /// at `frameMilliseconds` per frame (one pass, then it rests).
    case pixelFlip(pointsPerPixel: CGFloat, frameMilliseconds: Int)
}

/// Every styling decision on the receiver screen. Views read ONLY these
/// tokens. No view hard-codes a color, font, spacing, surface, icon variant,
/// art treatment or entrance curve. The stagger cadence (40 ms per row, first
/// eight rows) is product behaviour, not style, and lives in `StaggerTiming`.
struct Theme: Sendable {
    let id: ThemeID
    let displayName: String

    // MARK: Color (each adapts to light and dark)

    /// The screen background (cards chrome).
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
    /// The empty-state cat.
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

    let chrome: ListChrome
    /// Horizontal screen margin (cards chrome).
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
