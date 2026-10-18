import SwiftUI

/// Rich menu content (P3b user decision), hosted by a MenuPanelHostingView
/// inside a single NSMenuItem (MenuContentView). System materials and
/// semantic colors only — the menu chrome supplies the background, so
/// dark/light appearance follows automatically.
///
/// UI redesign (2026-10-18, PLAN.md "UI Redesign — Menu Panel"): three tiers —
/// glance (battery, Stay Awake, the merged Claude row), controls (Lock Screen,
/// Charge Limit, Lid alert + its one-line status), and everything else behind
/// ONE "Details" disclosure. IRON RULE: a non-nominal line never stays inside
/// Details — `TuckedLine` / `SurfacedLine` split every Details-home line on
/// `MenuStateModel.placement(ofDetailsLine:)`, so each renders exactly once.
///
/// The layout variant (A/C, MenuPanelVariants.swift) is a curation-only
/// scaffold; every variant composes the shared components below from the SAME
/// model outputs. Views decide arrangement only — never what is a warning.
struct MenuPanelView: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Group {
            switch model.panelStyle {
            case .a: QuietRowsPanel(model: model)
            case .c: StatusHeroPanel(model: model)
            }
        }
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
    /// Gap between feature blocks in the variants' main column.
    static let rowSpacing: CGFloat = loose
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
/// rendered only when the variant shows nominal captions.
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

/// A Details-home line, rendered inside Details ONLY while nominal.
struct TuckedLine: View {
    let line: PanelLine

    var body: some View {
        if MenuStateModel.placement(ofDetailsLine: line.severity) == .details {
            PanelCaptionLine(line: line, showsNominal: true)
        }
    }
}

/// The same Details-home line at TOP LEVEL, rendered ONLY while non-nominal.
struct SurfacedLine: View {
    let line: PanelLine

    var body: some View {
        if MenuStateModel.placement(ofDetailsLine: line.severity) == .topLevel {
            PanelCaptionLine(line: line)
        }
    }
}

/// Top-level home for the Claude-section Details lines that can be problems.
struct ClaudeSurfacedLines: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        SurfacedLine(line: model.hookStatus)
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

/// The merged Claude row (tier 1). Paused renders the warning icon in the
/// leading column plus the "where to undo it" hint.
struct ClaudeStatusRow: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        let status = model.claudeStatus
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.regular) {
                if let warning = MenuStateModel.severitySymbol(status.severity) {
                    Image(systemName: warning)
                        .font(.system(size: PanelMetrics.symbolSize))
                        .foregroundStyle(PanelSeverityTint.color(status.severity))
                        .frame(width: PanelMetrics.symbolColumn)
                } else {
                    Image(systemName: PanelSymbol.claude)
                        .font(.system(size: PanelMetrics.symbolSize))
                        .foregroundStyle(.secondary)
                        .frame(width: PanelMetrics.symbolColumn)
                }
                Text(status.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PanelSeverityTint.spoken(status))
            if let hint = model.claudeStatusHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
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
/// MenuContentView through the single dismissal gateway.
struct LockScreenButton: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        Button("Lock") { model.lockScreen() }
            .controlSize(.small)
            .disabled(!MenuStateModel.lockScreenPresentation(available: model.lockScreenAvailable).enabled)
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

/// The panel's LAST row in every variant (curation round 1, 2026-10-18): the
/// ONE Details disclosure on the left, Quit on the right. Expanded Details
/// content renders ABOVE this row, so the footer — and Quit — always close
/// the panel.
struct PanelFooterRow: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        HStack(alignment: .center, spacing: PanelMetrics.regular) {
            PanelDetailsDisclosure(model: model)
            Spacer(minLength: PanelMetrics.regular)
            Button("Quit NapCat") { model.quit() }
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Battery header

/// Live battery gauge + charging state. `.hero` (variant C) is the full-size
/// gauge with the percent inside and the composed activity line; `.compact`
/// is the classic 44pt header.
struct BatteryHeader: View {
    enum Size { case compact, hero }

    @ObservedObject var model: MenuStateModel
    var size: Size = .compact

    private var percent: String { MenuStateModel.percentText(model.batteryPercent) }

    var body: some View {
        HStack(spacing: PanelMetrics.loose) {
            gauge
            VStack(alignment: .leading, spacing: 2) {
                switch size {
                case .compact:
                    Text(MenuStateModel.batteryHeadline(hasBattery: model.hasBattery, percent: model.batteryPercent))
                        .font(.headline)
                        .monospacedDigit()
                    chargingLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .hero:
                    chargingLine
                        .font(.headline)
                    Text(model.heroActivity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: size == .hero ? 76 : nil)
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

    @ViewBuilder private var gauge: some View {
        if model.hasBattery {
            switch size {
            case .compact:
                Gauge(value: MenuStateModel.gaugeFraction(model.batteryPercent)) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: model.isCharging ? PanelSymbol.charging : PanelSymbol.battery)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.8)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Battery")
                .accessibilityValue(percent)
            case .hero:
                Gauge(value: MenuStateModel.gaugeFraction(model.batteryPercent)) {
                    EmptyView()
                } currentValueLabel: {
                    Text(percent).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel("Battery")
                .accessibilityValue(percent)
            }
        } else {
            Image(systemName: PanelSymbol.desktop)
                .font(size == .hero ? .largeTitle : .title2)
                .foregroundStyle(.secondary)
                .frame(width: size == .hero ? 60 : 44, height: size == .hero ? 60 : 44)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - The ONE "Details" disclosure (tier 3)

/// The single disclosure control (chevron + "Details" + badge), placed by
/// `PanelFooterRow` on the left of the panel's last row. Toggling is pure
/// model state (never dismisses the menu); the height change snaps
/// (MenuPanelHostingView) and only the chevron turns — ≤150ms ease-out, none
/// under Reduce Motion. The content opens ABOVE the footer, so the expanded
/// chevron points UP at it (right ▸ collapsed, up ▴ expanded).
struct PanelDetailsDisclosure: View {
    @ObservedObject var model: MenuStateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = model.detailsExpanded
        let badge = model.detailsBadge
        Button {
            model.setDetailsExpanded(!expanded)
        } label: {
            // Hugs its content: the footer's Spacer separates it from Quit.
            HStack(spacing: PanelMetrics.regular) {
                Image(systemName: PanelSymbol.disclosure)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? -90 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                    .frame(width: PanelMetrics.symbolColumn)
                Text("Details")
                if let symbol = MenuStateModel.severitySymbol(badge) {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(PanelSeverityTint.color(badge))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Details")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(badge == .nominal
            ? "Shows lid-alert settings, Claude hook status, Pause detection and Launch at Login"
            : "Holds the setting for an item that needs attention, shown above")
        .accessibilityAddTraits(.isButton)
    }
}

/// Tier-3 content — IDENTICAL in every variant. Details-home lines go through
/// `TuckedLine`, so a non-nominal one is absent here (it renders above).
struct PanelDetailsContent: View {
    @ObservedObject var model: MenuStateModel
    /// Variant C keeps the nominal Claude status here (its hero line already
    /// says "Claude running"); A shows it at top level always.
    var includesClaudeStatus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.loose) {
            if model.lidGuardVisible {
                lidAlertGroup
            }
            if model.claudeDetectionVisible {
                claudeGroup
            }
            generalGroup
        }
    }

    private var lidAlertGroup: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            DetailsGroupHeader(title: "Lid alert")
            // The topic itself is never rendered — it is the password to the
            // feed. The model does not even expose it to views.
            TuckedLine(line: model.lidServerStatus)
            TuckedLine(line: model.lidTopicStatus)
            TuckedLine(line: model.lidLastSend(now: Date().timeIntervalSince1970))
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
    /// casual reach; while paused, the top-level Claude row says so.
    private var claudeGroup: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            DetailsGroupHeader(title: "Claude detection")
            if includesClaudeStatus {
                TuckedLine(line: model.claudeStatus)
            }
            TuckedLine(line: model.hookStatus)
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
            if MenuStateModel.placement(ofDetailsLine: model.launchAtLoginCaption?.severity ?? .nominal) == .details {
                LaunchAtLoginRow(model: model)
            }
            PanelStylePreviewRow(model: model)
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

/// CURATION-ONLY SCAFFOLD (remove at design freeze with MenuPanelStyle):
/// toggles the layout variant A ↔ C, persisted to `menuPanelStyle`.
struct PanelStylePreviewRow: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        HStack {
            Text("Panel style (preview)").font(.caption)
            Spacer(minLength: PanelMetrics.regular)
            Button(model.panelStyle.title) { model.cyclePanelStyle() }
                .controlSize(.small)
                .accessibilityLabel("Panel style (preview)")
                .accessibilityValue(model.panelStyle.title)
                .accessibilityHint("Switches to \(model.panelStyle.next.title)")
        }
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
