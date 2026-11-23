import SwiftUI

/// An answer on the request screen, in Pixel Nap: a full-width card (the
/// theme's surface, border and hard shadow) holding a glyph and a label, in
/// the accent or the ink. At least 44 pt tall. Pressed, it dims at once;
/// nothing animates, so there is nothing to gate on Reduce Motion.
struct RequestButtonStyle: ButtonStyle {
    enum Emphasis: Sendable {
        case accent
        case ink
    }

    /// How far a pressed answer dims (a press, not a state: no contrast rule
    /// applies to it).
    static let pressedOpacity = 0.7

    let emphasis: Emphasis

    func makeBody(configuration: Configuration) -> some View {
        RequestButtonFace(label: configuration.label, isPressed: configuration.isPressed, emphasis: emphasis)
    }
}

private struct RequestButtonFace<Content: View>: View {
    let label: Content
    let isPressed: Bool
    let emphasis: RequestButtonStyle.Emphasis

    @Environment(\.theme) private var theme

    var body: some View {
        label
            .labelStyle(.titleAndIcon)
            .symbolVariant(theme.symbolVariant)
            .font(theme.metaFont)
            .foregroundStyle(emphasis == .accent ? theme.accent : theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, theme.rowPadding)
            .padding(.vertical, theme.innerGap)
            .background { ThemedSurface(fill: theme.surface, cornerRadius: theme.cornerRadius) }
            .contentShape(Rectangle())
            .opacity(isPressed ? RequestButtonStyle.pressedOpacity : 1)
    }
}
