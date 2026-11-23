// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S2: structure locks the behaviour tests cannot prove by example.
/// (The armed-gated lock — the host and the probe only behind the toggle,
/// fail-dark — lives with the S1 locks it replaced, in
/// ApprovalChannelStructureTests.)
struct RemoteApprovalsStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources

    // MARK: - The toggle's policy is pure by construction

    static let policyFile = "RemoteApprovalsPolicy.swift"
    /// I/O, clocks, logging and the feature's effectful types: the policy
    /// only ever returns effects for the controller to perform.
    static let bannedTokens = ["UserDefaults", "FileManager", "Logger", "os_log", "DispatchQueue", "DispatchSource",
                               "Date(", "clock_gettime", "Timer", "URLSession", "Process(", "ApprovalSeamHost",
                               "SeamListener", "ChannelPolicyProbe", "NSApp", "print("]

    static func purityFailures(_ source: String) -> [String] {
        let code = LidGuardStructureTests.codeOnly(source)
        var failures = bannedTokens.filter { code.contains($0) }.map { "'\($0)' in \(policyFile) — the policy stays I/O-free" }
        for line in code.split(separator: "\n") {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let index = words.firstIndex(of: "import"), words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
            if words.joined(separator: " ") != "import NapCatWire" {
                failures.append("'\(line)' — the only import allowed in \(policyFile) is NapCatWire (for the finding)")
            }
        }
        return failures
    }

    @Test func thePolicyIsPure() throws {
        let source = try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(Self.policyFile),
                                encoding: .utf8)
        #expect(source.contains("struct RemoteApprovalsState"), "vacuity: the file is the policy")
        #expect(Self.purityFailures(source).isEmpty, "\(Self.purityFailures(source))")
        for planted in ["import Foundation", "let d = UserDefaults.standard", "let q = DispatchQueue(label: \"x\")",
                        "let h = ApprovalSeamHost(socketPath: p)", "let f = ChannelPolicyProbe.probe()"] {
            #expect(!Self.purityFailures(source + "\n" + planted).isEmpty, "canary '\(planted)' was NOT caught")
        }
        #expect(Self.purityFailures(source + "\n// UserDefaults in a comment is fine").isEmpty)
    }

    // MARK: - The panel row and its switch

    /// The row sits in the Alerts card directly under Session alerts, gated
    /// on the model's one visibility flag, in the alert rows' shape: the
    /// switch, then its caption (non-nominal only). The switch is rendered
    /// once, renders the OBSERVED phase, and only forwards to the model, which
    /// only forwards to the controller.
    static func panelFailures(layout: String, views: String, model: String) -> [String] {
        func flat(_ text: some StringProtocol) -> String { MenuPanelStructureTests.flat(text) }
        var failures: [String] = []
        guard let alerts = MenuPanelStructureTests.cardBlocks(in: layout).last else { return ["no Alerts card"] }
        let card = flat(layout[alerts])
        let row = "if model.remoteApprovalsVisible { PanelFeature { "
            + "PanelRow(symbol: PanelSymbol.remoteApprovals, title: \"Remote approvals\") { "
            + "RemoteApprovalsToggle(model: model) } indentedCaption(model.remoteApprovalsStatus) } }"
        if let session = card.range(of: "indentedCaption(model.finishAlertStatus)"), let mine = card.range(of: row) {
            if session.upperBound > mine.lowerBound || card[session.upperBound..<mine.lowerBound].contains("PanelRow(") {
                failures.append("the Remote approvals row must sit directly under Session alerts")
            }
        } else {
            failures.append("the Alerts card must hold the gated Remote approvals row, in the alert rows' shape")
        }
        if MenuPanelStructureTests.occurrences(of: "RemoteApprovalsToggle(model: model)", in: views) != 1 {
            failures.append("the switch must render exactly once")
        }
        let toggle = flat(MenuPanelStructureTests.structChunk("RemoteApprovalsToggle", in: views) ?? "")
        for token in ["get: { model.remoteApprovalsEnabled }", "set: { model.setRemoteApprovalsEnabled($0) }",
                      ".toggleStyle(.switch)", ".accessibilityLabel(MenuStateModel.remoteApprovalsAccessibilityLabel)"]
        where !toggle.contains(token) {
            failures.append("the switch lost '\(token)'")
        }
        for token in ["cancelTracking", "request", "remoteApprovals?.", ".animation(", "withAnimation"] where toggle.contains(token) {
            failures.append("'\(token)' in the switch — it only forwards to the model, and does not animate")
        }
        let modelFlat = flat(model)
        if !modelFlat.contains("func setRemoteApprovalsEnabled(_ enabled: Bool) { remoteApprovals?.setEnabled(enabled) refresh() }") {
            failures.append("the model's action must only forward to the controller, then refresh")
        }
        if !modelFlat.contains("var remoteApprovalsEnabled: Bool { remoteApprovalsPhase != .off }") {
            failures.append("the switch must render the observed phase")
        }
        return failures
    }

    @Test func theRowSitsUnderSessionAlertsAndOnlyForwards() throws {
        let layout = try MenuPanelStructureTests.layoutBody()
        let views = try MenuPanelStructureTests.allViewCode()
        let model = try MenuPanelStructureTests.code("MenuStateModel.swift")
        #expect(Self.panelFailures(layout: layout, views: views, model: model).isEmpty,
                "\(Self.panelFailures(layout: layout, views: views, model: model))")
        let mutants: [(String, String, String, String)] = [
            ("ungated", layout.replacingOccurrences(of: "if model.remoteApprovalsVisible {", with: "if true {"), views, model),
            ("no caption", layout.replacingOccurrences(of: "indentedCaption(model.remoteApprovalsStatus)", with: ""), views, model),
            ("rendered twice", layout, views + "\nlet t = RemoteApprovalsToggle(model: model)", model),
            ("bound to the stored intent", layout,
             views.replacingOccurrences(of: "get: { model.remoteApprovalsEnabled }", with: "get: { storedIntent }"), model),
            ("closes the menu", layout,
             views.replacingOccurrences(of: "set: { model.setRemoteApprovalsEnabled($0) }",
                                        with: "set: { model.setRemoteApprovalsEnabled($0); menu.cancelTracking() }"), model),
            ("the model acts itself", layout, views,
             model.replacingOccurrences(of: "remoteApprovals?.setEnabled(enabled)", with: "remoteApprovals?.shutdown()")),
            ("the switch reads the store", layout, views,
             model.replacingOccurrences(of: "remoteApprovalsPhase != .off }", with: "storedToggle }")),
        ]
        for (name, layout, views, model) in mutants {
            #expect(!Self.panelFailures(layout: layout, views: views, model: model).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - The secrets fail closed

    /// The production host gets the lid guard's fail-closed answer (nil while
    /// the topic could not be read), and the intake folds a nil into a
    /// refusal right on the gate's answer — before the lifecycle opens.
    static func secretsFailures(intake: String, toggle: String) -> [String] {
        func flat(_ text: String) -> String { MenuPanelStructureTests.flat(text) }
        var failures: [String] = []
        if !flat(toggle).contains("makeHost: { Self.failDarkHost(socketPath: $0, secrets: { @Sendable in lidGuard.approvalSecrets }) }") {
            failures.append("the production host must look for the lid guard's fail-closed secrets")
        }
        let fold = "let known = secrets() let classification = ApprovalGate.classify(toolName: request.toolName, "
            + "inputPreview: request.inputPreview, secrets: known ?? []).failingClosed(secretsKnown: known != nil)"
        if !flat(intake).contains(fold) {
            failures.append("the intake must fold unknown secrets into a refusal on the gate's own answer")
        }
        if MenuPanelStructureTests.occurrences(of: "secrets()", in: intake) != 1 {
            failures.append("the secrets are read once per prompt, in one place")
        }
        if !flat(intake).contains("secretsKnown ? self : .suppress(.forbidden(.secretAccess))") {
            failures.append("unknown secrets must mean secret access")
        }
        return failures
    }

    @Test func theSecretsFailClosed() throws {
        let intake = try MenuPanelStructureTests.code("ApprovalIntake.swift")
        let toggle = try MenuPanelStructureTests.code("RemoteApprovalsController.swift")
        #expect(Self.secretsFailures(intake: intake, toggle: toggle).isEmpty, "\(Self.secretsFailures(intake: intake, toggle: toggle))")
        let mutants: [(String, String, String)] = [
            ("the stored topic, unreadable read as none", intake, toggle.replacingOccurrences(
                of: "lidGuard.approvalSecrets", with: "[lidGuard.storedTopic]")),
            ("the fold dropped", intake.replacingOccurrences(of: ".failingClosed(secretsKnown: known != nil)", with: ""), toggle),
            ("unknown read as none", intake.replacingOccurrences(
                of: "secretsKnown ? self : .suppress(.forbidden(.secretAccess))", with: "self"), toggle),
        ]
        for (name, intake, toggle) in mutants {
            #expect(!Self.secretsFailures(intake: intake, toggle: toggle).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - The S2 tests touch nothing live

    /// The S2 test files that run anything (this file only reads sources).
    static let s2TestFiles = ["RemoteApprovalsPolicyTests.swift", "RemoteApprovalsControllerTests.swift",
                              "RemoteApprovalsPresentationTests.swift", "WaitingPromptContextTests.swift",
                              "ApprovalSecretsFailClosedTests.swift", "ApprovalSeamLimitsTests.swift"]

    /// S1's list (it bans any defaults store at all), plus what S2 could
    /// reach: the toggle's production factory (it resolves the real socket
    /// path and reads the real defaults), the real keychain, and the real
    /// Application Support folders.
    static let liveTokens = ApprovalChannelStructureTests.liveTokens
        // The keychain names are split so no test file spells them
        // (KeychainTopicStoreTests.noTestFileCanReachTheRealKeychain).
        + ["makeIfEnabled(", "login" + "Keychain", "Sec" + "Item", "/Library/Application Support", "~/Library"]

    static func liveFailures(_ tests: Sources) -> [String] {
        tests.flatMap { name, text in
            liveTokens.filter { text.contains($0) }.map { "'\($0)' in \(name) — S2 tests touch nothing live" }
        }
    }

    @Test func theS2TestsTouchNothingLive() throws {
        let directory = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let tests: Sources = try Self.s2TestFiles.map {
            ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)))
        }
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let c = RemoteApprovalsController.makeIfEnabled(debugBattery: false, lidGuard: l)",
                        "let d = UserDefaults.standard", "let k = KeychainTopicStore." + "login" + "Keychain",
                        "let p = Process()", "let f = ChannelPolicyProbe.probe()",
                        "let s = SeamPaths.socketPath(home: h)"] {
            let mutant = tests.map { $0.name == "RemoteApprovalsControllerTests.swift" ? ($0.name, $0.text + "\n" + planted) : $0 }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }
}
