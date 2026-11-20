import SwiftUI

/// The theme's one surface: fill, optional border, optional hard shadow.
/// Cards and the connection pill both use it, so the screen has a single
/// surface style.
struct ThemedSurface: View {
    let fill: Color
    let cornerRadius: CGFloat
    var castsShadow = true

    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if castsShadow && theme.hardShadow > 0 {
                shape.fill(theme.hairline).offset(x: theme.hardShadow, y: theme.hardShadow)
            }
            shape.fill(fill)
            if theme.borderWidth > 0 {
                shape.strokeBorder(theme.hairline, lineWidth: theme.borderWidth)
            }
        }
    }
}

/// A row as a card on the theme's ground (cards chrome).
struct ThemedCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(theme.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ThemedSurface(fill: theme.surface, cornerRadius: theme.cornerRadius) }
    }
}

extension View {
    func themedCard() -> some View { modifier(ThemedCard()) }
}
