import SwiftUI

// The three layout variants of the menu panel — CURATION-ONLY SCAFFOLD
// (2026-10-18, PLAN.md "UI Redesign — Menu Panel (variant exploration)").
// Each arranges the SAME shared components (MenuPanelView.swift) and therefore
// renders identical MenuStateModel outputs; none of them decides what is a
// warning. Every variant MUST include the three surfaced-line components
// (`ClaudeSurfacedLines`, `LidAlertSurfacedLines`, `SurfacedLaunchAtLogin`) so
// that a non-nominal Details line always has a top-level home (lint-locked in
// MenuPanelStructureTests). At design freeze, keep one and delete the rest.

// MARK: - A — Quiet Rows

/// Single column: symbol + title + trailing control per row; captions ONLY
/// for non-nominal states; at most two Dividers; 4/8/12 rhythm.
struct QuietRowsPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.regular) {
            BatteryHeader(model: model)
            Divider()

            PanelRow(symbol: PanelSymbol.stayAwake, title: "Stay Awake") {
                StayAwakeToggle(model: model)
            }
            indentedCaption(model.stayAwakeCaption)
            PanelRow(symbol: PanelSymbol.lockScreen, title: "Lock Screen") {
                LockScreenButton(model: model)
            }
            indentedCaption(model.lockScreenCaption)

            // ADR §12: no battery → the charge-limit section is hidden
            // entirely, not disabled.
            if model.featureState != .hidden {
                PanelRow(symbol: PanelSymbol.chargeLimit, title: "Charge Limit") {
                    Text(MenuStateModel.chargeLimitValueText(limit: model.limit))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ChargeLimitToggle(model: model)
                }
                ChargeLimitSlider(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
                indentedCaption(model.chargeLimitCaption)
            }

            // Track B (absent in debugBattery mode).
            if model.claudeDetectionVisible {
                ClaudeStatusRow(model: model, showsSymbolColumn: true)
                ClaudeSurfacedLines(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
                if model.lidGuardVisible {
                    PanelRow(symbol: PanelSymbol.lidAlert, title: "Lid alert") {
                        LidAlertToggle(model: model)
                    }
                    indentedCaption(model.lidStatus)
                    LidAlertSurfacedLines(model: model)
                        .padding(.leading, PanelMetrics.titleIndent)
                }
            }

            if model.debugControlsVisible {
                DebugBatterySection(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
            }

            Divider()
            PanelDetailsDisclosure(model: model, usesSymbolColumn: true)
            if model.detailsExpanded {
                PanelDetailsContent(model: model, includesClaudeStatus: false)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
            SurfacedLaunchAtLogin(model: model)
                .padding(.leading, PanelMetrics.titleIndent)
            QuitFooter(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, PanelMetrics.loose)
    }

    /// Non-nominal captions only (A's rule), aligned with the row titles.
    @ViewBuilder private func indentedCaption(_ line: PanelLine?) -> some View {
        if let line {
            PanelCaptionLine(line: line, showsNominal: false)
                .padding(.leading, PanelMetrics.titleIndent)
        }
    }
}

// MARK: - B — Grouped Cards (default)

/// Three inset-grouped containers — Power, Claude, System — with caption
/// section headers. The ONE Details disclosure heads the System card (it is
/// also the only home in debugBattery mode, where the Claude card is absent).
struct GroupedCardsPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.regular) {
            PanelCard(title: "Power") {
                BatteryHeader(model: model)
                PanelRow(symbol: nil, title: "Stay Awake", subtitle: "Keep this Mac awake with the lid closed") {
                    StayAwakeToggle(model: model)
                }
                caption(model.stayAwakeCaption)
                PanelRow(symbol: nil, title: "Lock Screen", subtitle: "Lock now and turn the display off — the Mac keeps running") {
                    LockScreenButton(model: model)
                }
                caption(model.lockScreenCaption)
                if model.featureState != .hidden {
                    PanelRow(symbol: nil, title: "Charge Limit", subtitle: MenuStateModel.limitLabel(limit: model.limit)) {
                        ChargeLimitToggle(model: model)
                    }
                    ChargeLimitSlider(model: model)
                    caption(model.chargeLimitCaption)
                }
            }

            if model.claudeDetectionVisible {
                PanelCard(title: "Claude") {
                    ClaudeStatusRow(model: model, showsSymbolColumn: false)
                    ClaudeSurfacedLines(model: model)
                    if model.lidGuardVisible {
                        PanelRow(symbol: nil, title: "Lid alert") {
                            LidAlertToggle(model: model)
                        }
                        caption(model.lidStatus)
                        LidAlertSurfacedLines(model: model)
                    }
                }
            }

            if model.debugControlsVisible {
                PanelCard(title: "Debug — Simulated Battery") {
                    DebugBatterySection(model: model, showsTitle: false)
                }
            }

            PanelCard(title: "System") {
                PanelDetailsDisclosure(model: model, usesSymbolColumn: false)
                if model.detailsExpanded {
                    PanelDetailsContent(model: model, includesClaudeStatus: false)
                }
                SurfacedLaunchAtLogin(model: model)
                Divider()
                QuitFooter(model: model)
            }
        }
        .padding(PanelMetrics.cardPadding)
    }

    /// B shows nominal captions too; non-nominal ones get the icon.
    @ViewBuilder private func caption(_ line: PanelLine?) -> some View {
        if let line {
            PanelCaptionLine(line: line, showsNominal: true)
        }
    }
}

/// Inset-grouped container: caption header above a rounded quaternary fill.
struct PanelCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.tight) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, PanelMetrics.tight)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: PanelMetrics.regular) {
                content()
            }
            .padding(PanelMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
        }
    }
}

// MARK: - C — Status Hero

/// A ~76pt hero (full-size gauge + charging line + the composed activity
/// line), compact rows below, everything else in Details. The nominal Claude
/// status lives in Details here (the hero already says "Claude running"); a
/// paused state escapes to top level like every other problem.
struct StatusHeroPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.regular) {
            BatteryHeader(model: model, size: .hero)
            Divider()

            PanelRow(symbol: PanelSymbol.stayAwake, title: "Stay Awake") {
                StayAwakeToggle(model: model)
            }
            indentedCaption(model.stayAwakeCaption)
            PanelRow(symbol: PanelSymbol.lockScreen, title: "Lock Screen") {
                LockScreenButton(model: model)
            }
            indentedCaption(model.lockScreenCaption)
            if model.featureState != .hidden {
                PanelRow(symbol: PanelSymbol.chargeLimit, title: "Charge Limit") {
                    Text(MenuStateModel.chargeLimitValueText(limit: model.limit))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ChargeLimitToggle(model: model)
                }
                ChargeLimitSlider(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
                indentedCaption(model.chargeLimitCaption)
            }

            if model.claudeDetectionVisible {
                if MenuStateModel.placement(ofDetailsLine: model.claudeStatus.severity) == .topLevel {
                    ClaudeStatusRow(model: model, showsSymbolColumn: true)
                }
                ClaudeSurfacedLines(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
                if model.lidGuardVisible {
                    PanelRow(symbol: PanelSymbol.lidAlert, title: "Lid alert") {
                        LidAlertToggle(model: model)
                    }
                    indentedCaption(model.lidStatus)
                    LidAlertSurfacedLines(model: model)
                        .padding(.leading, PanelMetrics.titleIndent)
                }
            }

            if model.debugControlsVisible {
                DebugBatterySection(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
            }

            Divider()
            PanelDetailsDisclosure(model: model, usesSymbolColumn: true)
            if model.detailsExpanded {
                PanelDetailsContent(model: model, includesClaudeStatus: true)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
            SurfacedLaunchAtLogin(model: model)
                .padding(.leading, PanelMetrics.titleIndent)
            QuitFooter(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, PanelMetrics.loose)
    }

    @ViewBuilder private func indentedCaption(_ line: PanelLine?) -> some View {
        if let line {
            PanelCaptionLine(line: line, showsNominal: false)
                .padding(.leading, PanelMetrics.titleIndent)
        }
    }
}
