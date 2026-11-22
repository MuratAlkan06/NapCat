import SwiftUI

/// One quiet line about the list, state word first: the severity's glyph
/// (when it has one) and the text, in the secondary ink. Never color alone;
/// VoiceOver hears the severity first: "Note: Couldn't check just now …".
struct CaptionLine: View {
    let line: PhoneLine

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.innerGap) {
            if let glyph = line.severity.symbol {
                Image(systemName: glyph)
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .foregroundStyle(theme.tint(for: line.severity))
            }
            Text(line.text)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.detailFont)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spoken)
    }
}
