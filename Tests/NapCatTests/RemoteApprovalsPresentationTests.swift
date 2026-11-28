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
    static let notListening = PanelLine(text: "Not listening — could not start; reopen the menu to retry", severity: .warning)
    /// #205: on, with no iPhone paired.
    static let notPaired = PanelLine(text: "Not paired — pair your iPhone in Settings › Claude", severity: .info)
    /// Every answer `RemoteApprovalsPolicy.hold` can give.
    static let holds: [RemoteApprovalsHold?] = [nil, .off, .notPaired, .noRecordPath]

    // MARK: - The row's caption

    @Test func theRowCaptionPerPhase() {
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .off, hold: .off) == PanelLine(text: "Off", severity: .nominal))
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .listening, hold: .noRecordPath) == Self.localOnly)
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .unavailable, hold: .noRecordPath) == Self.notListening)
        // The warning in user words with its next step (a menu or Settings
        // open retries: anUnusableSocketIsUnavailableAndRetriedOnRefresh), as
        // short as the panel's other warnings.
        let warning = Self.notListening.text
        #expect(!warning.contains("socket") && warning.hasSuffix("reopen the menu to retry"))
        #expect(warning.split(separator: " ").filter { $0 != "—" }.count <= 10, "'\(warning)' is longer than the others")
    }

    /// #205: listening with no iPhone paired, the row says to pair one
    /// first, and where (the pairing lives in Settings › Claude); paired,
    /// it is local only as before. A socket that could not be opened is
    /// still the line to show. Nothing held at all still reads local only:
    /// the host stays unarmed in this build.
    @Test func theRowSaysToPairTheIPhoneFirst() {
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .listening, hold: .notPaired) == Self.notPaired)
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .unavailable, hold: .notPaired) == Self.notListening)
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .off, hold: .notPaired) == PanelLine(text: "Off", severity: .nominal))
        #expect(MenuStateModel.remoteApprovalsStatus(phase: .listening, hold: nil) == Self.localOnly)
        let words: [Substring] = Self.notPaired.text.split(separator: " ").filter { $0 != "—" }
        #expect(Self.notPaired.text.hasPrefix("Not paired — ") && Self.notPaired.text.contains("in Settings"))
        #expect(words.count <= 10, "'\(Self.notPaired.text)' is longer than the others")
    }

    /// Off is a choice, so it stays out of the card; on — in this build
    /// always local only, waiting for a pairing, or not even listening —
    /// shows under the row: the switch never sits ON in the panel without
    /// saying what it does.
    @Test(arguments: [RemoteApprovalsPhase.off, .listening, .unavailable])
    func onIsNeverSilentInThePanel(_ phase: RemoteApprovalsPhase) {
        for hold in Self.holds {
            let line = MenuStateModel.remoteApprovalsStatus(phase: phase, hold: hold)
            #expect((line.severity == .nominal) == (phase == .off), "\(phase), \(String(describing: hold)): \(line)")
            #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == (phase == .off ? .settings : .topLevel))
        }
    }

    // MARK: - The channel-policy line

    struct PolicyRow: Sendable, CustomTestStringConvertible {
        let finding: ChannelPolicyFinding
        let text: String
        let severity: PanelSeverity
        var testDescription: String { finding.rawValue }
    }

    /// Every reading is a Settings fact in this slice (nominal: nothing in
    /// the panel), in plain words — the development flag is "the preview
    /// option" (`remoteApprovalsPolicyLine` says why none is a problem yet).
    static let policyRows: [PolicyRow] = [
        PolicyRow(finding: .noFilePolicy,
                  text: "Claude Code policy: no file on this Mac — each session must start with the preview option",
                  severity: .nominal),
        PolicyRow(finding: .defaultAllowlist,
                  text: "Claude Code policy: Anthropic's channel list applies — each session must start with the "
                      + "preview option", severity: .nominal),
        PolicyRow(finding: .allowlistOmitsNapCat,
                  text: "Claude Code policy: the organization's channel list leaves out NapCat — each session must "
                      + "start with the preview option", severity: .nominal),
        PolicyRow(finding: .allowlistNamesNapCat,
                  text: "Claude Code policy: the organization's channel list includes NapCat — on that plan, sessions "
                      + "need no preview option", severity: .nominal),
        PolicyRow(finding: .channelsNotEnabled,
                  text: "Claude Code policy: channels turned off — on an organization plan, no session can reach NapCat",
                  severity: .nominal),
        PolicyRow(finding: .unreadable,
                  text: "Claude Code policy: unclear to NapCat — each session must start with the preview option",
                  severity: .nominal),
    ]

    @Test(arguments: policyRows)
    func thePolicyLinePerReading(_ row: PolicyRow) throws {
        let line = try #require(MenuStateModel.remoteApprovalsPolicyLine(finding: row.finding))
        #expect(line == PanelLine(text: row.text, severity: row.severity))
        // Honest about the option: only the allowlist that names NapCat says
        // it is not needed — and then only on that organization's plan.
        #expect(line.text.contains("each session must start with the preview option")
                == (row.finding.developmentFlagNeeded && row.finding != .channelsNotEnabled))
        // Settings only: the panel's twin never renders a reading in this
        // slice, and the gear badge does not count one.
        #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == .settings)
        // Plain words: none of the admin and command-line jargon.
        for jargon in ["flag", "allowlist", "managed settings", "Channel policy", "relay"] {
            #expect(!line.text.contains(jargon), "'\(line.text)' says '\(jargon)'")
        }
    }

    @Test func noReadingIsNoLine() {
        #expect(MenuStateModel.remoteApprovalsPolicyLine(finding: nil) == nil)
        #expect(Set(Self.policyRows.map(\.finding)) == Set(ChannelPolicyFinding.allCases)
                && Self.policyRows.count == ChannelPolicyFinding.allCases.count, "vacuity: every reading has one row")
    }

    // MARK: - Settings › Claude

    static let status = PanelLine(text: "Claude: idle", severity: .nominal)
    static let hook = PanelLine(text: "Busy hook: last seen 1m ago", severity: .nominal)

    static func pane(_ approvals: (isOn: Bool, status: PanelLine, policy: PanelLine?)?,
                     pairing: PairingPaneState? = nil) -> SettingsPaneContent {
        MenuStateModel.claudePane(status: Self.status, hook: Self.hook, hookVersion: nil, awake: nil, paused: false,
                                  approvals: approvals, pairing: pairing)
    }

    /// The group comes last, titled like the row; off shows the switch and
    /// what it does, on adds its status, and a reading adds its line. The
    /// Advanced section (#252) closes it either way.
    @Test func theRemoteApprovalsGroup() throws {
        let hint = MenuStateModel.remoteApprovalsHint
        let advanced = MenuStateModel.approvalsAdvancedRow
        let without = Self.pane(nil)
        #expect(without.sections.map(\.title) == ["Detection", "Busy hook"], "no toggle (debugBattery): no group")

        let off = Self.pane((isOn: false, status: PanelLine(text: "Off", severity: .nominal), policy: nil))
        #expect(off.sections.map(\.title) == ["Detection", "Busy hook", "Remote approvals"])
        #expect(off.sections.last?.rows == [.remoteApprovals(isOn: false, caption: nil, hint: hint), advanced])

        let policy = try #require(MenuStateModel.remoteApprovalsPolicyLine(finding: .noFilePolicy))
        let on = Self.pane((isOn: true, status: Self.localOnly, policy: policy))
        #expect(on.sections.last?.rows == [.remoteApprovals(isOn: true, caption: Self.localOnly, hint: hint), .line(policy),
                                           advanced])
        #expect(Array(on.sections.prefix(2)) == Array(without.sections), "the rest of the pane is unchanged")
        #expect(on.footnote == nil)
    }

    /// #252: the Advanced section closes the group in every state the
    /// pane's inputs can take — the switch off or on, each caption its
    /// mapping gives (every phase, every hold), each reading or none, each
    /// pairing state or no pairing controller — as ONE constant: its rows
    /// in order, the three kinds' switches off and the iPhone checkbox
    /// ticked. Nothing about the group reaches it; the row carries no
    /// enabled flag, and the view draws every control in it disabled
    /// (SettingsWindowTests). No toggle (debugBattery): no group, no
    /// section.
    @Test func theAdvancedSectionClosesTheGroupTheSameInEveryState() throws {
        let advanced = MenuStateModel.approvalsAdvancedRow
        guard case let .approvalsAdvanced(title, intro, unavailable, switches, phone, never) = advanced else {
            Issue.record("the section's row is not .approvalsAdvanced: \(advanced)")
            return
        }
        #expect([title, intro, unavailable]
                == [MenuStateModel.advancedTitle, MenuStateModel.advancedIntro, MenuStateModel.advancedUnavailable])
        #expect(switches == [
            SettingsFixedToggle(title: MenuStateModel.advancedAdminTitle, caption: MenuStateModel.advancedAdminCaption,
                                isOn: false),
            SettingsFixedToggle(title: MenuStateModel.advancedClaudeSettingsTitle,
                                caption: MenuStateModel.advancedClaudeSettingsCaption, isOn: false),
            SettingsFixedToggle(title: MenuStateModel.advancedSecretsTitle, caption: MenuStateModel.advancedSecretsCaption,
                                isOn: false),
        ])
        #expect(phone == SettingsFixedToggle(title: MenuStateModel.advancedPhoneTitle,
                                             caption: MenuStateModel.advancedPhoneCaption, isOn: true))
        #expect(never == MenuStateModel.advancedNeverSent)
        #expect(switches.allSatisfy { !$0.isOn } && phone.isOn, "the switches off, the checkbox ticked")

        let code = try #require(PairingFingerprint(lowercaseHex: "8a2c854aa45c"))
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let pairings: [PairingPaneState?] = [nil, .notPaired, .pairing, .paired(code, since: since),
                                             .rotating(code, since: since), .unpairFailed]
        let readings: [PanelLine?] = [nil] + ChannelPolicyFinding.allCases.map { MenuStateModel.remoteApprovalsPolicyLine(finding: $0) }
        let isAdvanced = { (row: SettingsRow) -> Bool in if case .approvalsAdvanced = row { true } else { false } }
        var states = 0
        for isOn in [false, true] {
            for phase in [RemoteApprovalsPhase.off, .listening, .unavailable] {
                for hold in Self.holds {
                    let caption = MenuStateModel.remoteApprovalsStatus(phase: phase, hold: hold)
                    for reading in readings {
                        for pairing in pairings {
                            let pane = Self.pane((isOn: isOn, status: caption, policy: reading), pairing: pairing)
                            let rows = pane.sections.last?.rows ?? []
                            let all = pane.sections.flatMap(\.rows)
                            let state = [String(describing: isOn), String(describing: phase), String(describing: hold),
                                         String(describing: reading), String(describing: pairing)].joined(separator: ", ")
                            #expect(rows.last == advanced && all.filter(isAdvanced).count == 1, "\(state)")
                            states += 1
                        }
                    }
                }
            }
        }
        #expect(states == 2 * 3 * Self.holds.count * readings.count * pairings.count && readings.count == 7,
                "vacuity: every state was composed — \(states)")
        for pairing in pairings {
            #expect(!Self.pane(nil, pairing: pairing).sections.flatMap(\.rows).contains(where: isAdvanced),
                    "no toggle, no section — \(String(describing: pairing))")
        }
    }

    /// The words: what it does today, the one change it makes you can see,
    /// what would stay on the Mac (what the gate recognizes, named as a
    /// fixed list, and every Read, whatever file it names), that the gate
    /// reads the prompt and not what a command goes on to do, that the
    /// terminal keeps working, and that off is the kill switch. Never the
    /// alert topic's lane (ntfy carries no approval semantics). Honest
    /// while OFF: no switch name and no hint sentence promises the iPhone
    /// half this build does not have. Honest about the gate: no absolute
    /// "never leave" that a list could not keep.
    @Test func theCopy() {
        #expect(MenuStateModel.remoteApprovalsToggleTitle == "Remote approvals")
        #expect(MenuStateModel.remoteApprovalsSettingsToggleTitle == "Mac-only preview",
                "the Settings switch says what it turns on today, not the group title again")
        #expect(MenuStateModel.remoteApprovalsAccessibilityLabel == "Remote approvals, Mac-only preview")
        let hint = MenuStateModel.remoteApprovalsHint
        #expect(hint == "NapCat listens for permission prompts from Claude Code sessions set up for it, and keeps "
                + "every one on this Mac. A waiting push can count some of them by kind (“— 1 Bash permission "
                + "prompt”). Prompts NapCat's gate recognizes as privileged, settings or secret — a fixed list of "
                + "commands and locations — are never counted, and would stay on this Mac even if a later version let "
                + "the iPhone app answer. Read prompts are never counted either, and would stay on this Mac too, "
                + "whatever file they name. The gate reads the prompt, not what a command goes on to do. The terminal "
                + "dialog always stays answerable. Off withdraws every prompt at once.")
        for phrase in ["keeps every one on this Mac", "A waiting push can count some of them", "1 Bash permission prompt",
                       "recognizes as privileged, settings or secret", "a fixed list of commands and locations",
                       "are never counted, and would stay on this Mac", "even if a later version",
                       "Read prompts are never counted either", "whatever file they name",
                       "The gate reads the prompt, not what a command goes on to do",
                       "terminal dialog always stays answerable", "Off withdraws every prompt"] {
            #expect(hint.contains(phrase), "the hint must say '\(phrase)'")
        }
        for overclaim in ["never leave", "privileged, settings, and secret prompts are never counted"] {
            #expect(!hint.contains(overclaim), "the hint must not say '\(overclaim)'")
        }
        // The promise must not come back: no present-tense iPhone answering
        // in the names, the hint or the pair-first caption.
        for text in [hint, MenuStateModel.remoteApprovalsAccessibilityLabel, MenuStateModel.remoteApprovalsSettingsToggleTitle,
                     Self.notPaired.text] {
            for promise in ["from iPhone", "from your iPhone", "Lets the NapCat iPhone app answer", "Answer permission"] {
                #expect(!text.contains(promise), "'\(text)' promises '\(promise)'")
            }
        }
        let texts = [hint, MenuStateModel.remoteApprovalsAccessibilityLabel, MenuStateModel.remoteApprovalsSettingsToggleTitle,
                     Self.localOnly.text, Self.notListening.text, Self.notPaired.text]
            + Self.policyRows.map(\.text)
        for text in texts {
            #expect(!text.lowercased().contains("ntfy"), "'\(text)' — approvals never ride the ntfy lane")
            #expect(!text.contains("CloudKit"), "'\(text)' — user words, not the transport")
        }
        #expect(MenuStateModel.remoteApprovalsToggleTitle.split(separator: " ").count == 2,
                "C1: the panel row adds two words")
    }

    /// #252: the Advanced section's words, each exact, in the order the
    /// section shows them. User words, never the alert lane or the
    /// transport; and the line that says why nothing there can change yet
    /// promises no date, number or release.
    @Test func theAdvancedCopy() {
        let copy: [(text: String, expected: String)] = [
            (MenuStateModel.advancedTitle, "Advanced"),
            (MenuStateModel.advancedIntro, "Riskier kinds of prompt. Each stays on this Mac until you turn its switch on, and "
                + "then stays on until you turn it off. Turning one on needs Touch ID or your password."),
            (MenuStateModel.advancedUnavailable, "Not available yet — these stay on this Mac in this version."),
            (MenuStateModel.advancedAdminTitle, "Admin commands"),
            (MenuStateModel.advancedAdminCaption, "sudo and similar commands, system folders. One Allow can change the whole Mac."),
            (MenuStateModel.advancedClaudeSettingsTitle, "Claude settings and startup files"),
            (MenuStateModel.advancedClaudeSettingsCaption, "Claude's settings and hooks, git hooks, shell startup files. A change "
                + "here can run later, or stop Claude asking at all."),
            (MenuStateModel.advancedSecretsTitle, "Secrets"),
            (MenuStateModel.advancedSecretsCaption, "Key, token and password files, and commands holding a credential. Their "
                + "text goes to your iPhone through iCloud."),
            (MenuStateModel.advancedPhoneTitle, "Let my iPhone turn these on"),
            (MenuStateModel.advancedPhoneCaption, "A notice on the iPhone can turn one on with Face ID. Off: only this Mac can."),
            (MenuStateModel.advancedNeverSent, "Never sent, and there is no switch for it: NapCat's own pairing and settings, "
                + "your alert topic, your keychain, and Claude Code's helper list."),
        ]
        for (text, expected) in copy {
            #expect(text == expected)
            #expect(!text.lowercased().contains("ntfy") && !text.contains("CloudKit"), "'\(text)' — user words, not the transport")
        }
        let why = MenuStateModel.advancedUnavailable
        #expect(why.rangeOfCharacter(from: .decimalDigits) == nil, "no date or version number")
        for promise in ["soon", "next", "update", "release", "when"] {
            #expect(!why.lowercased().contains(promise), "the line promises '\(promise)'")
        }
    }

    @Test func theRowSymbolResolvesAndIsItsOwn() {
        #expect(PanelSymbol.all.contains(PanelSymbol.remoteApprovals))
        #expect(NSImage(systemSymbolName: PanelSymbol.remoteApprovals, accessibilityDescription: nil) != nil)
        #expect(![PanelSymbol.lidAlert, PanelSymbol.sessionAlerts].contains(PanelSymbol.remoteApprovals))
    }
}
