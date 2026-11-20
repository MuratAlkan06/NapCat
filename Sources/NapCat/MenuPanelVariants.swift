import SwiftUI

// The menu panel's ONE layout. Panel 2.0 (owner pick "c cards", 2026-11-20)
// superseded the 2026-10-18 Quiet Rows freeze. The file name is kept from the
// 2026-10-18 curation round so the scanned-file lints stay stable.
// The layout arranges the shared components (MenuPanelView.swift) and never
// decides what is a warning. It MUST include the five surfaced-line
// components (`ClaudeSurfacedLines`, `LidAlertSurfacedLines`,
// `SessionAlertsSurfacedLines`, `GeneralSurfacedLines`,
// `SurfacedLaunchAtLogin`) OUTSIDE the cards, so that a non-nominal Settings
// line always has a top-level home, and must END with `PanelFooterRow` (the
// Settings gear, the Claude status caption, then Quit), also outside the
// cards (lint-locked in MenuPanelStructureTests).

// MARK: - Grouped Cards

/// Two cards and a footer. The Power card: the battery header (the Lock
/// Screen icon in its top-right corner), Stay Awake, Charge Limit. The
/// Alerts card, under its group header: Lid alert, Session alerts. Captions
/// ONLY for non-nominal states, inside the card under their row; the
/// surfaced Settings lines below the cards; the footer last. 4/8/12 rhythm.
///
/// No "Power" header (a judgment call the owner left open): the card's first
/// line is the panel's one headline, "Battery N%", which already names the
/// group — a caption-sized "Power" above it would title the same card twice
/// and put a second label above the panel's anchor. "Alerts" stays: nothing
/// inside that card names the group, and it marks where the opt-in
/// notifications begin.
struct GroupedCardsPanel: View {
    @ObservedObject var model: MenuStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            PanelCard {
                // The hero-size gauge (curation round 2) with the "Battery
                // N%" headline + charging line, and the charge-state glyph
                // inside the ring.
                BatteryHeader(model: model)

                PanelFeature {
                    PanelRow(symbol: PanelSymbol.stayAwake, title: "Stay Awake") {
                        StayAwakeToggle(model: model)
                    }
                    // The Stay Awake slot: unreadable > "Turning on…" (ruling
                    // e, the one nominal caption here) —
                    // MenuStateModel.stayAwakeSlot.
                    StayAwakeCaptionSlot(model: model, turnOn: model.stayAwakeTurnOn)
                        .padding(.leading, PanelMetrics.titleIndent)
                }

                // ADR §12: no battery → the charge-limit row is hidden
                // entirely, not disabled. The slider lives in Settings.
                if model.featureState != .hidden {
                    PanelFeature {
                        PanelRow(symbol: PanelSymbol.chargeLimit, title: "Charge Limit") {
                            ChargeLimitValue(model: model)
                            ChargeLimitToggle(model: model)
                        }
                        indentedCaption(model.chargeLimitCaption)
                    }
                }
            }

            // Track B + C (absent in debugBattery mode). The Claude status
            // itself is the footer's caption, not a row here.
            if model.claudeDetectionVisible && model.lidGuardVisible {
                PanelGroup(title: "Alerts") {
                    PanelFeature {
                        PanelRow(symbol: PanelSymbol.lidAlert, title: "Lid alert") {
                            LidAlertToggle(model: model)
                        }
                        indentedCaption(model.lidStatus)
                    }
                    // Track C: directly under the Lid alert row — same shape.
                    if model.finishAlertVisible {
                        PanelFeature {
                            PanelRow(symbol: PanelSymbol.sessionAlerts, title: "Session alerts") {
                                SessionAlertsToggle(model: model)
                            }
                            // The session-alerts slot: the alert-healing
                            // offline warning takes it while offline (offline
                            // > 429 hold > nominal —
                            // MenuStateModel.sessionAlertsSlot).
                            indentedCaption(model.finishAlertStatus)
                        }
                    }
                }
            }

            if model.debugControlsVisible {
                DebugBatterySection(model: model)
            }

            // The top-level home of every Settings line that can be a
            // problem, OUTSIDE the cards and right above the gear that opens
            // their Settings pane. Each renders only while non-nominal.
            if model.claudeDetectionVisible {
                ClaudeSurfacedLines(model: model)
                if model.lidGuardVisible {
                    LidAlertSurfacedLines(model: model)
                }
                if model.finishAlertVisible {
                    SessionAlertsSurfacedLines(model: model)
                }
            }
            GeneralSurfacedLines(model: model)
            SurfacedLaunchAtLogin(model: model)
            PanelFooterRow(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, PanelMetrics.loose)
    }

    /// Non-nominal captions only, aligned with the row titles.
    @ViewBuilder private func indentedCaption(_ line: PanelLine?) -> some View {
        if let line {
            PanelCaptionLine(line: line, showsNominal: false)
                .padding(.leading, PanelMetrics.titleIndent)
        }
    }
}
