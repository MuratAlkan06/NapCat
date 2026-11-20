import SwiftUI

/// One received alert: lane glyph + lane label + relative time, then the
/// Mac's message. The lane's severity tints the glyph only; the glyph's shape
/// and the label carry the meaning (never color alone), and VoiceOver hears
/// the severity first: "Warning: Lid alert, 41 minutes ago. This Mac …".
struct AlertRow: View {
    let alert: PhoneAlert

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 24

    var body: some View {
        // Periodic from now (not `.everyMinute`, whose dates sit on minute
        // boundaries and so read up to a minute early).
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {
                Image(systemName: alert.lane.symbol)
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .font(theme.metaFont)
                    .foregroundStyle(glyphTint)
                    .frame(width: glyphColumn)
                VStack(alignment: .leading, spacing: theme.innerGap) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.innerGap) {
                        Text(alert.lane.title)
                            .font(theme.metaFont)
                            .foregroundStyle(theme.ink)
                        Spacer(minLength: theme.innerGap)
                        Text(Self.relative(alert.firedAt, to: context.date, style: .short))
                            .font(theme.timestampFont)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    Text(alert.body)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(now: context.date))
        }
    }

    private var glyphTint: Color {
        alert.lane.severity == .nominal ? theme.accent : theme.tint(for: alert.lane.severity)
    }

    private func spoken(now: Date) -> String {
        let when = Self.relative(alert.firedAt, to: now, style: .full)
        return PhoneLine(text: "\(alert.lane.title), \(when). \(alert.body)", severity: alert.lane.severity).spoken
    }

    /// "2 min. ago", "yesterday" (named where natural).
    static func relative(_ date: Date, to now: Date, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
