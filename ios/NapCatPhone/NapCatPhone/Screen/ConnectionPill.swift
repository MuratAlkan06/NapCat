import SwiftUI

/// Whether alerts can reach this iPhone, as a pill: a glyph and the state's
/// text (never color alone). VoiceOver hears the severity first:
/// "Warning: Notifications off".
struct ConnectionPill: View {
    let state: ConnectionState

    @Environment(\.theme) private var theme

    var body: some View {
        let line = state.line
        HStack(spacing: theme.innerGap) {
            Image(systemName: state.symbol)
                .symbolVariant(theme.symbolVariant)
                .fontWeight(theme.symbolWeight)
                .foregroundStyle(line.severity == .nominal ? theme.accent : theme.tint(for: line.severity))
            Text(line.text)
                .foregroundStyle(theme.ink)
        }
        .font(theme.pillFont)
        .padding(theme.pillInsets)
        .background {
            ThemedSurface(fill: theme.pillFill, cornerRadius: theme.pillCornerRadius, castsShadow: false)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spoken)
    }
}
