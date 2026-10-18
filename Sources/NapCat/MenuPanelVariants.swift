import SwiftUI

// The menu panel's ONE layout (PLAN.md "UI Redesign — Menu Panel").
// Design freeze 2026-10-18: of the curation variants the user kept A "Quiet
// Rows" ("the version that has the icon"); B "Grouped Cards" (round 1) and
// C "Status Hero" (freeze) were deleted. The file name is kept from that
// exploration so the scanned-file lints stay stable.
// The layout arranges the shared components (MenuPanelView.swift) and never
// decides what is a warning. It MUST include the three surfaced-line
// components (`ClaudeSurfacedLines`, `LidAlertSurfacedLines`,
// `SurfacedLaunchAtLogin`) so that a non-nominal Details line always has a
// top-level home, and must END with `PanelFooterRow` (the one Details
// disclosure + Quit), with expanded Details content above it (lint-locked in
// MenuPanelStructureTests).

// MARK: - Quiet Rows

/// Single column: symbol + title + trailing control per row; captions ONLY
/// for non-nominal states; at most two Dividers; 4/8/12 rhythm.
struct QuietRowsPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            // The hero-size gauge (curation round 2) with the "Battery N%"
            // headline + charging line, and the charge-state glyph inside
            // the ring.
            BatteryHeader(model: model)
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
                PanelDetailsContent(model: model)
                    .padding(.leading, PanelMetrics.titleIndent)
            }
            SurfacedLaunchAtLogin(model: model)
                .padding(.leading, PanelMetrics.titleIndent)
            PanelFooterRow(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, PanelMetrics.loose)
    }

    /// Non-nominal captions only (Quiet Rows' rule), aligned with the row
    /// titles.
    @ViewBuilder private func indentedCaption(_ line: PanelLine?) -> some View {
        if let line {
            PanelCaptionLine(line: line, showsNominal: false)
                .padding(.leading, PanelMetrics.titleIndent)
        }
    }
}
