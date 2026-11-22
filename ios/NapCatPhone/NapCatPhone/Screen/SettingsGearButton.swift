import SwiftUI

/// The main screen's way to Settings: a gear in the toolbar's trailing
/// corner (the Mac panel's settings glyph). Icon only on screen; VoiceOver
/// reads "Settings".
struct SettingsGearButton: View {
    nonisolated static let symbol = "gearshape"

    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Label(SettingsScreen.title, systemImage: Self.symbol)
                .symbolVariant(theme.symbolVariant)
                .fontWeight(theme.symbolWeight)
        }
        .tint(theme.accent)
    }
}
