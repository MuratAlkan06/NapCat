import SwiftUI

/// Rich menu content (P3b user decision), hosted by an NSHostingView inside
/// a single NSMenuItem (MenuContentView). System materials and semantic
/// colors only — the menu chrome supplies the background, so dark/light
/// appearance follows automatically.
struct MenuPanelView: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            stayAwakeSection
            // ADR §12: no battery → the charge-limit section is hidden
            // entirely, not disabled.
            if model.featureState != .hidden {
                Divider()
                chargeLimitSection
            }
            // Track B: READ-ONLY Claude detection (absent in debugBattery mode).
            if model.claudeDetectionVisible {
                Divider()
                claudeSection
            }
            if model.debugControlsVisible {
                Divider()
                debugSection
            }
            Divider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300)
    }

    // MARK: Header — battery gauge + live charging state

    private var header: some View {
        HStack(spacing: 12) {
            if model.hasBattery {
                Gauge(value: MenuStateModel.gaugeFraction(model.batteryPercent)) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: model.isCharging ? "bolt.fill" : "battery.100")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .scaleEffect(0.8)
                .frame(width: 44, height: 44)
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(MenuStateModel.batteryHeadline(hasBattery: model.hasBattery, percent: model.batteryPercent))
                    .font(.headline)
                Text(MenuStateModel.chargingStatusLine(
                    hasBattery: model.hasBattery,
                    percent: model.batteryPercent,
                    isCharging: model.isCharging,
                    adapterConnected: model.adapterConnected
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Stay awake

    private var stayAwakeBinding: Binding<Bool> {
        Binding(
            get: { MenuStateModel.stayAwakeToggle(forObserved: model.stayAwakeObserved).isOn },
            set: { model.setStayAwake($0) }
        )
    }

    private var stayAwakeSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stay Awake")
                    Text("Keep this Mac awake with the lid closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Stay Awake", isOn: stayAwakeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let caption = MenuStateModel.stayAwakeToggle(forObserved: model.stayAwakeObserved).caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Charge limit

    private var limitEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.limitEnabled },
            set: { model.setLimitEnabled($0) }
        )
    }

    private var limitBinding: Binding<Double> {
        Binding(
            get: { Double(model.limit) },
            set: { model.setLimit(Int($0.rounded())) }
        )
    }

    /// Intel: permanently unavailable → controls disabled with explanation.
    /// setupRequired: controls stay usable (intent persists; setup message
    /// explains why nothing happens yet).
    private var chargeControlsDisabled: Bool { model.featureState == .notSupported }

    private var messageColor: Color {
        switch model.featureState {
        case .error: return .red
        case .setupRequired: return .orange
        default: return .secondary
        }
    }

    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charge Limit")
                    Text(MenuStateModel.limitLabel(limit: model.limit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Charge Limit", isOn: limitEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(chargeControlsDisabled)
            }
            Slider(value: limitBinding, in: 50...100, step: Double(ChargeLimiter.limitStep)) {
                EmptyView()
            } minimumValueLabel: {
                Text("50%").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("100%").font(.caption2).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .disabled(chargeControlsDisabled || !model.limitEnabled)
            if let message = MenuStateModel.featureMessage(for: model.featureState) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(messageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Claude detection (READ-ONLY; pause toggle = kill switch)

    private var pauseDetectionBinding: Binding<Bool> {
        Binding(
            get: { model.claudeDetectionPaused },
            set: { model.setDetectionPaused($0) }
        )
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(MenuStateModel.claudeTaskLine(
                inFlight: model.claudeTaskInFlight,
                paused: model.claudeDetectionPaused
            ))
            .font(.caption)
            Text(MenuStateModel.claudeAwakeLine(holding: model.claudeHoldingAwake))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(MenuStateModel.claudeHookLine(
                installed: model.claudeHookInstalled,
                everSeen: model.claudeHookEverSeen,
                lastSeenSeconds: model.claudeHookLastSeenSeconds
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Pause detection").font(.caption)
                Spacer()
                Toggle("Pause detection", isOn: pauseDetectionBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            // B2 delivery controls (absent in debugBattery mode, like the
            // detection block above).
            if model.lidGuardVisible {
                lidAlertBlock
            }
        }
    }

    // MARK: Lid-close alert (B2 — notify only, best effort)

    private var lidAlertEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.lidGuardEnabled },
            set: { model.setLidGuardEnabled($0) }
        )
    }

    private var lidAlertBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notify me if the Mac sleeps mid-task").font(.caption)
                    Text(MenuStateModel.lidAlertStatusLine(
                        for: model.lidGuardArming,
                        lastOutcome: model.lidGuardLastOutcome
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Notify me if the Mac sleeps mid-task", isOn: lidAlertEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            // The topic itself is never rendered here — it is the password to
            // the feed (see MenuStateModel.lidAlertTopicLine).
            Text(MenuStateModel.lidAlertTopicLine(model.lidGuardTopic))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(MenuStateModel.lidAlertServerLine(model.lidGuardServer))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("ntfy settings…") { model.editLidGuardSettings() }
                    .controlSize(.small)
                Button("Send test message") { model.sendLidGuardTestMessage() }
                    .controlSize(.small)
                    .disabled(!MenuStateModel.lidAlertTestSendAvailable(
                        server: model.lidGuardServer,
                        topic: model.lidGuardTopic
                    ))
            }
            Text(MenuStateModel.lidAlertLastSendCaption(
                outcome: model.lidGuardLastOutcome,
                at: model.lidGuardLastOutcomeAt,
                now: Date().timeIntervalSince1970
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(MenuStateModel.lidAlertTopicSecrecyNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Debug (debugBattery mode only)

    private var debugPercentBinding: Binding<Double> {
        Binding(
            get: { Double(model.batteryPercent ?? 0) },
            set: { model.setSimulatedPercent(Int($0.rounded())) }
        )
    }

    private var debugAdapterBinding: Binding<Bool> {
        Binding(
            get: { model.adapterConnected },
            set: { model.setSimulatedAdapter($0) }
        )
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug — Simulated Battery")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: debugPercentBinding, in: 0...100, step: 1)
                    .controlSize(.small)
                Text(MenuStateModel.percentText(model.batteryPercent))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                Text("AC adapter connected").font(.caption)
                Spacer()
                Toggle("AC adapter connected", isOn: debugAdapterBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    // MARK: Footer

    /// SMAppService is the source of truth — the checkbox renders the
    /// OBSERVED status (refreshed on menu open), never a stored flag.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { MenuStateModel.launchAtLoginPresentation(for: model.loginItemStatus).isOn },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var footer: some View {
        let presentation = MenuStateModel.launchAtLoginPresentation(for: model.loginItemStatus)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                Button("Quit NapCat") { model.quit() }
                    .controlSize(.small)
                    .keyboardShortcut("q", modifiers: .command)
            }
            if let caption = presentation.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.showSettingsShortcut {
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .font(.caption2)
            }
        }
    }
}
