import SwiftUI

// The layout variants of the menu panel — CURATION-ONLY SCAFFOLD
// (2026-10-18, PLAN.md "UI Redesign — Menu Panel (variant exploration)").
// Each arranges the SAME shared components (MenuPanelView.swift) and therefore
// renders identical MenuStateModel outputs; none of them decides what is a
// warning. Every variant MUST include the three surfaced-line components
// (`ClaudeSurfacedLines`, `LidAlertSurfacedLines`, `SurfacedLaunchAtLogin`) so
// that a non-nominal Details line always has a top-level home, and must END
// with `PanelFooterRow` (the one Details disclosure + Quit), with expanded
// Details content above it (lint-locked in MenuPanelStructureTests).
// Curation round 1 scrapped variant B "Grouped Cards"; at design freeze, keep
// one of A / C and delete the other.

// MARK: - A — Quiet Rows

/// Single column: symbol + title + trailing control per row; captions ONLY
/// for non-nominal states; at most two Dividers; 4/8/12 rhythm.
struct QuietRowsPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            // Curation round 2: the same hero-size gauge as C (fair A-vs-C
            // comparison), with A's own headline + charging-line text and
            // the charge-state glyph inside the ring.
            BatteryHeader(model: model, size: .hero)
            Divider()

            PanelFeature {
                PanelRow(symbol: PanelSymbol.stayAwake, title: "Stay Awake") {
                    StayAwakeToggle(model: model)
                }
                indentedCaption(model.stayAwakeCaption)
            }
            PanelFeature {
                PanelRow(symbol: PanelSymbol.lockScreen, title: "Lock Screen") {
                    LockScreenButton(model: model)
                }
                indentedCaption(model.lockScreenCaption)
            }

            // ADR §12: no battery → the charge-limit section is hidden
            // entirely, not disabled.
            if model.featureState != .hidden {
                PanelFeature {
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
            }

            // Track B (absent in debugBattery mode).
            if model.claudeDetectionVisible {
                PanelFeature {
                    ClaudeStatusRow(model: model)
                    ClaudeSurfacedLines(model: model)
                        .padding(.leading, PanelMetrics.titleIndent)
                }
                if model.lidGuardVisible {
                    PanelFeature {
                        PanelRow(symbol: PanelSymbol.lidAlert, title: "Lid alert") {
                            LidAlertToggle(model: model)
                        }
                        indentedCaption(model.lidStatus)
                        LidAlertSurfacedLines(model: model)
                            .padding(.leading, PanelMetrics.titleIndent)
                    }
                }
            }

            if model.debugControlsVisible {
                DebugBatterySection(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
            }

            Divider()
            // Details opens ABOVE the footer row, which always closes the panel.
            if model.detailsExpanded {
                PanelDetailsContent(model: model, includesClaudeStatus: false)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
            SurfacedLaunchAtLogin(model: model)
                .padding(.leading, PanelMetrics.titleIndent)
            PanelFooterRow(model: model)
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

// MARK: - C — Status Hero

/// A ~76pt hero (full-size gauge + charging line + the composed activity
/// line), compact rows below, everything else in Details. The nominal Claude
/// status lives in Details here (the hero already says "Claude running"); a
/// paused state escapes to top level like every other problem.
struct StatusHeroPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            BatteryHeader(model: model, size: .hero, content: .activity)
            Divider()

            PanelFeature {
                PanelRow(symbol: PanelSymbol.stayAwake, title: "Stay Awake") {
                    StayAwakeToggle(model: model)
                }
                indentedCaption(model.stayAwakeCaption)
            }
            PanelFeature {
                PanelRow(symbol: PanelSymbol.lockScreen, title: "Lock Screen") {
                    LockScreenButton(model: model)
                }
                indentedCaption(model.lockScreenCaption)
            }
            if model.featureState != .hidden {
                PanelFeature {
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
            }

            if model.claudeDetectionVisible {
                // The status row is conditional here, so it only forms a
                // feature block when present (an empty block would leave a gap).
                if MenuStateModel.placement(ofDetailsLine: model.claudeStatus.severity) == .topLevel {
                    PanelFeature {
                        ClaudeStatusRow(model: model)
                        ClaudeSurfacedLines(model: model)
                            .padding(.leading, PanelMetrics.titleIndent)
                    }
                } else {
                    ClaudeSurfacedLines(model: model)
                        .padding(.leading, PanelMetrics.titleIndent)
                }
                if model.lidGuardVisible {
                    PanelFeature {
                        PanelRow(symbol: PanelSymbol.lidAlert, title: "Lid alert") {
                            LidAlertToggle(model: model)
                        }
                        indentedCaption(model.lidStatus)
                        LidAlertSurfacedLines(model: model)
                            .padding(.leading, PanelMetrics.titleIndent)
                    }
                }
            }

            if model.debugControlsVisible {
                DebugBatterySection(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
            }

            Divider()
            // Details opens ABOVE the footer row, which always closes the panel.
            if model.detailsExpanded {
                PanelDetailsContent(model: model, includesClaudeStatus: true)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
            SurfacedLaunchAtLogin(model: model)
                .padding(.leading, PanelMetrics.titleIndent)
            PanelFooterRow(model: model)
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
