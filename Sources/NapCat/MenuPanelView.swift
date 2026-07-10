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

    private var footer: some View {
        HStack {
            Toggle("Launch at Login", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(true) // Wired up in Phase 5 (SMAppService).
            Spacer()
            Button("Quit NapCat") { model.quit() }
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
