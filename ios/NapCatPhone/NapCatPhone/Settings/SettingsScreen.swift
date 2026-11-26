import SwiftUI

/// Settings: one standard grouped Form in the current palette.
///
/// - Appearance picks the palette. A palette changes colors only, and the
///   whole app (this screen included) redraws in it at once.
/// - Notifications shows whether the iPhone may buzz, with the way to this
///   app's page in the system's notification settings.
/// - Pairing (F4 slice S-PAIR-C1.6, #172): Pair with Mac opens the pairing
///   screen as a sheet over Settings, a new ceremony each time, and only on
///   the owner's tap. Shown only when the launch has a live pairing (a
///   request fixture launch, and previews, have none).
/// - Remote approvals (F4, #194), under Pairing and shown with it: the
///   phone's own switch (`ApprovalsSwitch`), off by default. It follows the
///   phone's pairing, read through the live pairing as the screen draws: on
///   a paired phone it shows and sets the stored choice it is handed and
///   nothing else (the root hands it to the inbox, and nothing tells the
///   Mac); on an unpaired one it shows off, a stored on included, cannot be
///   set, its label dims to the secondary ink as the switch does, and its
///   footer says to pair first.
/// - About shows the running build, read from the bundle, and the project
///   site.
///
/// It works only on what it is handed and on the bundle's Info.plist: no
/// iCloud, no network of its own (the pairing it opens writes its one
/// record through the live pairing it is handed). Every color and font is a
/// theme token.
struct SettingsScreen: View {
    nonisolated static let title = "Settings"
    nonisolated static let done = "Done"
    nonisolated static let appearanceHeader = "Appearance"
    nonisolated static let paletteLabel = "Palette"
    nonisolated static let paletteFooter = "Changes colors only. Each palette follows your iPhone's light or dark appearance."
    nonisolated static let notificationsHeader = "Notifications"
    nonisolated static let statusLabel = "Status"
    nonisolated static let pairingHeader = "Pairing"
    nonisolated static let pairTitle = PairingScreen.title
    /// Names both of the Mac's buttons (a paired Mac shows Pair a New
    /// iPhone…), says the pane is NapCat's own, and names the biometric
    /// that comes with the scan: this phone's own (#175: a Touch ID phone
    /// read Face ID), or, on a phone with none, biometrics.
    nonisolated static func pairingFooter(_ biometric: BiometryKind?) -> String {
        let name: String = biometric?.name ?? "biometrics"
        return "On your Mac, choose Pair iPhone… or Pair a New iPhone… in NapCat's Settings › Claude, "
            + "then scan the code it shows and confirm with \(name)."
    }
    nonisolated static let approvalsHeader = "Remote approvals"
    nonisolated static let approvalsLabel = "Prompts on This iPhone"
    /// What the switch does today, on a paired phone: the prompts are listed
    /// and announced here; answering from here is not on yet.
    nonisolated static let approvalsPairedFooter = "Shows permission prompts from your paired Mac and notifies you "
        + "when one is waiting. You can't answer from iPhone yet — answer on your Mac."
    /// On an unpaired phone, whose switch is off and cannot be set: pairing
    /// comes first, in the row above.
    nonisolated static let approvalsUnpairedFooter = "Pair this iPhone with your Mac above to see its permission prompts here."

    /// The footer for the phone's pairing as it stands.
    nonisolated static func approvalsFooter(for keyHealth: PhoneKeyring.Health) -> String {
        ApprovalsSwitch.isCommitted(keyHealth) ? approvalsPairedFooter : approvalsUnpairedFooter
    }

    /// The switch as the row shows and sets it: the stored choice on a
    /// phone with a committed key; off on any other, whatever is stored,
    /// and nothing set there is kept (the row is disabled there too).
    static func shownSwitch(_ stored: Binding<Bool>, keyHealth: PhoneKeyring.Health) -> Binding<Bool> {
        Binding(get: { ApprovalsSwitch.effective(stored: stored.wrappedValue, keyHealth: keyHealth) },
                set: { if ApprovalsSwitch.isCommitted(keyHealth) { stored.wrappedValue = $0 } })
    }
    nonisolated static let aboutHeader = "About"
    nonisolated static let versionLabel = "Version"
    nonisolated static let siteLabel = "Website"
    nonisolated static let siteURL = URL(string: "https://muratalkan06.github.io/NapCat/")

    @Binding var palette: PaletteID
    let notifications: NotificationPermission
    /// The launch's live pairing, if it has one.
    var pairing: LivePairing?
    /// The owner's remote-approvals switch, as the root keeps it.
    @Binding var approvals: Bool
    var version = AppVersion(bundle: .main)

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// The ceremony the pairing sheet runs: a new one for each tap. It is
    /// the sheet's item (#178): the sheet is up exactly while there is one,
    /// and its content is handed that ceremony, so it never opens blank.
    @State private var ceremony: PairingCeremony?

    var body: some View {
        NavigationStack {
            Form {
                appearance
                notificationsSection
                if let pairing {
                    pairingSection(pairing)
                    approvalsSection(pairing.health())
                }
                about
            }
            .scrollContentBackground(.hidden)
            .background(theme.ground.ignoresSafeArea())
            .font(theme.bodyFont)
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Self.done) { dismiss() }
                }
            }
        }
        .tint(theme.accent)
        .sheet(item: $ceremony) { ceremony in
            if let pairing { PairingSheet(ceremony: ceremony, camera: pairing.camera) }
        }
    }

    // MARK: Sections

    private var appearance: some View {
        Section {
            Picker(Self.paletteLabel, selection: $palette) {
                ForEach(PaletteID.allCases) { option in
                    Text(option.displayName)
                        .foregroundStyle(theme.ink)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            header(Self.appearanceHeader)
        } footer: {
            footer(Self.paletteFooter)
        }
        .listRowBackground(theme.surface)
    }

    private var notificationsSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: theme.innerGap) {
                    if let glyph = notifications.line.severity.symbol {
                        Image(systemName: glyph)
                            .fontWeight(theme.symbolWeight)
                            .foregroundStyle(theme.tint(for: notifications.line.severity))
                    }
                    Text(notifications.line.text)
                        .foregroundStyle(theme.inkSecondary)
                }
            } label: {
                Text(Self.statusLabel)
                    .foregroundStyle(theme.ink)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.statusLabel)
            .accessibilityValue(notifications.line.spoken)

            NotificationSettingsButton(title: notifications.action)
        } header: {
            header(Self.notificationsHeader)
        } footer: {
            if let detail = notifications.detail {
                footer(detail)
            }
        }
        .listRowBackground(theme.surface)
    }

    /// One row: Pair with Mac, which opens a new ceremony's sheet.
    private func pairingSection(_ pairing: LivePairing) -> some View {
        Section {
            Button(Self.pairTitle) {
                ceremony = pairing.makeCeremony()
            }
        } header: {
            header(Self.pairingHeader)
        } footer: {
            footer(Self.pairingFooter(pairing.biometric()))
        }
        .listRowBackground(theme.surface)
    }

    /// One switch: the phone's own (#194), under Pairing, following the
    /// phone's pairing as it stands (`keyHealth`).
    private func approvalsSection(_ keyHealth: PhoneKeyring.Health) -> some View {
        Section {
            Toggle(isOn: Self.shownSwitch($approvals, keyHealth: keyHealth)) {
                Text(Self.approvalsLabel)
                    .foregroundStyle(ApprovalsSwitch.isCommitted(keyHealth) ? theme.ink : theme.inkSecondary)
            }
            .disabled(!ApprovalsSwitch.isCommitted(keyHealth))
        } header: {
            header(Self.approvalsHeader)
        } footer: {
            footer(Self.approvalsFooter(for: keyHealth))
        }
        .listRowBackground(theme.surface)
    }

    private var about: some View {
        Section {
            LabeledContent {
                Text(version.text)
                    .foregroundStyle(theme.inkSecondary)
            } label: {
                Text(Self.versionLabel)
                    .foregroundStyle(theme.ink)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.versionLabel)
            .accessibilityValue(version.spoken)

            if let site = Self.siteURL {
                Link(destination: site) {
                    LinkOutLabel(title: Self.siteLabel)
                }
            }
        } header: {
            header(Self.aboutHeader)
        }
        .listRowBackground(theme.surface)
    }

    // MARK: Type

    /// A section header, as the main screen's "Recent".
    private func header(_ text: String) -> some View {
        Text(text)
            .font(theme.sectionFont)
            .textCase(.uppercase)
            .foregroundStyle(theme.inkSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(theme.detailFont)
            .foregroundStyle(theme.inkSecondary)
    }
}

#Preview("Night Groom, notifications on") {
    @Previewable @State var palette = PaletteID.nightGroom
    SettingsScreen(palette: $palette, notifications: .on, approvals: .constant(false))
        .environment(\.theme, ThemeID.fallback.theme(palette: palette))
}

#Preview("Deep Cream, notifications off") {
    @Previewable @State var palette = PaletteID.deepCream
    SettingsScreen(palette: $palette, notifications: .off, approvals: .constant(false))
        .environment(\.theme, ThemeID.fallback.theme(palette: palette))
}
