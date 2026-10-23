import SwiftUI

/// Rich menu content (P3b user decision), hosted by a MenuPanelHostingView
/// inside a single NSMenuItem (MenuContentView). System materials and
/// semantic colors only — the menu chrome supplies the background, so
/// dark/light appearance follows automatically.
///
/// UI redesign (2026-10-18, PLAN.md "UI Redesign — Menu Panel"): three tiers —
/// glance (battery, Stay Awake), controls (Charge Limit, Lid alert and Session
/// alerts, each with its one-line status), and everything else behind ONE
/// "Details" disclosure. Declutter amendment (2026-10-21): the Claude status
/// is the disclosure's own text in the footer ("Claude: running ●"), and Lock
/// Screen is an icon button. Lock Screen amendment (2026-10-22): that button
/// overlays the battery header's top-right corner instead of sitting beside
/// Quit, where it read as part of the Quit control. IRON RULE: a non-nominal
/// line never stays inside Details — `TuckedLine` / `SurfacedLine` split
/// every Details-home line on `MenuStateModel.placement(ofDetailsLine:)`, so
/// each renders exactly once.
///
/// Design freeze (2026-10-18): the panel is ONE fixed layout, `QuietRowsPanel`
/// (MenuPanelVariants.swift), composed from the shared components below. The
/// curation variants and their picker are gone. Views decide arrangement only —
/// never what is a warning.
struct MenuPanelView: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        QuietRowsPanel(model: model)
            .frame(width: PanelMetrics.width)
    }
}

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
    /// Gap between feature blocks in the panel's main column.
    static let rowSpacing: CGFloat = loose
    /// Top inset of the Lock Screen button in the battery header's top-right
    /// corner (2026-10-22). The ring — the system `.accessoryCircularCapacity`
    /// gauge, which has no size constant to read (58pt measured) — is centred
    /// in the 76pt header, so its top edge sits (76 − 58) / 2 = 9pt down. The
    /// button shares that top line instead of hugging the panel edge.
    static let headerLockInset: CGFloat = 9
}

/// One feature block: a control row plus whatever hangs under it (caption,
/// slider, surfaced problem lines), held `tight` together so the larger
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

// MARK: - Severity lines

/// One status line. Non-nominal ⇒ severity icon + text (never color alone),
/// with the severity spoken to VoiceOver. Nominal ⇒ a plain secondary caption,
/// rendered only when the caller shows nominal captions.
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

/// A Details-home line, rendered inside Details ONLY while nominal. An absent
/// line (nil — e.g. "holding the Mac awake" while it is not) renders nowhere.
struct TuckedLine: View {
    let line: PanelLine?

    var body: some View {
        if let line, MenuStateModel.placement(ofDetailsLine: line.severity) == .details {
            PanelCaptionLine(line: line, showsNominal: true)
        }
    }
}

/// The same Details-home line at TOP LEVEL, rendered ONLY while non-nominal.
struct SurfacedLine: View {
    let line: PanelLine?

    var body: some View {
        if let line, MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel {
            PanelCaptionLine(line: line)
        }
    }
}

/// Top-level home for the Claude-section Details lines that can be problems.
/// (The awake line is always nominal today, so its twin never renders — it
/// exists so the iron rule holds by construction, not by the mapping.)
struct ClaudeSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.hookStatus)
        SurfacedLine(line: model.hookVersionStatus)
        SurfacedLine(line: model.claudeAwakeLine)
    }
}

/// Top-level home for the General-group Details line that can be a problem
/// (2026-10-21): the Lock Screen API being unavailable on this macOS.
struct GeneralSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.lockScreenStatus)
    }
}

/// Top-level home for the lid-alert Details lines that can be problems.
struct LidAlertSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.lidTopicStatus)
        SurfacedLine(line: model.lidServerStatus)
        SurfacedLine(line: model.lidLastSend(now: Date().timeIntervalSince1970))
    }
}

/// Top-level home for the session-alerts Details line that can be a problem
/// (a refused / failed / unconfirmed last session alert).
struct SessionAlertsSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.finishAlertLastSend(now: Date().timeIntervalSince1970))
    }
}

/// Launch at Login escapes Details as a WHOLE row (checkbox + caption +
/// System Settings link) while its status needs the user.
struct SurfacedLaunchAtLogin: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        if let caption = model.launchAtLoginCaption,
           MenuStateModel.placement(ofDetailsLine: caption.severity) == .topLevel {
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

/// One click: lock the session AND turn the display off, with the Mac still
/// running. The menu closes first (the user is walking away) — handled by
/// MenuContentView through the single dismissal gateway. Since the
/// 2026-10-21 declutter it is an ICON-ONLY button; since 2026-10-22 it sits
/// in the battery header's top-right corner (`BatteryHeader`). Its
/// availability line lives in Details › General (and surfaces when the lock
/// API is unavailable).
struct LockScreenButton: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Button { model.lockScreen() } label: {
            Image(systemName: PanelSymbol.lockScreen)
        }
        .controlSize(.small)
        .disabled(!MenuStateModel.lockScreenPresentation(available: model.lockScreenAvailable).enabled)
        .help("Lock Screen")
        .accessibilityLabel("Lock Screen")
        .accessibilityHint("Locks now and turns the display off — the Mac keeps running")
    }
}

/// Intel (notSupported): controls disabled with the explanation. Setup
/// required: still usable (intent persists; the caption explains).
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

struct ChargeLimitSlider: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(model.limit) },
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
        .controlSize(.small)
        .disabled(model.featureState == .notSupported || !model.limitEnabled)
        .accessibilityValue(MenuStateModel.limitLabel(limit: model.limit))
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

/// The panel's LAST row (curation round 1, 2026-10-18): the ONE Details
/// disclosure on the left, Quit on the right — nothing else. (The Lock Screen
/// button sat beside Quit from the 2026-10-21 declutter until 2026-10-22,
/// when it moved to the battery header's top-right corner.) Expanded Details
/// content renders ABOVE this row, so the footer — and Quit — always close
/// the panel.
struct PanelFooterRow: View {
    @ObservedObject var model: MenuStateModel

    /// The row adds no stack gap: the Spacer alone keeps ≥8pt between the
    /// status label and Quit, and the disclosure's badge yields before the
    /// label would truncate.
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            PanelDetailsDisclosure(model: model)
            Spacer(minLength: PanelMetrics.regular)
            Button("Quit NapCat") { model.quit() }
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Battery header

/// Live battery gauge + charging state — the panel's header, frozen
/// 2026-10-18 as the curated Quiet Rows header: the full-size ring of
/// curation round 2 (~76pt header) with the charge-state glyph inside it, and
/// the "Battery N%" headline + charging line beside it, so the percent is
/// stated exactly once (in the headline). The 44pt compact ring and Status
/// Hero's percent-in-ring / activity-line header were deleted at the freeze.
///
/// Lock Screen amendment (2026-10-22, "battery header stays same, lock goes
/// to top right"): the icon-only `LockScreenButton` is an OVERLAY in the
/// header's top-trailing corner, its top on the ring's top line
/// (`PanelMetrics.headerLockInset`). An overlay takes no room in the HStack,
/// so ring, headline and charging line keep their frozen layout; the longest
/// charging line ("On AC power — not charging") still clears the button.
struct BatteryHeader: View {
    @ObservedObject var model: MenuStateModel

    private var percent: String { MenuStateModel.percentText(model.batteryPercent) }

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
        .frame(minHeight: 76)
        .overlay(alignment: .topTrailing) {
            LockScreenButton(model: model)
                .padding(.top, PanelMetrics.headerLockInset)
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

    /// The full-size ring (no desktop: the desktop symbol at the same
    /// footprint). What sits inside the ring is `ringInterior`.
    @ViewBuilder private var gauge: some View {
        if model.hasBattery {
            Gauge(value: MenuStateModel.gaugeFraction(model.batteryPercent)) {
                EmptyView()
            } currentValueLabel: {
                ringInterior
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("Battery")
            .accessibilityValue(percent)
        } else {
            Image(systemName: PanelSymbol.desktop)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
        }
    }

    /// Curation round 2 fix ("you removed the battery icon"): the headline
    /// already says "Battery N%", so the ring holds the charge-state glyph,
    /// never the percent — at 12pt, which keeps the glyph-to-ring proportion
    /// of the old compact header (whose 0.8 scale shrank ring and glyph alike).
    private var ringInterior: some View {
        Image(systemName: model.isCharging ? PanelSymbol.charging : PanelSymbol.battery)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

// MARK: - The ONE "Details" disclosure (tier 3)

/// The single disclosure control (chevron + the Claude status as its text +
/// badge), placed by `PanelFooterRow` on the left of the panel's last row.
/// Status-as-disclosure (2026-10-21): the text is `model.detailsLabel` — the
/// fixed vocabulary of `MenuStateModel.claudeFooterLabel` ("Claude: paused" /
/// "running" / "idle"; plain "Details" without detection). A paused label
/// carries the severity icon + tint right here, at top level; the badge then
/// summarises only the OTHER tucked lines. Toggling is pure model state (never
/// dismisses the menu); the height change snaps (MenuPanelHostingView) and
/// only the chevron turns — ≤150ms ease-out, none under Reduce Motion. The
/// content opens ABOVE the footer, so the expanded chevron points UP at it
/// (right ▸ collapsed, up ▴ expanded).
struct PanelDetailsDisclosure: View {
    @ObservedObject var model: MenuStateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = model.detailsExpanded
        let badge = model.detailsBadge
        let label = model.detailsLabel
        Button {
            model.setDetailsExpanded(!expanded)
        } label: {
            // Hugs its content: the footer's Spacer separates it from Quit,
            // the only other control in the row.
            HStack(spacing: PanelMetrics.regular) {
                Image(systemName: PanelSymbol.disclosure)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? -90 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                    .frame(width: PanelMetrics.symbolColumn)
                // The status text never truncates to make room for the badge:
                // if both do not fit beside Quit, the badge yields (the
                // problems it points at are already surfaced above it).
                ViewThatFits(in: .horizontal) {
                    statusLine(label, badge: badge)
                    statusLine(label, badge: .nominal)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Details")
        .accessibilityValue("\(PanelSeverityTint.spoken(label)), \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(badge == .nominal
            ? "Shows detection, alert and app settings"
            : "Holds the setting for an item that needs attention, shown above")
        .accessibilityAddTraits(.isButton)
    }

    /// The label (with its own severity icon + tint) and, when not nominal,
    /// the badge — held `tight`.
    private func statusLine(_ label: PanelLine, badge: PanelSeverity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.tight) {
            if let symbol = MenuStateModel.severitySymbol(label.severity) {
                Image(systemName: symbol)
                    .foregroundStyle(PanelSeverityTint.color(label.severity))
            }
            Text(label.text)
                .lineLimit(1)
            if let symbol = MenuStateModel.severitySymbol(badge) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(PanelSeverityTint.color(badge))
            }
        }
    }
}

/// Tier-3 content. Details-home lines go through `TuckedLine`, so a
/// non-nominal one is absent here (it renders above). The Claude status is
/// NOT a Details line: it is the disclosure's own text, always visible in the
/// footer (`PanelDetailsDisclosure`).
struct PanelDetailsContent: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.loose) {
            if model.lidGuardVisible {
                ntfyAlertsGroup
            }
            if model.claudeDetectionVisible {
                claudeGroup
            }
            generalGroup
        }
    }

    /// The lid alert and the session alerts share one destination, one
    /// settings editor and one priming test send — so one group.
    private var ntfyAlertsGroup: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            DetailsGroupHeader(title: "ntfy alerts")
            // The topic itself is never rendered — it is the password to the
            // feed. The model does not even expose it to views.
            TuckedLine(line: model.lidServerStatus)
            TuckedLine(line: model.lidTopicStatus)
            TuckedLine(line: model.lidLastSend(now: Date().timeIntervalSince1970))
            if model.finishAlertVisible {
                TuckedLine(line: model.finishAlertLastSend(now: Date().timeIntervalSince1970))
            }
            HStack(spacing: PanelMetrics.regular) {
                Button("ntfy settings…") { model.editLidGuardSettings() }
                    .controlSize(.small)
                Button("Send test message") { model.sendLidGuardTestMessage() }
                    .controlSize(.small)
                    .disabled(!model.lidAlertTestSendAvailable)
            }
            .padding(.top, 2)
            Text(MenuStateModel.lidAlertTopicSecrecyNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// F3 (2026-10-18): the Pause detection kill switch lives HERE, out of
    /// casual reach; while paused, the footer's disclosure label says so.
    private var claudeGroup: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            DetailsGroupHeader(title: "Claude detection")
            TuckedLine(line: model.hookStatus)
            TuckedLine(line: model.hookVersionStatus)
            TuckedLine(line: model.claudeAwakeLine)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pause detection").font(.callout)
                    Text(MenuStateModel.pauseDetectionCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: PanelMetrics.regular)
                Toggle("Pause detection", isOn: Binding(
                    get: { model.claudeDetectionPaused },
                    set: { model.setDetectionPaused($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.top, 2)
        }
    }

    private var generalGroup: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            DetailsGroupHeader(title: "General")
            TuckedLine(line: model.lockScreenStatus)
            if MenuStateModel.placement(ofDetailsLine: model.launchAtLoginCaption?.severity ?? .nominal) == .details {
                LaunchAtLoginRow(model: model)
            }
        }
    }
}

struct DetailsGroupHeader: View {
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
            DetailsGroupHeader(title: "Debug — Simulated Battery")
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
