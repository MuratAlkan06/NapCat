// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S-PAIR-C1 (#168): the structure locks over the Mac's pairing —
/// the rules the behaviour tests cannot prove by example. Each is a pure
/// function over the comment-stripped sources of the four targets, and
/// each catches planted canaries, so none can pass vacuously.
///
/// 1. The comparison cannot be skipped: the only road to the paired-key
///    slot's one write is the owner's Codes Match. The state machine returns
///    the commit effect from its Codes Match event alone, on its pinned
///    lines; the shell performs it at one site; the slot's `commit` is the
///    one write of its item; the sheet's Codes Match button is the one
///    caller of the shell's `codesMatch`; and nothing else builds the slot
///    or names the real keychain item behind it.
/// 2. The nonce stays on the screen: one stored nonce (the state machine's,
///    private), handed to the wire's builders and the checks only; what is
///    remembered across launches is the record's NAME; the payload is drawn
///    by the QR view and named nowhere else; no pairing file logs, copies or
///    shows a tooltip.
/// 3. Nothing arms and the verifier stays unwired: no pairing file names the
///    verdict API or the verifier, and no approval file or the verifier
///    names the slot (S-PAIR-C2 wires it, under its own locks).
/// 4. The C1 tests touch nothing live.
/// 5. The sheet's keys: Esc ends it in every state; nothing answers Return.
struct PairingStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources

    static let ceremonyFile = "PairingCeremony.swift"
    static let controllerFile = "PairingController.swift"
    static let slotFile = "PairedKeyStore.swift"
    static let sheetFile = "PairingSheet.swift"
    static let pairingFiles = [ceremonyFile, controllerFile, slotFile, sheetFile]

    static func text(_ name: String, in sources: Sources) -> String { ApprovalChannelStructureTests.text(name, in: sources) }

    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        ApprovalChannelStructureTests.mutate(sources, name, transform)
    }

    /// `pattern`'s sites across `sources` must be exactly `allowed` (file →
    /// line → count), in every constructor scan copy (backticks removed,
    /// block comments a space).
    static func appSiteFailures(_ pattern: String, in sources: Sources, allowed: [String: [String: Int]], rule: String) -> [String] {
        var failures: [String] = []
        for (name, text) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(text) {
                failures += ApprovalRecordPathStructureTests.siteFailures(pattern, in: copy, file: name,
                                                                          allowed: allowed[name] ?? [:], rule: rule)
            }
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    // MARK: - 1. The comparison cannot be skipped

    /// The state machine's Codes Match, whole: the one place a commit is
    /// returned, while comparing, inside the window.
    static let codesMatchBody = "private mutating func codesMatch(now: TimeInterval) -> [PairingEffect] {"
        + " guard case .comparing(let candidate) = phase else { return [] }"
        + " guard now < deadline else { return end(.expired) }"
        + " phase = .committing(candidate) return [.commit(candidate)] }"

    static let commitSites: [String: [String: Int]] = [
        ceremonyFile: ["case commit(PairingCandidate)": 1, "return [.commit(candidate)]": 1],
        controllerFile: ["case .commit(let candidate):": 1, "return .committed(phone.map { keys.commit($0) } ?? false)": 1],
        slotFile: ["func commit(_ phone: PairedPhone) -> Bool {": 1],
    ]

    static let codesMatchSites: [String: [String: Int]] = [
        ceremonyFile: ["case codesMatch(now: TimeInterval)": 1, "case .codesMatch(let now): return codesMatch(now: now)": 2,
                       codesMatchHead: 1],
        controllerFile: ["func codesMatch() { run(.codesMatch(now: clock().timeIntervalSince1970)) }": 2],
        sheetFile: ["case cancel, theyDontMatch, codesMatch, done, startOver, close": 1,
                    "case .codesMatch: return \"Codes Match\"": 1,
                    "countdown: countdown, actions: [.theyDontMatch, .codesMatch], actionsEnabled: enabled)": 1,
                    "case .codesMatch: pairing.codesMatch()": 2],
    ]
    static let codesMatchHead = "private mutating func codesMatch(now: TimeInterval) -> [PairingEffect] {"

    /// The real item's binding and the real calls, spelled split so no test
    /// file names them (KeychainTopicStoreTests.noTestFileCanReachTheRealKeychain).
    static let realItem = "pairedPhone" + "Keychain"
    static let realCalls = "security" + "Framework"
    static let wiringLine = "keys: PairedKeyStore(items: KeychainTopicStore." + realItem + "),"
    static let itemLine = "static let " + realItem + " = KeychainTopicStore(item: .pairedPhone, calls: ." + realCalls + ")"

    /// The slot and its item: built by the app's wiring alone; written by
    /// its `commit` alone.
    static let slotSites: [(pattern: String, allowed: [String: [String: Int]], rule: String)] = [
        (#"\bPairedKeyStore\s*(?:\.\s*init\s*)?\("#,
         ["NapCatApp.swift": [wiringLine: 1]],
         "the slot is built by the app's wiring only"),
        (#"\b"# + realItem + #"\b"#,
         ["KeychainTopicStore.swift": [itemLine: 1], "NapCatApp.swift": [wiringLine: 1]],
         "the real paired-key item is handed to the slot once, by the app's wiring"),
        (#"\.\s*pairedPhone\b"#,
         ["KeychainTopicStore.swift": [
            itemLine: 1,
            "var label: String { item == .pairedPhone ? Self.pairedPhoneItemLabel : Self.itemLabel }": 1]],
         "the paired-key item's name is used by the keychain store only"),
        (#"\bitems\s*\.\s*(?:write|delete|read)\b"#,
         [slotFile: ["switch items.read() {": 1, "items.write(Self.text(of: phone))": 1, "items.delete()": 1]],
         "the slot's item is read, written (by commit) and deleted (by unpair) at one site each"),
    ]

    static func compareFailures(_ sources: Sources) -> [String] {
        let ceremony = text(ceremonyFile, in: sources)
        guard ceremony.contains("struct PairingCeremonyState"), !text(controllerFile, in: sources).isEmpty,
              !text(slotFile, in: sources).isEmpty, !text(sheetFile, in: sources).isEmpty else {
            return ["a pairing file is missing — the compare lock would be vacuous"]
        }
        var failures: [String] = []
        let flat = MenuPanelStructureTests.flat(ceremony)
        if ApprovalChannelStructureTests.count(codesMatchBody, in: flat) != 1 {
            failures.append("Codes Match must return the commit, while comparing, inside the window — exactly as pinned")
        }
        if ApprovalChannelStructureTests.count("phase = .committing(", in: ceremony) != 1 {
            failures.append("only Codes Match moves the ceremony to committing")
        }
        failures += appSiteFailures(#"\bcommit\b"#, in: sources, allowed: commitSites,
                                    rule: "the slot's commit is reached from Codes Match alone")
        failures += appSiteFailures(#"\bcodesMatch\b"#, in: sources, allowed: codesMatchSites,
                                    rule: "Codes Match is the sheet's button's alone")
        for (pattern, allowed, rule) in slotSites {
            failures += appSiteFailures(pattern, in: sources, allowed: allowed, rule: rule)
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    @Test func theComparisonCannotBeSkipped() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.compareFailures(sources).isEmpty, "\(Self.compareFailures(sources))")
        let ceremony = Self.ceremonyFile
        let verified = "                phase = .comparing(candidate)\n                return [.audit(.verified)]"
        #expect(Self.text(ceremony, in: sources).contains(verified), "vacuity: the freeze is where the canaries plant")
        let mutants: [(String, Sources)] = [
            ("committed on the verified fetch (no Codes Match)", Self.mutate(sources, ceremony) {
                $0.replacingOccurrences(of: verified, with: "                phase = .committing(candidate)\n"
                                        + "                return [.audit(.verified), .commit(candidate)]") }),
            ("Codes Match outside the window", Self.mutate(sources, ceremony) {
                $0.replacingOccurrences(of: "        guard now < deadline else { return end(.expired) }\n        phase = .committing(",
                                        with: "        phase = .committing(") }),
            ("Codes Match from any phase", Self.mutate(sources, ceremony) {
                $0.replacingOccurrences(of: "        guard case .comparing(let candidate) = phase else { return [] }\n        guard now",
                                        with: "        guard let candidate = frozen else { return [] }\n        guard now") }),
            ("They Don't Match commits", Self.mutate(sources, ceremony) {
                $0.replacingOccurrences(of: "        guard case .comparing = phase else { return [] }\n        return end(.stoppedMismatch)",
                                        with: "        guard case .comparing(let c) = phase else { return [] }\n        return [.commit(c)]") }),
            ("the shell writes the slot on its own", Self.mutate(sources, Self.controllerFile) {
                $0 + "\nextension PairingController { func zz(_ p: PairedPhone, _ k: PairedKeyStore) { _ = k.commit(p) } }" }),
            ("an unapplied commit", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = PairedKeyStore.commit" }),
            ("a second slot built", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet zz = PairedKeyStore(items: FakeItems())" }),
            ("the real item written directly", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = KeychainTopicStore." + Self.realItem + ".write(\"x\")" }),
            ("the item named elsewhere", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet zz = KeychainTopicStore(item: .pairedPhone, calls: c)" }),
            ("a second write of the slot's item", Self.mutate(sources, Self.slotFile) {
                $0 + "\nextension PairedKeyStore { func zz() -> Bool { items.write(\"\") } }" }),
            ("Codes Match pressed by the timer", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "    func tick() { run(.tick(now: clock().timeIntervalSince1970)) }",
                                        with: "    func tick() { run(.tick(now: clock().timeIntervalSince1970)); codesMatch() }") }),
            ("Codes Match on another button", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "case .startOver: pairing.begin()", with: "case .startOver: pairing.codesMatch()") }),
            ("a backticked commit", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = k.`commit`(p)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.compareFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned words, and
        // a whole-line comment naming them.
        #expect(Self.compareFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nlet committed = 1, commitCount = 2, codesMatched = 3"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never keys.commit(p) outside Codes Match")
        }).isEmpty)
    }

    // MARK: - 2. The nonce stays on the screen

    static let nonceSites: [String: [String: Int]] = [
        ceremonyFile: [
            "case begin(nonce: [UInt8], rotating: Bool, now: TimeInterval)": 1,
            "private var nonce: [UInt8]?": 1,
            "var holdsNonce: Bool { nonce != nil }": 1,
            "guard case .showing = phase, visible, let nonce else { return nil }": 1,
            "return ApprovalSigning.pairingPayload(nonce: nonce)": 2,
            "case let .begin(nonce, rotating, now): return begin(nonce: nonce, rotating: rotating, now: now)": 3,
            "private mutating func begin(nonce: [UInt8], rotating: Bool, now: TimeInterval) -> [PairingEffect] {": 1,
            "guard ApprovalSigning.pairingPayload(nonce: nonce) != nil, let name = PairingResponseCheck.recordName(nonce: nonce) else {": 4,
            "self.nonce = nonce": 2,
            "guard let nonce else { return refuse(.confirmationInvalid) }": 1,
            "switch PairingResponseCheck.check(response, nonce: nonce) {": 2,
            "nonce = nil": 1,
            "static func check(_ response: PairingResponseClaim, nonce: [UInt8]) -> Outcome {": 1,
            "guard nonce.count == ApprovalSigning.pairingNonceByteCount,": 1,
            "using: SymmetricKey(data: nonce)) else {": 1,
            "guard let proofMessage = ApprovalSigning.pairingProofMessage(nonce: nonce, publicKey: response.publicKey),": 2,
            "static func recordName(nonce: [UInt8]) -> String? {": 1,
            "ApprovalSigning.pairingRecordNameInput(nonce: nonce)": 2,
        ],
        controllerFile: [
            "guard let nonce = makeNonce() else {": 1,
            "run(.begin(nonce: nonce, rotating: rotating, now: clock().timeIntervalSince1970))": 2,
        ],
    ]

    /// The payload, and what could carry it out of the sheet.
    static let payloadSites: [String: [String: Int]] = [
        ceremonyFile: ["var qrPayload: String? {": 1],
        sheetFile: ["let qrPayload: String?": 1, "qrPayload: nil, fingerprint: nil, status: endedLine(.expired), notes: [], countdown: nil,": 1,
                    "qrPayload: nil, fingerprint: nil, status: PanelLine(text: hiddenLine, severity: .info),": 1,
                    "guard let payload = state.qrPayload else {": 1,
                    "qrPayload: payload, fingerprint: nil, status: status, notes: [privacyNote],": 1,
                    "qrPayload: nil, fingerprint: candidate.fingerprint,": 1,
                    "return PairingSheetContent(screen: .paired, title: title(.paired, rotating: false), subtitle: nil, qrPayload: nil,": 1,
                    "qrPayload: nil, fingerprint: nil, status: endedLine(end), notes: [], countdown: nil,": 1,
                    "if let payload = content.qrPayload {": 1],
    ]

    /// Matched as words (`fingerprint(` is no `print(`).
    static let leakTokens = [#"\bNSPasteboard\b"#, #"\bUIPasteboard\b"#, #"\.help\("#, #"\bprint\("#, #"\bNSLog\b"#,
                             #"\bos_log\b"#, #"\bdebugPrint\b"#, #"\bdump\("#, #"\.contextMenu\b"#, #"\bUserDefaults\b"#,
                             #"@AppStorage\b"#, #"\bFileManager\b"#, #"\bwrite\(to\b"#]

    static func nonceFailures(_ sources: Sources) -> [String] {
        var failures = appSiteFailures(#"\bnonce\b"#, in: sources.filter { [ceremonyFile, controllerFile].contains($0.name) },
                                       allowed: nonceSites, rule: "the nonce goes only to the wire's builders and the checks")
        failures += appSiteFailures(#"\bqrPayload\b"#, in: sources, allowed: payloadSites,
                                    rule: "the payload is drawn by the QR view and named nowhere else")
        for (name, text) in sources where [ceremonyFile, sheetFile].contains(name) {
            for token in leakTokens + [#"\bLogger\b"#, #"\blogger\b"#] where ApprovalRecordPathStructureTests.hits(token, in: text) {
                failures.append("'\(token)' in \(name) — nothing of the code is logged, kept, copied or shown twice")
            }
        }
        for token in leakTokens where ApprovalRecordPathStructureTests.hits(token, in: text(controllerFile, in: sources)
            .replacingOccurrences(of: "defaults: UserDefaults) -> PairingController? {", with: "")) {
            failures.append("'\(token)' in \(controllerFile) — only the record's name is remembered")
        }
        let controller = text(controllerFile, in: sources)
        let remembered = ApprovalRecordPathStructureTests.siteTally(#"\bwriteRemembered\s*\("#, in: controller)
        if remembered != ["writeRemembered(name)": 1, "if gone, readRemembered() == name { writeRemembered(nil) }": 1,
                          "if await source.delete(recordName: name), readRemembered() == name { writeRemembered(nil) }": 1] {
            failures.append("only the record's NAME is remembered, and forgotten once the record is gone: \(remembered)")
        }
        let logged = ApprovalRecordPathStructureTests.siteTally(#"\blogger\s*\."#, in: controller)
        if logged != ["logger.notice(\"\\(event.code, privacy: .public)\")": 1] {
            failures.append("the pairing log writes closed codes only: \(logged)")
        }
        if ApprovalRecordPathStructureTests.hits(#"(?m)^    (?:\w+ |\w+\(\w+\) )*(?:var|let) \w*[Nn]once\b(?!:\s*\(\))"#,
                                                 in: controller) {
            failures.append("the shell keeps a nonce — it lives in the state machine alone")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    @Test func theNonceStaysOnTheScreen() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.nonceFailures(sources).isEmpty, "\(Self.nonceFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the nonce remembered", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "            writeRemembered(name)\n", with: "            writeRemembered(name)\n"
                                        + "            writeRemembered(state.nonceText)\n") }),
            ("the shell keeps the nonce", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "    private var generation = 0\n", with: "    private var generation = 0\n"
                                        + "    private var lastNonce: [UInt8]?\n") }),
            ("the nonce handed elsewhere", Self.mutate(sources, Self.ceremonyFile) {
                $0.replacingOccurrences(of: "        self.nonce = nonce\n", with: "        self.nonce = nonce\n        Spare.seen = nonce\n") }),
            ("the payload logged", Self.mutate(sources, Self.controllerFile) {
                $0 + "\nextension PairingController { func zz() { PairingLog.logger.notice(\"\\(self.state.qrPayload ?? \"\")\") } }" }),
            ("the payload copied", Self.mutate(sources, Self.sheetFile) {
                $0 + "\nfunc zz(_ p: String) { NSPasteboard.general.setString(p, forType: .string) }" }),
            ("the payload as a tooltip", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "                QRCodeView(payload: payload)\n",
                                        with: "                QRCodeView(payload: payload)\n                    .help(payload)\n") }),
            ("the payload spoken", Self.mutate(sources, Self.sheetFile) {
                $0 + "\nlet zz = PairingSheetContent.make(s, now: 0).qrPayload ?? \"\"" }),
            ("the payload elsewhere", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = pairing?.state.qrPayload" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.nonceFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 3. Nothing arms; the verifier stays unwired

    static let pairingTypes = ["PairedKeyStore", "PairedPhone", "PairingController", "PairingCeremonyState", "PairingCandidate"]
    /// The approval files and the verifier: none reaches the slot in C1.
    static let unwiredFiles = ApprovalRecordPathStructureTests.approvalFiles + [ApprovalRecordPathStructureTests.verifierFile]
    static let armingTokens = ApprovalRecordPathStructureTests.verdictAPITokens
        + ApprovalRecordPathStructureTests.verifierTypes + ["ApprovalDecision", "signatureVerified"]

    static func unwiredFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where pairingFiles.contains(name) {
            for token in armingTokens where text.contains(token) && !(name == controllerFile && token == "RemoteApprovalsController") {
                failures.append("'\(token)' in \(name) — pairing names nothing of the verdict API (the toggle only for its kill switch)")
            }
        }
        for (name, text) in sources where unwiredFiles.contains(name) {
            for type in pairingTypes where ApprovalRecordPathStructureTests.hits(#"\b"# + type + #"\b"#, in: text) {
                failures.append("'\(type)' in \(name) — the slot is wired to no decision path in C1 (S-PAIR-C2)")
            }
        }
        let controller = text(controllerFile, in: sources)
        if ApprovalChannelStructureTests.count("RemoteApprovalsController", in: controller) != 1
            || !controller.contains("killSwitch: { [weak remoteApprovals] in remoteApprovals?.setEnabled(false) })") {
            failures.append("the pairing reaches the toggle once: Unpair's kill switch (setEnabled(false))")
        }
        return failures
    }

    @Test func nothingArmsAndTheVerifierStaysUnwired() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.unwiredFailures(sources).isEmpty, "\(Self.unwiredFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the verifier handed the slot", Self.mutate(sources, ApprovalRecordPathStructureTests.verifierFile) {
                $0 + "\nenum ZZ { static var keys: PairedKeyStore? }" }),
            ("the intake reads the slot", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet zz: PairedPhone? = nil" }),
            ("the pairing arms", Self.mutate(sources, Self.controllerFile) { $0 + "\nlet zzArmed = { true }\nlet armed = zzArmed" }),
            ("the pairing builds a verifier input", Self.mutate(sources, Self.ceremonyFile) {
                $0 + "\nlet zz: DecisionEvidence? = nil" }),
            ("the pairing turns the toggle on", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "remoteApprovals?.setEnabled(false)", with: "remoteApprovals?.setEnabled(true)") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.unwiredFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - 4. The C1 tests touch nothing live

    static let testFiles = ["PairingCeremonyTests.swift", "PairingControllerTests.swift", "PairingPresentationTests.swift",
                            "PairingResponseReaderTests.swift", "PairedKeyStoreTests.swift", "PairingFingerprintVectorTests.swift"]
    /// The live parts: the real keychain items and bindings (split so no
    /// test file spells them), the real defaults, the app's factories, the
    /// live tick, the system random source, the announcer, and CloudKit's
    /// container and database.
    static let liveTokens = ["pairedPhone" + "Keychain", "login" + "Keychain", "security" + "Framework", "Sec" + "Item",
                             "UserDefaults.standard", "makeIfEnabled(", "TimerPairingTicker", "secureNonce", "Pairing" + "Announcer",
                             "CKContainer", "CKDatabase", "SecRandomCopyBytes", "NSApp.", "makeKeyAndOrderFront"]

    static func liveFailures(_ tests: Sources) -> [String] {
        tests.flatMap { name, text in
            liveTokens.filter { text.contains($0) }.map { "'\($0)' in \(name) — the C1 tests touch nothing live" }
        }
    }

    @Test func theC1TestsTouchNothingLive() throws {
        let directory = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let tests: Sources = try Self.testFiles.map {
            ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)))
        }
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let k = KeychainTopicStore." + "pairedPhone" + "Keychain", "let d = UserDefaults.standard",
                        "let p = PairingController.makeIfEnabled(remoteApprovals: r, keys: k, defaults: d)",
                        "let t = TimerPairingTicker { }", "let n = PairingController.secureNonce()",
                        "Pairing" + "Announcer.post(\"x\")"] {
            let mutant = tests.map { $0.name == "PairingControllerTests.swift" ? ($0.name, $0.text + "\n" + planted) : $0 }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
        // The keychain lock's own binding list covers the new item too.
        #expect(KeychainTopicStoreTests.bindingTokens.contains("pairedPhone" + "Keychain"),
                "no test file can name the real paired-key item")
    }

    // MARK: - 5. The sheet's keys: Esc ends it, nothing answers Return

    /// The sheet's key bindings, whole (design review H2): Esc
    /// (`.cancelAction`, which needs no focus) on the state's Cancel, Done
    /// or Close and on S1c's faceless Cancel — each only ends the sheet — and
    /// nothing on Return, so the pairing is committed by a click on Codes
    /// Match alone and no key meant for one screen lands on the next.
    static let shortcutSites: [String: [String: Int]] = [
        sheetFile: ["button.keyboardShortcut(.cancelAction)": 1, ".keyboardShortcut(.cancelAction)": 1],
    ]
    static let escapeBindings = [
        "var isEscape: Bool { [.cancel, .done, .close].contains(self) }",
        "var escape: Action { actions.first(where: \\.isEscape) ?? .cancel }",
        "actionButton(action, isEscape: action == content.escape)",
        "if isEscape { button.keyboardShortcut(.cancelAction) } else { button }",
        "if !content.actions.contains(content.escape) { Button(content.escape.title) { perform(content.escape) }"
            + " .keyboardShortcut(.cancelAction) .hidden() .accessibilityHidden(true) }",
        "case .cancel, .done, .close: pairing.cancel()",
        ".onExitCommand { pairing.cancel() }",
    ]
    /// What else could put a key on the sheet.
    static let otherKeyTokens = [#"\.defaultAction\b"#, #"\bKeyEquivalent\b"#, #"\bKeyboardShortcut\b"#, #"\.return\b"#,
                                 #"\bkeyEquivalent\b"#, #"\.onKeyPress\b"#, #"\.onSubmit\b"#, #"\bNSEvent\b"#]

    static func keyboardFailures(_ sources: Sources) -> [String] {
        let sheet = text(sheetFile, in: sources)
        guard sheet.contains("struct PairingSheetView") else { return ["the sheet is missing — the keyboard lock would be vacuous"] }
        var failures: [String] = []
        for copy in LidGuardStructureTests.constructorScanCopies(sheet) {
            for token in otherKeyTokens where ApprovalRecordPathStructureTests.hits(token, in: copy) {
                failures.append("'\(token)' in \(sheetFile) — nothing on the sheet answers Return, or any key but Esc")
            }
        }
        failures += appSiteFailures(#"\bkeyboardShortcut\b"#, in: sources.filter { $0.name == sheetFile }, allowed: shortcutSites,
                                    rule: "Esc is the only key: on the button that ends the sheet, and on S1c's faceless Cancel")
        let flat = MenuPanelStructureTests.flat(sheet)
        for binding in escapeBindings where ApprovalChannelStructureTests.count(binding, in: flat) != 1 {
            failures.append("Esc's binding moved or is gone: \(binding)")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    @Test func escEndsTheSheetAndNothingAnswersReturn() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.keyboardFailures(sources).isEmpty, "\(Self.keyboardFailures(sources))")
        let sheet = Self.sheetFile
        let mutants: [(String, Sources)] = [
            ("Codes Match the default again", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "actionButton(action, isEscape: action == content.escape)",
                                        with: "actionButton(action, isEscape: action == content.escape)"
                                            + ".keyboardShortcut(action == .codesMatch ? .defaultAction : nil)") }),
            ("the last button the default again", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "            button.keyboardShortcut(.cancelAction)\n        } else {\n            button\n",
                                        with: "            button.keyboardShortcut(.cancelAction)\n        } else {\n"
                                            + "            button.keyboardShortcut(KeyboardShortcut(\"\\r\", modifiers: []))\n") }),
            ("Esc dropped from the escape button", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "            button.keyboardShortcut(.cancelAction)\n", with: "            button\n") }),
            ("Esc dropped from S1c", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "                        .keyboardShortcut(.cancelAction)\n                        .hidden()",
                                        with: "                        .hidden()") }),
            ("Esc on a deciding button", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "[.cancel, .done, .close].contains(self)", with: "[.cancel, .done, .close, .startOver].contains(self)") }),
            ("S1c's Esc decides", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "actions.first(where: \\.isEscape) ?? .cancel", with: "actions.first(where: \\.isEscape) ?? .theyDontMatch") }),
            ("Return by a key press", Self.mutate(sources, sheet) {
                $0.replacingOccurrences(of: "        .onExitCommand { pairing.cancel() }\n",
                                        with: "        .onExitCommand { pairing.cancel() }\n        .onKeyPress(.return) { .handled }\n") }),
            ("a backticked default", Self.mutate(sources, sheet) {
                $0 + "\nlet zz = KeyboardShortcut.`defaultAction`" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keyboardFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }
}
