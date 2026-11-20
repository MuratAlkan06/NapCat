import SwiftUI

/// Rich menu content (P3b user decision), hosted by a MenuPanelHostingView
/// inside a single NSMenuItem (MenuContentView). System materials and
/// semantic colors only — the menu chrome supplies the background, so
/// dark/light appearance follows automatically.
///
/// Panel 2.0 (owner pick "c cards", 2026-11-20 — it supersedes the
/// 2026-10-18 Quiet Rows freeze): a glance surface of grouped CARDS. The
/// Power card holds the battery header (with the Lock Screen icon in its
/// top-right corner), Stay Awake and Charge Limit; the Alerts card holds the
/// Lid alert and Session alerts rows. The footer — the Settings gear, the
/// Claude status caption and Quit — sits outside the cards. Everything else
/// lives in the Settings window (slice W), so there is no Details disclosure
/// any more. IRON RULE: a Settings-resident line that is not nominal renders
/// in the panel too, exactly once — `SurfacedLine` filters every such line
/// on `MenuStateModel.placement(ofSettingsLine:)`, below the cards.
///
/// The panel is ONE fixed layout, `GroupedCardsPanel`
/// (MenuPanelVariants.swift), composed from the shared components below.
/// Views decide arrangement only — never what is a warning.
struct MenuPanelView: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        GroupedCardsPanel(model: model)
            .frame(width: PanelMetrics.width)
    }
}

/// Type (canon C8, Panel 2.0 slice P): exactly four text roles. `.headline`
/// is the battery headline alone; `.body` (the default) the row titles;
/// `.caption` every status — row and surfaced captions, the charging line,
/// the Charge Limit value, group headers (semibold), the footer; `.caption2`
/// at most once (none today). No `.callout`. Glyphs size themselves apart
/// from the roles (`.system(size:)`, the desktop symbol's `.largeTitle`).
///
/// Shared geometry: 4/8/12 spacing rhythm, a fixed symbol column.
///
/// Density pass (curation round 1, 2026-10-18 — "the rows feel crowded"):
/// leading symbols 13pt → 16pt in a column widened 20 → 28pt, and feature rows
/// 8 → 12pt apart, while a row's own caption / slider / surfaced lines stay
/// `tight` under it (`PanelFeature`).
enum PanelMetrics {
    static let width: CGFloat = 300
    static let tight: CGFloat = 4
    static let regular: CGFloat = 8
    static let loose: CGFloat = 12
    /// Point size of the leading feature symbols (~1.25× the 13pt body text).
    static let symbolSize: CGFloat = 16
    /// Holds the widest leading glyph at `symbolSize` (battery.75percent,
    /// 28pt) without overflow — canary-tested in MenuPanelPresentationTests.
    static let symbolColumn: CGFloat = 28
    /// Captions under a symbol row align with the row title.
    static let titleIndent: CGFloat = symbolColumn + regular
    /// Gap between feature blocks in a card, and between the panel's
    /// groups (a card, the surfaced lines, the footer).
    static let rowSpacing: CGFloat = loose
    /// `PanelCard` (Panel 2.0 slice P, the owner-picked "c cards"): the
    /// corner radius and the inner padding of every card.
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 10
    /// The card's hairline: a `.separatorColor` stroke this wide.
    static let cardStroke: CGFloat = 0.5
    /// The card fill is `quaternarySystemFill` — which alone measured
    /// 1.06:1 against the menu (the 2026-10-18 invisible-card failure) —
    /// plus ONE extra layer per scheme: this much black in light, this much
    /// white in dark. Together they measured 1.166:1 light / 1.188:1 dark
    /// in the owner's pick render (target ≥ 1.15:1).
    static let cardBoostLight: Double = 0.045
    static let cardBoostDark: Double = 0.032
    /// `PanelIconButton` (slice W): the 28pt circular target and its 15pt
    /// glyph (Panel 2.0 spec — the Settings gear and, since slice P, the
    /// Lock Screen button).
    static let iconButtonSize: CGFloat = 28
    static let iconButtonGlyph: CGFloat = 15
    /// Its hit area (slice P, issue #47): a 36pt circle around the same
    /// centre, overflowing the 28pt footprint by 4pt on every side — so a
    /// near-miss still lands, and the layout around the button never moves.
    static let iconButtonHitArea: CGFloat = 36
    /// The severity badge on an icon button's top-trailing corner.
    static let iconButtonBadge: CGFloat = 9
}

/// Motion rules for the panel (motion-and-polish charter, issue #67), next to
/// the geometry they move. Motion only ever acknowledges what the user just
/// did; the panel's signature is the snap.
///
/// - Zero motion on open / close: the menu window appears and disappears in
///   one step, its height changes snap (`MenuPanelHostingView`), and no view
///   animates its own insertion or removal.
/// - Every animation is an ease-out of at most `maxDuration`. The motion lint
///   (`MenuPanelStructureTests.motionIsGatedAndShort`, amended by owner
///   ruling f on 2026-11-20) holds the panel to a tighter 200 ms, inside this
///   ceiling.
/// - Every animation is nil under Reduce Motion — the chevron's pattern,
///   `.animation(reduceMotion ? nil : .easeOut(duration: …), value: …)`.
/// - Only values the user drives animate: a button's press. Observed-state
///   changes never animate. (Panel 2.0 slice P retired the panel's other
///   two: the Details chevron left with the disclosure, and the charge-limit
///   readout's digit roll left with the panel slider — the limit is set in
///   Settings now, so in the panel it is observed state and snaps.)
///
/// The animated lines spell their duration as a literal (the motion lint
/// reads it); `panelMotionCodifiesEveryAnimation` holds each literal to one
/// of the durations below.
enum PanelMotion {
    /// The pressed-state fade of a plain-style panel button
    /// (`PanelPressFadeButtonStyle`).
    static let pressFade: Double = 0.10
    /// A pressed plain-style panel button's opacity, reached over `pressFade`.
    static let pressedOpacity: Double = 0.7
    /// How long the test send's "Sent" acknowledgment holds before the
    /// button reverts. A hold, not an animation: the label swap snaps.
    static let sentRevert: Double = 1.5
    /// How long a flipped-ON Stay Awake switch waits for pmset to confirm
    /// before its row says "Turning on…" (owner ruling e). A hold, not an
    /// animation: the caption snaps in, and a fast confirm never shows it.
    static let turnOnCaptionDelay: Double = 0.4
    /// The ceiling for any panel animation.
    static let maxDuration: Double = 0.3
}

/// One feature block: a control row plus whatever hangs under it (its
/// caption), held `tight` together so the larger
/// `rowSpacing` reads as the gap BETWEEN features. Only wrap content whose
/// first view is unconditional: an empty VStack still takes a full stack gap
/// (measured), whereas an empty conditional view takes none.
struct PanelFeature<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            content()
        }
    }
}

// MARK: - Cards

/// The panel's ONE container (Panel 2.0 slice P, the owner-picked "c
/// cards"): a rounded card — `PanelMetrics.cardRadius`, continuous corners —
/// holding its feature blocks `rowSpacing` apart inside `cardPadding`. The
/// fill is `quaternarySystemFill` plus one boost layer per scheme
/// (`PanelMetrics.cardBoostLight` black / `cardBoostDark` white): the system
/// fill alone measured 1.06:1 against the menu, the invisible card of the
/// 2026-10-18 scrapped variant; with the boost the owner's pick measured
/// 1.166:1 light / 1.188:1 dark. A `cardStroke` hairline in the separator
/// color draws the edge.
struct PanelCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            content()
        }
        .padding(PanelMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                shape.fill(Color(nsColor: .quaternarySystemFill))
                shape.fill(Self.boost(colorScheme))
            }
        }
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: PanelMetrics.cardStroke))
    }

    /// The one extra fill layer: black in light, white in dark.
    static func boost(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(PanelMetrics.cardBoostDark)
            : Color.black.opacity(PanelMetrics.cardBoostLight)
    }
}

/// A titled group: its `PanelGroupHeader`, `tight` above its card.
struct PanelGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            PanelGroupHeader(title: title)
            PanelCard(content: content)
        }
    }
}

// MARK: - Severity lines

/// One status line. Non-nominal ⇒ severity icon + text (never color alone),
/// with the severity spoken to VoiceOver. Nominal ⇒ a plain secondary caption,
/// rendered only when the caller shows nominal captions.
///
/// Contrast program (canon C11, issue #48): only the ICON carries the
/// severity tint; the text of a warning or error stays `.primary`. A tinted
/// glyph measured 1.57:1 against the light menu — fine for a redundant cue
/// beside the words, never for the words themselves.
struct PanelCaptionLine: View {
    let line: PanelLine
    var showsNominal = true
    var font: Font = .caption

    var body: some View {
        if let symbol = MenuStateModel.severitySymbol(line.severity) {
            HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {
                Image(systemName: symbol)
                    .foregroundStyle(PanelSeverityTint.color(line.severity))
                Text(line.text)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(font)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PanelSeverityTint.spoken(line))
        } else if showsNominal {
            Text(line.text)
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Styling only (the severity itself comes from the mappings): semantic
/// system colors that adapt to appearance, always paired with the icon.
enum PanelSeverityTint {
    static func color(_ severity: PanelSeverity) -> Color {
        switch severity {
        case .nominal, .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    static func spoken(_ line: PanelLine) -> String {
        MenuStateModel.severityAccessibilityPrefix(line.severity).map { "\($0): \(line.text)" } ?? line.text
    }
}

/// A Settings-home line at TOP LEVEL in the panel, rendered ONLY while
/// non-nominal (a nominal one lives in its Settings pane alone). An absent
/// line (nil — e.g. "holding the Mac awake" while it is not) renders nowhere.
struct SurfacedLine: View {
    let line: PanelLine?

    var body: some View {
        if let line, MenuStateModel.placement(ofSettingsLine: line.severity) == .topLevel {
            PanelCaptionLine(line: line)
        }
    }
}

/// Top-level home for the Settings › Claude lines that can be problems.
/// (The awake line is always nominal today, so it never renders here — it
/// is listed so the iron rule holds by construction, not by the mapping.)
struct ClaudeSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.hookStatus)
        SurfacedLine(line: model.hookVersionStatus)
        SurfacedLine(line: model.claudeAwakeLine)
    }
}

/// Top-level home for the Settings › General line that can be a problem:
/// the Lock Screen API being unavailable on this macOS.
struct GeneralSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.lockScreenStatus)
    }
}

/// Top-level home for the Settings › Alerts lines that can be problems —
/// the shared delivery settings (server, topic), the lid History line and
/// (F3 stage 1) the phone transport line.
struct LidAlertSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.lidTopicStatus)
        SurfacedLine(line: model.lidServerStatus)
        SurfacedLine(line: model.lidLastSend(now: Date().timeIntervalSince1970))
        SurfacedLine(line: model.phoneAlertStatus(now: Date().timeIntervalSince1970))
    }
}

/// Top-level home for the session-alerts History line that can be a problem
/// (a refused / failed / unconfirmed last session alert).
struct SessionAlertsSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.finishAlertLastSend(now: Date().timeIntervalSince1970))
    }
}

/// Launch at Login surfaces from Settings › General as a WHOLE row (checkbox
/// + caption + System Settings link) while its status needs the user.
struct SurfacedLaunchAtLogin: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        if let caption = model.launchAtLoginCaption,
           MenuStateModel.placement(ofSettingsLine: caption.severity) == .topLevel {
            LaunchAtLoginRow(model: model)
        }
    }
}

// MARK: - Rows

/// One control row: leading symbol in the fixed symbol column, title,
/// trailing control.
struct PanelRow<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: PanelMetrics.regular) {
            Image(systemName: symbol)
                .font(.system(size: PanelMetrics.symbolSize))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.symbolColumn)
                .accessibilityHidden(true)
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: PanelMetrics.regular)
            // Controls (not text) keep their ideal size, so the title gives way
            // instead of crushing the button.
            HStack(spacing: PanelMetrics.regular) { trailing() }
                .fixedSize()
        }
    }
}

// MARK: - Controls (bindings render OBSERVED state; actions forward to the model)

struct StayAwakeToggle: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Toggle("Stay Awake", isOn: Binding(
            get: { MenuStateModel.stayAwakeToggle(forObserved: model.stayAwakeObserved).isOn },
            set: { model.setStayAwake($0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// The Stay Awake row's caption slot (`MenuStateModel.stayAwakeSlot`): the
/// unreadable-state warning, or (owner ruling e) the transient "Turning on…"
/// in the quiet nominal caption style while a flipped-ON switch waits past
/// `PanelMotion.turnOnCaptionDelay` for pmset to confirm. It is the ONLY view
/// observing `StayAwakeTurnOnFeedback`, so a flip re-renders this slot and
/// never the switch.
struct StayAwakeCaptionSlot: View {
    @ObservedObject var model: MenuStateModel
    @ObservedObject var turnOn: StayAwakeTurnOnFeedback

    var body: some View {
        if let line = MenuStateModel.stayAwakeSlot(observed: model.stayAwakeObserved, turnOn: turnOn.phase) {
            PanelCaptionLine(line: line)
        }
    }
}

/// One click: lock the session AND turn the display off, with the Mac still
/// running. The menu closes first (the user is walking away) — handled by
/// MenuContentView through the single dismissal gateway. Since the
/// 2026-10-21 declutter it is an ICON-ONLY button; since 2026-10-22 it sits
/// in the battery header's top-right corner (`BatteryHeader`). Since slice P
/// it is the panel's `PanelIconButton` — the owner found the bordered
/// small button's glyph "too small", and a bordered button only ever
/// hit-tested at its 35×19pt bezel (#47) — so it has the 15pt glyph, the
/// 28pt target and the 36pt hit area. Its availability line lives in
/// Settings › General (and surfaces in the panel when the lock API is
/// unavailable).
struct LockScreenButton: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        PanelIconButton(symbol: PanelSymbol.lockScreen, label: "Lock Screen") { model.lockScreen() }
            .disabled(!MenuStateModel.lockScreenPresentation(available: model.lockScreenAvailable).enabled)
            .accessibilityHint("Locks now and turns the display off — the Mac keeps running")
    }
}

/// Intel (notSupported): controls disabled with the explanation. Setup
/// required and control unavailable (#58): still usable (intent persists;
/// the caption explains, and it takes effect once the feature can act).
struct ChargeLimitToggle: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Toggle("Charge Limit", isOn: Binding(
            get: { model.limitEnabled },
            set: { model.setLimitEnabled($0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(model.featureState == .notSupported)
    }
}

/// The Charge Limit row's value (Panel 2.0 slice P): the limit in
/// monospaced digits, before the switch. The slider that set it lives in
/// Settings › General now, so in the panel the value is observed state: it
/// snaps (the #67 digit roll left with the panel slider — it would only
/// ever have played as the menu opened).
struct ChargeLimitValue: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Text(MenuStateModel.chargeLimitValueText(limit: model.limit))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct LidAlertToggle: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Toggle("Lid alert", isOn: Binding(
            get: { model.lidGuardEnabled },
            set: { model.setLidGuardEnabled($0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Lid alert — notify me if the Mac sleeps mid-task")
    }
}

/// Track C: the finish alert + waiting buzz behind ONE toggle. Forwards to
/// MenuContentView (shared priming test send); the menu stays open.
struct SessionAlertsToggle: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Toggle("Session alerts", isOn: Binding(
            get: { model.finishAlertEnabled },
            set: { model.setFinishAlertEnabled($0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel("Session alerts — notify me when a Claude session finishes or waits for me")
    }
}

/// SMAppService is the source of truth — the checkbox renders the OBSERVED
/// status (refreshed on menu open), never a stored flag.
struct LaunchAtLoginRow: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        let presentation = MenuStateModel.launchAtLoginPresentation(for: model.loginItemStatus)
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            Toggle("Launch at Login", isOn: Binding(
                get: { presentation.isOn },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if let caption = model.launchAtLoginCaption {
                PanelCaptionLine(line: caption)
            }
            if presentation.showSettingsShortcut {
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .font(.caption)
            }
        }
    }
}

/// The panel's LAST row, OUTSIDE the cards (Panel 2.0 slice P): the
/// Settings gear first, then the Claude status caption, then Quit on the
/// right — never an icon button beside Quit, where it reads as part of the
/// Quit control (the 2026-10-22 lesson). The surfaced problem lines render
/// ABOVE this row, so the footer — and Quit — always close the panel.
///
/// The footer has no fill of its own, and neither has Quit: a bordered
/// button's gray bezel measured 1.188:1 against the light menu — the card
/// fill's own step (1.166:1) — so it read as a third, small card. Quit is the
/// panel's plain button look instead (`PanelPressFadeButtonStyle`, the icon
/// buttons' press fade): neutral primary text, its hit area the full
/// footer-row height.
struct PanelFooterRow: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        HStack(alignment: .center, spacing: PanelMetrics.regular) {
            SettingsGearButton(model: model)
            PanelFooterStatus(model: model)
            Spacer(minLength: PanelMetrics.regular)
            Button { model.quit() } label: {
                Text("Quit NapCat")
                    .font(.caption)
                    .frame(minHeight: PanelMetrics.iconButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressFadeButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// The footer's caption: the Claude status (`model.footerLabel`, the
/// fixed vocabulary of `MenuStateModel.claudeFooterLabel` — "Claude:
/// running" / "idle" / "paused"), absent without the detection stack. One
/// line that hugs its text, so the footer's Spacer keeps it clear of Quit —
/// `PanelCaptionLine`'s two looks on a single line: a paused label carries
/// the severity icon + tint right here, at top level, unconditionally (never
/// behind a placement filter); a nominal one is the quiet secondary caption.
struct PanelFooterStatus: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        if let label = model.footerLabel {
            Group {
                if let symbol = MenuStateModel.severitySymbol(label.severity) {
                    HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {
                        Image(systemName: symbol)
                            .foregroundStyle(PanelSeverityTint.color(label.severity))
                        Text(label.text)
                            .foregroundStyle(.primary)
                    }
                } else {
                    Text(label.text)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PanelSeverityTint.spoken(label))
        }
    }
}

/// The panel's icon-only button (Panel 2.0, slice W): a 28pt circular target
/// holding the glyph alone — 15pt medium, primary (tertiary while disabled:
/// the plain look has no bezel to grey out) — with the plain look and the
/// shared press fade (`PanelPressFadeButtonStyle`). Tooltip and VoiceOver
/// carry its name. The footer's Settings gear and the header's Lock Screen
/// button use it.
///
/// Hit area (slice P, issue #47): the label is a 36pt circle, and a negative
/// padding hands the layout back its 28pt footprint, so the hit circle
/// overflows the target by 4pt on every side without moving anything. (A
/// bordered button cannot do this: it hit-tests at its bezel whatever its
/// content shape says.)
struct PanelIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PanelMetrics.iconButtonGlyph, weight: .medium))
                .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)
                .frame(width: PanelMetrics.iconButtonHitArea, height: PanelMetrics.iconButtonHitArea)
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressFadeButtonStyle())
        .padding(-(PanelMetrics.iconButtonHitArea - PanelMetrics.iconButtonSize) / 2)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The footer's Settings gear (slice W, issue #78): opens the Settings
/// window — forwarding to the model, which hands it to MenuContentView's
/// dismissal gateway — and carries the worst Settings-resident severity as a
/// corner badge (`MenuStateModel.settingsBadge`). Only a badge: the problem
/// lines themselves surface above it, exactly once, through the panel's own
/// surfaced twins — the gear only says where their setting lives.
struct SettingsGearButton: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        let badge = model.settingsBadge
        PanelIconButton(symbol: PanelSymbol.settings, label: "Settings") { model.openSettings() }
            .overlay(alignment: .topTrailing) {
                if let symbol = MenuStateModel.severitySymbol(badge) {
                    Image(systemName: symbol)
                        .font(.system(size: PanelMetrics.iconButtonBadge, weight: .semibold))
                        .foregroundStyle(PanelSeverityTint.color(badge))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(MenuStateModel.severityAccessibilityPrefix(badge) ?? "")
            .accessibilityHint(badge == .nominal
                ? "Opens the Settings window"
                : "Opens the Settings window, which holds the setting for an item that needs attention, shown above")
    }
}

// MARK: - Battery header

/// Live battery gauge + charging state — the panel's header, the first
/// thing in the Power card: the full-size ring of curation round 2 with the
/// charge-state glyph inside it, and the "Battery N%" headline + charging
/// line beside it, so the percent is stated exactly once (in the headline).
/// The 44pt compact ring and Status Hero's percent-in-ring / activity-line
/// header were deleted at the 2026-10-18 freeze. Panel 2.0 slice P dropped
/// the old 76pt minimum height: centred in it, the 58pt ring sat 9pt down,
/// which inside the card's 10pt padding was 19pt of dead space above it.
/// The header now hugs the ring.
///
/// Lock Screen amendment (2026-10-22, "battery header stays same, lock goes
/// to top right"): the icon-only `LockScreenButton` is an OVERLAY in the
/// header's top-trailing corner, its top on the ring's top line. An overlay
/// takes no room in the HStack, so ring, headline and charging line keep
/// their layout; the charging line sits below the button's reach.
///
/// VoiceOver (UI audit M1a, 2026-11-19): the ring and the text column are
/// ONE element — "Battery", valued "85%, Charging" — so the percent is spoken
/// once, not once by the ring and again by the headline. The Lock Screen
/// overlay sits outside that element and stays its own button, after it.
struct BatteryHeader: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        HStack(spacing: PanelMetrics.loose) {
            gauge
            VStack(alignment: .leading, spacing: 2) {
                Text(MenuStateModel.batteryHeadline(hasBattery: model.hasBattery, percent: model.batteryPercent))
                    .font(.headline)
                    .monospacedDigit()
                chargingLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(Self.spokenValue(
            hasBattery: model.hasBattery,
            percent: model.batteryPercent,
            isCharging: model.isCharging,
            adapterConnected: model.adapterConnected
        ))
        // Measured: as one element the row would otherwise be read AFTER the
        // overlaid Lock Screen button that shares its top edge.
        .accessibilitySortPriority(1)
        .overlay(alignment: .topTrailing) {
            LockScreenButton(model: model)
        }
    }

    private var chargingLine: some View {
        Text(MenuStateModel.chargingStatusLine(
            hasBattery: model.hasBattery,
            percent: model.batteryPercent,
            isCharging: model.isCharging,
            adapterConnected: model.adapterConnected
        ))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The header element's VoiceOver value, built from the same two strings
    /// the text column shows: "<percent>, <charging line>" ("85%, Charging"),
    /// or the charging line alone on a desktop Mac ("Desktop Mac — no
    /// battery"), which has no percent to state.
    nonisolated static func spokenValue(hasBattery: Bool, percent: Int?, isCharging: Bool,
                                        adapterConnected: Bool) -> String {
        let state = MenuStateModel.chargingStatusLine(
            hasBattery: hasBattery,
            percent: percent,
            isCharging: isCharging,
            adapterConnected: adapterConnected
        )
        return hasBattery ? "\(MenuStateModel.percentText(percent)), \(state)" : state
    }

    /// The full-size ring (no desktop: the desktop symbol at the same
    /// footprint). What sits inside the ring is `ringInterior`. Neither
    /// carries accessibility of its own: the header row is the one element.
    @ViewBuilder private var gauge: some View {
        if model.hasBattery {
            Gauge(value: MenuStateModel.gaugeFraction(model.batteryPercent)) {
                EmptyView()
            } currentValueLabel: {
                ringInterior
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            Image(systemName: PanelSymbol.desktop)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
        }
    }

    /// Curation round 2 fix ("you removed the battery icon"): the headline
    /// already says "Battery N%", so the ring holds the charge-state glyph,
    /// never the percent — at 12pt, which keeps the glyph-to-ring proportion
    /// of the old compact header (whose 0.8 scale shrank ring and glyph alike).
    /// Primary since the contrast program (canon C11, issue #48): the
    /// secondary glyph was the faintest mark on the header, and on the light
    /// card it measured 3.78:1.
    private var ringInterior: some View {
        Image(systemName: model.isCharging ? PanelSymbol.charging : PanelSymbol.battery)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
    }
}

// MARK: - Press fade

/// The plain look plus a press state (#67, owner ruling f): while the pointer
/// holds the button, its label fades to `PanelMotion.pressedOpacity` over
/// `PanelMotion.pressFade`, and back on release. There is no fade under
/// Reduce Motion. The press is the user's own, so it may animate.
struct PanelPressFadeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? PanelMotion.pressedOpacity : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The "Send test message" button (#67), acknowledging the tap within
/// the Doherty threshold: "Sending…" (disabled) on the next frame after the
/// click, then — once ntfy ACCEPTS the message — "Sent" + checkmark for
/// `PanelMotion.sentRevert`, then back. A failure only re-enables it: the
/// surfaced last-send line stays the one error signal. The phase is transient
/// view state, moved only by `MenuStateModel.testSendPhase(_:on:)` and ended
/// by the lid lane's existing outcome pipeline (`lidGuardLastOutcomeAt`,
/// republished through `model.refresh()`).
///
/// Reserved width: every phase's label is laid out in one ZStack, all but the
/// current one hidden, so the button always has the widest label's size
/// ("Send test message") and the row's geometry never moves. Label swaps
/// snap — no animation. Settings › Alerts (slice W) is its home since the
/// Details disclosure left the panel (slice P), at the regular control size;
/// the small default was the panel's.
struct SendFeedbackButton: View {
    @ObservedObject var model: MenuStateModel
    var controlSize: ControlSize = .small
    @State private var phase = TestSendPhase.idle

    var body: some View {
        let presentation = MenuStateModel.testSendButton(phase: phase, available: model.lidAlertTestSendAvailable)
        Button {
            phase = MenuStateModel.testSendPhase(phase, on: .tapped)
            model.sendLidGuardTestMessage()
        } label: {
            ZStack {
                ForEach(TestSendPhase.allCases, id: \.self) { candidate in
                    let label = Self.label(MenuStateModel.testSendButton(phase: candidate, available: true))
                    if candidate == phase {
                        label
                    } else {
                        label.hidden()
                    }
                }
            }
        }
        .controlSize(controlSize)
        .disabled(!presentation.enabled)
        .accessibilityLabel(presentation.title)
        .onChange(of: model.lidGuardLastOutcomeAt) {
            phase = MenuStateModel.testSendPhase(phase, on: .outcome(model.lidGuardLastOutcome))
        }
        .task(id: phase) {
            guard phase == .sent else { return }
            // Cut short (the panel closed) it reverts too — never a stale
            // "Sent" on reopen. The mapping ignores the revert in any other
            // phase, so a cancelled hold cannot undo a newer tap.
            try? await Task.sleep(for: .seconds(PanelMotion.sentRevert))
            phase = MenuStateModel.testSendPhase(phase, on: .revertElapsed)
        }
    }

    /// The title, then the symbol inline in the same Text: the glyph sits on
    /// the text's baseline and adds no height.
    private static func label(_ presentation: TestSendButtonPresentation) -> Text {
        guard let symbol = presentation.symbol else { return Text(presentation.title) }
        return Text("\(presentation.title) \(Image(systemName: symbol))")
    }
}

/// A group's header (Panel 2.0 slice P: above the Alerts card; also the
/// debug section's): `.caption` semibold, secondary, a VoiceOver heading.
struct PanelGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Debug (debugBattery mode only)

struct DebugBatterySection: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            PanelGroupHeader(title: "Debug — Simulated Battery")
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(model.batteryPercent ?? 0) },
                        set: { model.setSimulatedPercent(Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1
                ) {
                    Text("Simulated battery percent")
                }
                .labelsHidden()
                .controlSize(.small)
                Text(MenuStateModel.percentText(model.batteryPercent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                Text("AC adapter connected").font(.caption)
                Spacer()
                Toggle("AC adapter connected", isOn: Binding(
                    get: { model.adapterConnected },
                    set: { model.setSimulatedAdapter($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }
}
