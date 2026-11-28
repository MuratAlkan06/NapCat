import SwiftUI

/// The Settings window's SwiftUI content (Panel 2.0 slice W, issue #78),
/// hosted by `SettingsWindowController`. It renders the pane the toolbar
/// selected as a grouped form, row by row from the model's composition
/// (`MenuStateModel.settingsContent(for:)`, SettingsContent.swift) — the views
/// decide arrangement only, never what a row says or how loud it is. System
/// materials, semantic colors and the panel's shared components only.
///
/// Fixed width (`SettingsMetrics.width`), height fitted to the pane: the form
/// does not scroll and its ideal height is the window's content height, so a
/// pane switch or a caption appearing resizes the window (snap — no motion).
/// The window's one motion is a button's press (`SettingsPressButtonStyle`).
struct SettingsRootView: View {
    @ObservedObject var model: MenuStateModel
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        SettingsPaneView(model: model, content: model.settingsContent(for: selection.pane,
                                                                      now: Date().timeIntervalSince1970))
            // A fresh identity per pane, so no row state carries across tabs.
            .id(selection.pane)
    }
}

enum SettingsMetrics {
    /// The window's fixed content width.
    static let width: CGFloat = 440
    /// The bordered buttons' bezel (`SettingsPressButtonStyle.Look.bezel`,
    /// issue #86): the native regular push button's footprint, measured on
    /// macOS 27.2.1 — a fixed 24 pt tall, the width the label's plus this
    /// padding on each side ("Send test message": 140 × 24 pt, the system
    /// button's own frame). A press squashes the drawing only; the layout
    /// never moves.
    static let bezelHeight: CGFloat = 24
    static let bezelPadding: CGFloat = 12
}

/// One pane: its sections in order, the footnote under the last one.
struct SettingsPaneView: View {
    @ObservedObject var model: MenuStateModel
    let content: SettingsPaneContent

    var body: some View {
        Form {
            ForEach(Array(content.sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        SettingsRowView(model: model, row: row)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                } footer: {
                    if index == content.sections.count - 1, let footnote = content.footnote {
                        Text(footnote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row. Controls render the state the row carries and forward to the
/// model — the same actions the panel's controls forward to.
struct SettingsRowView: View {
    @ObservedObject var model: MenuStateModel
    let row: SettingsRow

    var body: some View {
        switch row {
        case let .launchAtLogin(isOn, caption, showsSettingsShortcut):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { isOn },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                if let caption {
                    PanelCaptionLine(line: caption)
                }
                if showsSettingsShortcut {
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                        .buttonStyle(SettingsPressButtonStyle(look: .link))
                        .font(.caption)
                }
            }
        case let .chargeLimit(header, isOn, switchEnabled, limit, sliderEnabled, caption):
            VStack(alignment: .leading, spacing: PanelMetrics.regular) {
                HStack {
                    Text(header)
                        .monospacedDigit()
                    Spacer(minLength: PanelMetrics.regular)
                    Toggle("Charge Limit", isOn: Binding(
                        get: { isOn },
                        set: { model.setLimitEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!switchEnabled)
                }
                Slider(
                    value: Binding(
                        get: { Double(limit) },
                        set: { model.setLimit(Int($0.rounded())) }
                    ),
                    in: 50...100,
                    step: Double(ChargeLimiter.limitStep)
                ) {
                    Text("Charge limit")
                } minimumValueLabel: {
                    Text("50%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("100%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .labelsHidden()
                .disabled(!sliderEnabled)
                .accessibilityValue(header)
                if let caption {
                    PanelCaptionLine(line: caption)
                }
            }
        case let .note(text):
            // A fact, not a control: the Lock Screen line's look (body,
            // secondary) with the panel's info glyph beside it, `tight` apart
            // like a caption line. Nothing here takes focus or acts.
            HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {
                Image(systemName: PanelSymbol.info)
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
        case let .line(line):
            PanelCaptionLine(line: line, font: .body)
        case .ntfyButtons:
            HStack(spacing: PanelMetrics.regular) {
                // The existing hardened editor (masked topic, server,
                // validation), presented through MenuContentView.
                Button("ntfy settings…") { model.editLidGuardSettings() }
                SendFeedbackButton(model: model, controlSize: .regular)
            }
            .buttonStyle(SettingsPressButtonStyle(look: .bezel))
        case let .minimumRun(label, seconds, choices, caption):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Picker(label, selection: Binding(
                    get: { seconds },
                    set: { model.setFinishAlertMinimumRunSeconds($0) }
                )) {
                    ForEach(choices, id: \.self) { choice in
                        Text(MenuStateModel.sessionAlertsFloorText(seconds: choice)).tag(choice)
                    }
                }
                .accessibilityLabel(MenuStateModel.sessionAlertsFloorAccessibilityLabel)
                // Issue #242: the caption follows the floor, and the
                // "Immediately" one is long — it wraps, like the other
                // captions here, rather than truncate.
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .phoneAlerts(title, isOn, hint):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Toggle(title, isOn: Binding(
                    get: { isOn },
                    set: { model.setPhoneTransportEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .pauseDetection(isOn, caption):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Toggle("Pause detection", isOn: Binding(
                    get: { isOn },
                    set: { model.setDetectionPaused($0) }
                ))
                .toggleStyle(.switch)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .updateCheck(checking, caption):
            // Issue #111: the caption is passive text; the button is the
            // window's bezel button, disabled while a check is out.
            HStack(spacing: PanelMetrics.regular) {
                Text(caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Check for Updates…") { model.checkForUpdates() }
                    .buttonStyle(SettingsPressButtonStyle(look: .bezel))
                    .disabled(checking)
            }
        case let .updateAuto(isOn, disclosure):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { isOn },
                    set: { model.setUpdateCheckAutoEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .remoteApprovals(isOn, caption, hint):
            // F4 slice S2: the panel row's twin — the same model action.
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Toggle(MenuStateModel.remoteApprovalsSettingsToggleTitle, isOn: Binding(
                    get: { isOn },
                    set: { model.setRemoteApprovalsEnabled($0) }
                ))
                .toggleStyle(.switch)
                if let caption {
                    PanelCaptionLine(line: caption)
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .pairingStatus(line, fingerprint, hint):
            // S-PAIR-C1 (#168): the line, the paired code (selectable,
            // monospaced, spoken one character at a time), and the hint.
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                PanelCaptionLine(line: line, font: .body)
                if let fingerprint {
                    PairingCodeText(fingerprint: fingerprint, font: .body)
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .pairingButtons(paired, retry):
            // #240: after a refused Unpair, Try Again comes first.
            HStack(spacing: PanelMetrics.regular) {
                if retry {
                    Button(MenuStateModel.unpairRetryButtonTitle) { model.retryUnpair() }
                        .accessibilityLabel(MenuStateModel.unpairRetryAccessibilityLabel)
                }
                Button(paired ? MenuStateModel.pairNewButtonTitle : MenuStateModel.pairButtonTitle) { model.beginPairing() }
                if paired {
                    Button(MenuStateModel.unpairButtonTitle) { model.unpair() }
                }
            }
            .buttonStyle(SettingsPressButtonStyle(look: .bezel))
        case let .hookInstall(intro, command, note):
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Text(intro)
                    .fixedSize(horizontal: false, vertical: true)
                // Selectable, so the command can be copied as it is.
                Text(command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .approvalsAdvanced(title, intro, unavailable, switches, phone, never):
            // #252: no model here — nothing in the section can act.
            SettingsAdvancedSection(title: title, intro: intro, unavailable: unavailable, switches: switches,
                                    phone: phone, never: never)
        }
    }
}

/// #252: the Remote approvals group's Advanced section. Its button opens
/// and closes it: collapsed whenever the pane is built (the state is this
/// view's, in memory only), and with no motion — the chevron swaps and the
/// content shows or goes in one step; the button's press is the only
/// animation, as on every Settings button. VoiceOver hears the button's
/// title with "collapsed" or "expanded" as its value.
///
/// Open, the only words on screen are each control's label and the line
/// saying these stay on this Mac in this version. The rest sits behind
/// info circles (`info(_:)`), each holding its text in full as a tooltip
/// and as what VoiceOver reads: the intro's beside the title, what is
/// never sent at the end of the not-available line, and each control's
/// caption beside its label — outside the control, since a disabled view
/// shows no tooltip.
///
/// Every control inside is drawn disabled over its row's constant value:
/// a `.constant` binding, so there is no setter, and the view holds no
/// model; its label is dimmed to match.
struct SettingsAdvancedSection: View {
    let title: String
    let intro: String
    let unavailable: String
    let switches: [SettingsFixedToggle]
    let phone: SettingsFixedToggle
    let never: String
    @State private var expanded = false

    /// The chevron, swapped, never turned.
    static let collapsedSymbol = "chevron.right"
    static let expandedSymbol = "chevron.down"

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.regular) {
            HStack(spacing: PanelMetrics.tight) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: PanelMetrics.tight) {
                        Image(systemName: expanded ? Self.expandedSymbol : Self.collapsedSymbol)
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(title)
                    }
                }
                .buttonStyle(SettingsPressButtonStyle(look: .bezel))
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                info(intro)
            }
            if expanded {
                HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {
                    Image(systemName: PanelSymbol.info)
                        .accessibilityHidden(true)
                    Text(unavailable)
                        .fixedSize(horizontal: false, vertical: true)
                    info(never)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(switches, id: \.title) { kind in
                    HStack(spacing: PanelMetrics.tight) {
                        dimmed(kind.title)
                        info(kind.caption)
                        Spacer(minLength: PanelMetrics.regular)
                        Toggle(kind.title, isOn: .constant(kind.isOn))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(true)
                    }
                }
                HStack(spacing: PanelMetrics.tight) {
                    Toggle(isOn: .constant(phone.isOn)) { dimmed(phone.title) }
                        .toggleStyle(.checkbox)
                        .disabled(true)
                    info(phone.caption)
                }
            }
        }
    }

    /// An info circle: `text` in full as its tooltip and as its VoiceOver
    /// label (the panel's icon buttons pair `.help` and the label the same
    /// way). It is never disabled, so its tooltip shows.
    private func info(_ text: String) -> some View {
        Image(systemName: PanelSymbol.info)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
    }

    /// A disabled control's label: AppKit's disabled control text, as on
    /// a disabled system control's title (a switch's label stands beside
    /// it as plain text, which the disabled state does not reach).
    private func dimmed(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(Color(nsColor: .disabledControlTextColor))
    }
}

// MARK: - Press motion

/// Every Settings button's look plus the panel's quiet spring (issue #86,
/// owner pick "settings b"). The system `.bordered` and `.link` styles expose
/// no press state, so the window draws its own: a style gets
/// `configuration.isPressed` from SwiftUI itself — no gesture, no AppKit
/// tracking. While the pointer holds the button, the WHOLE button fades to
/// `PanelMotion.pressedOpacity` and squashes to `PanelMotion.widePressedScale`
/// over `PanelMotion.pressFade`, then springs back on release
/// (`PanelMotion.press` — the panel's one animation, scoped to those two
/// modifiers). Under Reduce Motion there is no squash and the fade snaps.
///
/// - `bezel` (ntfy settings…, Send test message): the card family's bezel —
///   `PanelMetrics.cardRadius` continuous corners, the card's fill
///   (`quaternarySystemFill` plus `PanelCard.boost`) and its `cardStroke`
///   separator hairline, no new color — in the native button's footprint
///   (`SettingsMetrics.bezelHeight` / `bezelPadding`). The tint does not
///   change on press: the motion is the feedback.
/// - `link` (Open Login Items Settings…): the system link color in the
///   label's own footprint, like `.link`, and its link role — a custom style
///   reads as a button (AXButton), so the look adds `.isLink` and external
///   accessibility clients read AXLink, as on `.link`. The pointer stays the
///   arrow, as on `.link` (macOS 27.2.1).
///
/// Disabled, the label takes AppKit's disabled control text, as a system
/// button's title does.
struct SettingsPressButtonStyle: ButtonStyle {
    enum Look {
        case bezel
        case link
    }

    let look: Look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        rest(configuration.label)
            .animation(PanelMotion.press(configuration.isPressed, reduceMotion: reduceMotion)) { button in
                button
                    .opacity(configuration.isPressed ? PanelMotion.pressedOpacity : 1)
                    .scaleEffect(configuration.isPressed && !reduceMotion ? PanelMotion.widePressedScale : 1)
            }
    }

    /// The button at rest, in its look.
    @ViewBuilder
    private func rest(_ label: Configuration.Label) -> some View {
        switch look {
        case .bezel:
            let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
            label
                .foregroundStyle(ink(.primary))
                .padding(.horizontal, SettingsMetrics.bezelPadding)
                .frame(height: SettingsMetrics.bezelHeight)
                .background {
                    ZStack {
                        shape.fill(Color(nsColor: .quaternarySystemFill))
                        shape.fill(PanelCard<EmptyView>.boost(colorScheme))
                    }
                }
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: PanelMetrics.cardStroke))
                // The whole bezel takes the click, and the keyboard focus
                // ring follows its corners.
                .contentShape([.interaction, .focusEffect], shape)
        case .link:
            label
                .foregroundStyle(ink(.link))
                .accessibilityAddTraits(.isLink)
        }
    }

    /// The label's color: its look's own, or — disabled ("Send test message"
    /// while no topic is set, and while "Sending…") — AppKit's disabled
    /// control text, as on a system button. A custom style is not dimmed for
    /// it.
    private func ink(_ enabled: some ShapeStyle) -> AnyShapeStyle {
        isEnabled ? AnyShapeStyle(enabled) : AnyShapeStyle(Color(nsColor: .disabledControlTextColor))
    }
}
