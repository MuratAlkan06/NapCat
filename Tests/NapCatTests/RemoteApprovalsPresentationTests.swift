// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// F4 slice S2: what the panel row and Settings › Claude say about remote
/// approvals — the pure mappings, table-tested. (Their USE in the views is
/// locked in RemoteApprovalsStructureTests; the iron rule and C2 checks in
/// MenuPanelPresentationTests and SettingsWindowTests include these lines.)
struct RemoteApprovalsPresentationTests {
    static let localOnly = PanelLine(text: "Local only — the iPhone app cannot answer prompts yet", severity: .info)
    static let notListening = PanelLine(
        text: "Not listening — the approvals socket could not be opened; prompts stay on this Mac", severity: .warning)

    // MARK: - The row's caption

    @Test func theRowCaptionPerPhase() {
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .off) == PanelLine(text: "Off", severity: .nominal))
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .listening) == Self.localOnly)
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .unavailable) == Self.notListening)
    }

    /// Off is a choice, so it stays out of the card; on — in this build
    /// always local only, or not even listening — shows under the row: the
    /// switch never sits ON in the panel without saying what it does.
    @Test(arguments: [RemoteApprovalsPhase.off, .listening, .unavailable])
    func onIsNeverSilentInThePanel(_ phase: RemoteApprovalsPhase) {
        let line = MenuStateModel.remoteApprovalsStatus(phase: phase)
        #expect((line.severity == .nominal) == (phase == .off), "\(phase): \(line)")
        #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == (phase == .off ? .settings : .topLevel))
    }

    // MARK: - The channel-policy line

    struct PolicyRow: Sendable, CustomTestStringConvertible {
        let finding: ChannelPolicyFinding
        let text: String
        let severity: PanelSeverity
        var testDescription: String { finding.rawValue }
    }

    static let policyRows: [PolicyRow] = [
        PolicyRow(finding: .noFilePolicy,
                  text: "Channel policy: no managed settings — each session still needs the development flag",
                  severity: .nominal),
        PolicyRow(finding: .defaultAllowlist,
                  text: "Channel policy: managed settings keep the default allowlist — each session still needs the "
                      + "development flag", severity: .nominal),
        PolicyRow(finding: .allowlistOmitsNapCat,
                  text: "Channel policy: the managed allowlist does not name NapCat — each session still needs the "
                      + "development flag", severity: .nominal),
        PolicyRow(finding: .allowlistNamesNapCat,
                  text: "Channel policy: the managed allowlist names NapCat — on an organization plan no development "
                      + "flag is needed", severity: .nominal),
        PolicyRow(finding: .channelsNotEnabled,
                  text: "Channel policy: managed settings do not enable channels — on an organization plan no session "
                      + "can relay prompts", severity: .info),
        PolicyRow(finding: .unreadable,
                  text: "Channel policy: managed settings could not be read — each session still needs the "
                      + "development flag", severity: .info),
    ]

    @Test(arguments: policyRows)
    func thePolicyLinePerReading(_ row: PolicyRow) throws {
        let line = try #require(MenuStateModel.remoteApprovalsPolicyLine(finding: row.finding))
        #expect(line == PanelLine(text: row.text, severity: row.severity))
        // Honest about the flag: only the allowlist that names NapCat says
        // it is not needed — and then only on an organization plan.
        #expect(line.text.contains("still needs the development flag") == (row.finding.developmentFlagNeeded
                                                                            && row.finding != .channelsNotEnabled))
    }

    @Test func noReadingIsNoLine() {
        #expect(MenuStateModel.remoteApprovalsPolicyLine(finding: nil) == nil)
        #expect(Set(Self.policyRows.map(\.finding)) == Set(ChannelPolicyFinding.allCases)
                && Self.policyRows.count == ChannelPolicyFinding.allCases.count, "vacuity: every reading has one row")
    }

    // MARK: - Settings › Claude

    static let status = PanelLine(text: "Claude: idle", severity: .nominal)
    static let hook = PanelLine(text: "Busy hook: last seen 1m ago", severity: .nominal)

    static func pane(_ approvals: (isOn: Bool, status: PanelLine, policy: PanelLine?)?) -> SettingsPaneContent {
        MenuStateModel.claudePane(status: Self.status, hook: Self.hook, hookVersion: nil, awake: nil, paused: false,
                                  approvals: approvals)
    }

    /// The group comes last, titled like the row; off shows the switch and
    /// what it does, on adds its status, and a reading adds its line.
    @Test func theRemoteApprovalsGroup() throws {
        let hint = MenuStateModel.remoteApprovalsHint
        let without = Self.pane(nil)
        #expect(without.sections.map(\.title) == ["Detection", "Busy hook"], "no toggle (debugBattery): no group")

        let off = Self.pane((isOn: false, status: PanelLine(text: "Off", severity: .nominal), policy: nil))
        #expect(off.sections.map(\.title) == ["Detection", "Busy hook", "Remote approvals"])
        #expect(off.sections.last?.rows == [.remoteApprovals(isOn: false, caption: nil, hint: hint)])

        let policy = try #require(MenuStateModel.remoteApprovalsPolicyLine(finding: .noFilePolicy))
        let on = Self.pane((isOn: true, status: Self.localOnly, policy: policy))
        #expect(on.sections.last?.rows == [.remoteApprovals(isOn: true, caption: Self.localOnly, hint: hint), .line(policy)])
        #expect(Array(on.sections.prefix(2)) == Array(without.sections), "the rest of the pane is unchanged")
        #expect(on.footnote == nil)
    }

    /// The words: what it does, what never leaves the Mac, that the terminal
    /// keeps working, and that off is the kill switch. Never the alert topic's
    /// lane (ntfy carries no approval semantics).
    @Test func theCopy() {
        #expect(MenuStateModel.remoteApprovalsToggleTitle == "Remote approvals")
        #expect(MenuStateModel.remoteApprovalsSettingsToggleTitle == "Answer permission prompts from iPhone",
                "the Settings switch says what it does, not the group title again")
        let hint = MenuStateModel.remoteApprovalsHint
        for phrase in ["iPhone", "terminal dialog always stays answerable", "never leave this Mac",
                       "Off withdraws every prompt"] {
            #expect(hint.contains(phrase), "the hint must say '\(phrase)'")
        }
        let texts = [hint, MenuStateModel.remoteApprovalsAccessibilityLabel, MenuStateModel.remoteApprovalsSettingsToggleTitle,
                     Self.localOnly.text, Self.notListening.text]
            + Self.policyRows.map(\.text)
        for text in texts {
            #expect(!text.lowercased().contains("ntfy"), "'\(text)' — approvals never ride the ntfy lane")
            #expect(!text.contains("CloudKit"), "'\(text)' — user words, not the transport")
        }
        #expect(MenuStateModel.remoteApprovalsToggleTitle.split(separator: " ").count == 2,
                "C1: the panel row adds two words")
    }

    @Test func theRowSymbolResolvesAndIsItsOwn() {
        #expect(PanelSymbol.all.contains(PanelSymbol.remoteApprovals))
        #expect(NSImage(systemSymbolName: PanelSymbol.remoteApprovals, accessibilityDescription: nil) != nil)
        #expect(![PanelSymbol.lidAlert, PanelSymbol.sessionAlerts].contains(PanelSymbol.remoteApprovals))
    }
}
