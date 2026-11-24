// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
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
/// 6. The nonce is fresh — the system's random source fills all of it — and
///    the app's controller is the one `makeIfEnabled` builds, whole.
///
/// AMENDED (the C1 security review's R3-R5): lock 1 also keeps the slot's
/// item private to it and pins every name that leads to the real keychain;
/// lock 2 pins every line of the sheet naming the payload and its one image;
/// lock 6 is new.
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
        // The C1 security review's R3: the item is the slot's alone (private,
        // `slotItemSites`), and no member access or key path anywhere names
        // it (M1 aliased it, M2 reached it by key path).
        (#"\.\s*items\b"#,
         [slotFile: ["self.items = items": 1]],
         "nothing reaches the slot's item through a member access or a key path"),
        // … and every name that leads to the real keychain sits on its
        // pinned lines (M3 built a second real handle from the account
        // literal and wrote it from another file): the paired item's account,
        // the item-name and store types (however a construction is spelled —
        // a typed `.init` or an unapplied one still names its type), the
        // real calls' binding and the topic store's.
        (NSRegularExpression.escapedPattern(for: pairedAccount),
         ["KeychainTopicStore.swift": [pairedNameLine: 1]],
         "the paired item's account is spelled once, in its name"),
        (#"\bKeychainItemName\b"#,
         ["KeychainTopicStore.swift": ["struct KeychainItemName: Equatable, Sendable {": 1, topicNameLine: 1, pairedNameLine: 1,
                                       "let item: KeychainItemName": 1]],
         "the keychain's item names are built at their two sites only"),
        (#"\bKeychainTopicStore\b"#,
         ["KeychainTopicStore.swift": ["struct KeychainTopicStore: TopicStore {": 1, topicStoreLine: 1, itemLine: 1],
          "NapCatApp.swift": ["topicStore: KeychainTopicStore." + topicItem: 1, wiringLine: 1]],
         "the real keychain stores are built at their two sites and handed on by the app's wiring only"),
        (#"\b"# + realCalls + #"\b"#,
         ["KeychainTopicStore.swift": ["static let " + realCalls + " = KeychainItemCalls(": 1, topicStoreLine: 1, itemLine: 1]],
         "the real keychain calls are handed to the two real stores only"),
        (#"\b"# + topicItem + #"\b"#,
         ["KeychainTopicStore.swift": [topicStoreLine: 1], "NapCatApp.swift": ["topicStore: KeychainTopicStore." + topicItem: 1]],
         "the topic's real store is handed on by the app's wiring only"),
    ]

    /// The paired item's account, its name and the topic's real store, as
    /// written (the bindings split, as above).
    static let pairedAccount = "paired-iphone-key"
    static let topicItem = "login" + "Keychain"
    static let topicNameLine = "static let ntfyTopic = KeychainItemName(service: \"com.muratalkan.napcat\", account: \"ntfy-topic\")"
    static let pairedNameLine = "static let pairedPhone = KeychainItemName(service: \"com.muratalkan.napcat\", account: \"" + pairedAccount + "\")"
    static let topicStoreLine = "static let " + topicItem + " = KeychainTopicStore(item: .ntfyTopic, calls: ." + realCalls + ")"

    /// R3: every `items` in the slot's own file — the item is private (so
    /// the compiler keeps every other file off it), handed on once by the
    /// init, and used at its three sites.
    static let slotItemSites: [String: [String: Int]] = [
        slotFile: ["private let items: any TopicStore": 1, "init(items: any TopicStore) {": 1, "self.items = items": 2,
                   "switch items.read() {": 1, "items.write(Self.text(of: phone))": 1, "items.delete()": 1],
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
        failures += appSiteFailures(#"\bitems\b"#, in: sources.filter { $0.name == slotFile }, allowed: slotItemSites,
                                    rule: "the slot's item is private to it, handed on once and used at its three sites")
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
        // The C1 security review's R3: its M1-M3, as planted, and their
        // neighbours — the item made visible, aliased in its own file, and a
        // second real store however it is built or wherever its real calls
        // come from.
        let store = "KeychainTopicStore.swift"
        let insideStore = "    static let itemLabel = \"NapCat ntfy topic\"\n"
        let r3: [(String, Sources)] = [
            ("M1: the slot's item aliased and written", Self.mutate(sources, Self.controllerFile) {
                $0 + "\nextension PairingController { func zz(_ p: PairedPhone) -> Bool { let slot = keys.items; "
                    + "return slot.write(PairedKeyStore.text(of: p)) } }" }),
            ("M2: the slot's item reached by key path", Self.mutate(sources, Self.controllerFile) {
                $0 + "\nextension PairingController { func zz2(_ p: PairedPhone) -> Bool { "
                    + "keys[keyPath: \\.items].write(PairedKeyStore.text(of: p)) } }" }),
            ("M3: a second real handle by the account literal, written from another file", Self.mutate(Self.mutate(sources, store) {
                $0 + "\nextension KeychainTopicStore { static let zzSlot = KeychainTopicStore(item: KeychainItemName(service: "
                    + "\"com.muratalkan.napcat\", account: \"" + Self.pairedAccount + "\"), calls: ." + Self.realCalls + ") }" },
                "MenuContentView.swift") { $0 + "\nfunc zzWrite(_ p: PairedPhone) -> Bool { KeychainTopicStore.zzSlot.write(PairedKeyStore.text(of: p)) }" }),
            ("the slot's item made visible", Self.mutate(sources, Self.slotFile) {
                $0.replacingOccurrences(of: "    private let items: any TopicStore\n", with: "    let items: any TopicStore\n") }),
            ("the slot's item aliased in its own file", Self.mutate(sources, Self.slotFile) {
                $0 + "\nextension PairedKeyStore { var spare: any TopicStore { items } }" }),
            ("a key path to the slot's item, by its type", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = \\PairedKeyStore.items" }),
            ("a second real store, init-spelled", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = KeychainTopicStore.init(item: n, calls: c)" }),
            ("a second real store by typed implicit init", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz: KeychainTopicStore = .init(item: n, calls: c)" }),
            ("a backticked second store", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = `KeychainTopicStore`(item: n, calls: c)" }),
            ("the account split, the name built beside the others", Self.mutate(sources, store) {
                $0 + "\nextension KeychainItemName { static let zz = KeychainItemName(service: s, account: \"paired-\" + \"iphone-key\") }" }),
            ("the account literal elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = \"" + Self.pairedAccount + "\"" }),
            ("a third store in the store's own body, on the real calls", Self.mutate(sources, store) {
                $0.replacingOccurrences(of: insideStore, with: "    static let zz = Self(item: .init(service: s, account: a), calls: ."
                                        + Self.realCalls + ")\n" + insideStore) }),
            ("a third store in the store's own body, on the topic store's calls", Self.mutate(sources, store) {
                $0.replacingOccurrences(of: insideStore, with: "    static let zz = Self(item: .init(service: s, account: a), calls: "
                                        + Self.topicItem + ".calls)\n" + insideStore) }),
        ]
        for (name, mutant) in mutants + r3 {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.compareFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned words, and
        // a whole-line comment naming them.
        #expect(Self.compareFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nlet committed = 1, commitCount = 2, codesMatched = 3"
                + "\nlet itemsCount = 4, lineItems = [5], KeychainTopicStores = 6, KeychainItemNames = 7"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never keys.commit(p) outside Codes Match")
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never keys.items, never \\.items, never KeychainTopicStore(item:calls:)"
                                                                  + "\n/// never KeychainItemName(service:account:) for \"" + Self.pairedAccount + "\"")
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

    /// The C1 security review's R5: every line of the sheet naming the drawn
    /// `payload` — handed from the content to the QR view, and from the view
    /// to CoreImage's generator, nowhere else (M8 made it the QR's
    /// accessibility value) — and the sheet's one `Image`, the QR, labelled
    /// in fixed words (M7 labelled it with the payload).
    static let sheetPayloadSites: [String: [String: Int]] = [
        sheetFile: ["guard let payload = state.qrPayload else {": 1,
                    "qrPayload: payload, fingerprint: nil, status: status, notes: [privacyNote],": 1,
                    "if let payload = content.qrPayload {": 1, "QRCodeView(payload: payload)": 2, "let payload: String": 1,
                    "if let modules = Self.image(payload),": 1, "static func image(_ payload: String) -> CGImage? {": 1,
                    "filter.message = Data(payload.utf8)": 1],
    ]
    static let qrImageLine = "Image(drawn, scale: CGFloat(Self.wholeScale(displayScale)), label: Text(PairingSheetContent.qrAccessibilityLabel))"

    /// Matched as words (`fingerprint(` is no `print(`).
    static let leakTokens = [#"\bNSPasteboard\b"#, #"\bUIPasteboard\b"#, #"\.help\("#, #"\bprint\("#, #"\bNSLog\b"#,
                             #"\bos_log\b"#, #"\bdebugPrint\b"#, #"\bdump\("#, #"\.contextMenu\b"#, #"\bUserDefaults\b"#,
                             #"@AppStorage\b"#, #"\bFileManager\b"#, #"\bwrite\(to\b"#]

    static func nonceFailures(_ sources: Sources) -> [String] {
        var failures = appSiteFailures(#"\bnonce\b"#, in: sources.filter { [ceremonyFile, controllerFile].contains($0.name) },
                                       allowed: nonceSites, rule: "the nonce goes only to the wire's builders and the checks")
        failures += appSiteFailures(#"\bqrPayload\b"#, in: sources, allowed: payloadSites,
                                    rule: "the payload is drawn by the QR view and named nowhere else")
        let sheet = sources.filter { $0.name == sheetFile }
        failures += appSiteFailures(#"\bpayload\b"#, in: sheet, allowed: sheetPayloadSites,
                                    rule: "the sheet hands the payload to the QR's generator and nothing else")
        failures += appSiteFailures(#"\bImage\b"#, in: sheet, allowed: [sheetFile: [qrImageLine: 1]],
                                    rule: "the sheet's one image is the QR, labelled in fixed words")
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
            // The C1 security review's R5: its M7 and M8, as planted, and
            // their neighbours.
            ("M7: the QR's accessibility label is the payload", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "label: Text(PairingSheetContent.qrAccessibilityLabel)", with: "label: Text(payload)") }),
            ("M8: the QR's accessibility value is the payload", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "                QRCodeView(payload: payload)\n",
                                        with: "                QRCodeView(payload: payload)\n                    .accessibilityValue(payload)\n") }),
            ("the payload as the QR's hint", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: Self.qrImageLine, with: Self.qrImageLine + "\n                .accessibilityHint(Text(verbatim: payload))") }),
            ("the payload under the QR view's own label", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "                    .frame(maxWidth: .infinity)\n            }\n            if let fingerprint",
                                        with: "                    .frame(maxWidth: .infinity)\n                    .accessibilityLabel(Text(verbatim: payload))\n"
                                            + "            }\n            if let fingerprint") }),
            ("a second image labelled with the payload", Self.mutate(sources, Self.sheetFile) {
                $0 + "\nstruct ZZ: View { let code: String; var body: some View { Image(systemName: \"qrcode\").accessibilityLabel(code) } }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.nonceFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the pinned ones, and
        // a whole-line comment naming the shapes.
        #expect(Self.nonceFailures(Self.mutate(sources, Self.sheetFile) {
            $0 + "\nlet payloads = 1, payloadCount = 2, cgImageCount = 3, ImageCache = 4"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never Image(drawn, label: Text(payload)), never .accessibilityValue(payload)")
        }).isEmpty)
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

    // MARK: - 6. The nonce is fresh, and the app's controller is the wired one

    /// The C1 security review's R4. The system's random source fills the
    /// whole nonce: `secureNonce`, whole, its size the wire's
    /// `pairingNonceByteCount` (M5 drew 2 random bytes into the 32). The
    /// app's one controller is `makeIfEnabled`'s, whole: the record source
    /// `NoPairingRecords`, and no seam overridden there or by a changed
    /// default in the init (M6 passed a fixed nonce). And nothing else builds
    /// a controller, however it is spelled: `PairingController(` at its one
    /// site; every call of the init names `readRemembered` (it has no
    /// default), so a typed `.init(` is a site too; no unapplied init, alias,
    /// extension or bound generic; and no `type(of:)` anywhere, whose
    /// dynamic type would reach the init with neither name nor label.
    static let secureNonceHead = "nonisolated static func secureNonce() -> [UInt8]? {"
    static let secureNonceBody = secureNonceHead
        + " var bytes = [UInt8](repeating: 0, count: \(ApprovalSigning.pairingNonceByteCount))"
        + " return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? bytes : nil }"
    static let nonceDefaultLine = "makeNonce: @escaping () -> [UInt8]? = PairingController.secureNonce,"
    static let initHead = "init(source: any PairingRecordSource, keys: PairedKeyStore,"
        + " readRemembered: @escaping () -> String?, writeRemembered: @escaping (String?) -> Void,"
        + " " + nonceDefaultLine
        + " clock: @escaping () -> Date = Date.init, killSwitch: @escaping () -> Void,"
        + " audit: @escaping (PairingAudit) -> Void = PairingLog.record,"
        + " makeTicker: @escaping TickerFactory = { TimerPairingTicker($0) }) {"
    static let makeIfEnabledBody = "static func makeIfEnabled(remoteApprovals: RemoteApprovalsController?, keys: PairedKeyStore,"
        + " defaults: UserDefaults) -> PairingController? {"
        + " guard let remoteApprovals else { return nil }"
        + " return PairingController( source: NoPairingRecords(), keys: keys,"
        + " readRemembered: { defaults.string(forKey: DefaultsKey.pairingRecordToDelete) },"
        + " writeRemembered: { name in"
        + " if let name { defaults.set(name, forKey: DefaultsKey.pairingRecordToDelete) }"
        + " else { defaults.removeObject(forKey: DefaultsKey.pairingRecordToDelete) } },"
        + " killSwitch: { [weak remoteApprovals] in remoteApprovals?.setEnabled(false) }) }"

    static let freshSites: [(pattern: String, allowed: [String: [String: Int]], rule: String)] = [
        (#"\bsecureNonce\b"#, [controllerFile: [secureNonceHead: 1, nonceDefaultLine: 1]],
         "the system nonce is defined once and is the init's default, nothing else"),
        (#"\bmakeNonce\b"#, [controllerFile: ["private let makeNonce: () -> [UInt8]?": 1, nonceDefaultLine: 1,
                                              "self.makeNonce = makeNonce": 2, "guard let nonce = makeNonce() else {": 1]],
         "the nonce source is the init's, kept as handed, called by begin alone"),
        (ApprovalRecordPathStructureTests.constructionPattern("PairingController"), [controllerFile: ["return PairingController(": 1]],
         "the app's controller is built by makeIfEnabled alone"),
        (#"\breadRemembered\s*:"#, [controllerFile: ["private let readRemembered: () -> String?": 1,
                                                     "readRemembered: @escaping () -> String?, writeRemembered: @escaping (String?) -> Void,": 1,
                                                     "readRemembered: { defaults.string(forKey: DefaultsKey.pairingRecordToDelete) },": 1]],
         "every call of the controller's init names readRemembered — makeIfEnabled's is the one"),
    ]
    /// A dynamic type, taken anywhere in the four targets (none takes one).
    static let dynamicType = #"\btype\s*\(\s*of\s*:"#

    static func freshFailures(_ sources: Sources) -> [String] {
        let controller = text(controllerFile, in: sources)
        guard controller.contains("final class PairingController") else {
            return ["the controller is missing — the fresh-nonce lock would be vacuous"]
        }
        var failures: [String] = []
        let flat = MenuPanelStructureTests.flat(controller)
        for (body, what) in [(secureNonceBody, "secureNonce fills the wire's whole nonce from SecRandomCopyBytes — exactly as pinned"),
                             (initHead, "the init's seams default to the live ones — exactly as pinned"),
                             (makeIfEnabledBody, "makeIfEnabled builds the controller on NoPairingRecords, no seam overridden — exactly as pinned")]
        where ApprovalChannelStructureTests.count(body, in: flat) != 1 {
            failures.append(what)
        }
        for (pattern, allowed, rule) in freshSites {
            failures += appSiteFailures(pattern, in: sources, allowed: allowed, rule: rule)
        }
        for (name, text) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(text) {
                if ApprovalRecordPathStructureTests.hits(ApprovalRecordPathStructureTests.indirectConstructionPattern("PairingController"),
                                                         in: copy) {
                    failures.append("\(name) reaches the controller's init unnamed (an unapplied init, the metatype, an alias, "
                                    + "an extension, a subclass or a bound generic)")
                }
                if ApprovalRecordPathStructureTests.hits(dynamicType, in: copy) {
                    failures.append("\(name) takes a dynamic type (type(of:)) — the road to an init with no name in sight")
                }
            }
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    @Test func theNonceIsFreshAndTheAppsControllerIsTheWiredOne() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.freshFailures(sources).isEmpty, "\(Self.freshFailures(sources))")
        let controller = Self.controllerFile
        let wiring = "            killSwitch: { [weak remoteApprovals] in"
        let mutants: [(String, Sources)] = [
            // The review's M5 and M6, as planted.
            ("M5: nonce entropy cut to 16 bits", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)",
                                        with: "SecRandomCopyBytes(kSecRandomDefault, 2, &bytes)") }),
            ("M6: the production wiring passes a fixed nonce", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: wiring, with: "            makeNonce: { [UInt8](repeating: 7, count: 32) },\n" + wiring) }),
            // … and their neighbours.
            ("a shorter nonce", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "[UInt8](repeating: 0, count: 32)", with: "[UInt8](repeating: 0, count: 16)") }),
            ("the random source's answer ignored", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "== errSecSuccess ? bytes : nil", with: "!= 0 ? bytes : bytes") }),
            ("the init's default nonce fixed", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "= PairingController.secureNonce,", with: "= { [UInt8](repeating: 7, count: 32) },") }),
            ("the nonce source swapped as it is kept", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "        self.makeNonce = makeNonce\n", with: "        self.makeNonce = { [UInt8](repeating: 7, count: 32) }\n") }),
            ("the clock overridden in the wiring", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: wiring, with: "            clock: { Date(timeIntervalSince1970: 0) },\n" + wiring) }),
            ("another record source in the wiring", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "source: NoPairingRecords(), keys: keys,", with: "source: SpareRecords(), keys: keys,") }),
            ("a second controller in the app", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet zz = PairingController(source: s, keys: k, readRemembered: r, writeRemembered: w, killSwitch: {})" }),
            ("a second controller, init-spelled", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = PairingController.init(source: s, keys: k, readRemembered: r, writeRemembered: w, killSwitch: {})" }),
            ("a second controller by typed implicit init", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz: PairingController = .init(source: s, keys: k, readRemembered: r, writeRemembered: w, killSwitch: {})" }),
            ("a second controller through an unapplied init", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = PairingController.init" }),
            ("a second controller through a live one's dynamic type", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nfunc zz(_ p: PairingController) -> Any { type(of: p).init }" }),
            ("a convenience init in an extension", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nextension PairingController { convenience init(fixed: Bool) { self.init(source: s, keys: k, "
                    + "readRemembered: r, writeRemembered: w, makeNonce: { nil }, killSwitch: {}) } }" }),
            ("a second nonce source", Self.mutate(sources, controller) {
                $0 + "\nenum ZZ { nonisolated static func secureNonce(_ n: Int) -> [UInt8]? { [UInt8](repeating: 7, count: n) } }" }),
            ("a backticked second controller", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = `PairingController`(source: s, keys: k, readRemembered: r, writeRemembered: w, killSwitch: {})" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.freshFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the controller held, passed and asked for its
        // factory (the app's own uses); words that only contain the pinned
        // ones; and a whole-line comment naming the shapes.
        #expect(Self.freshFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nfunc zz(_ p: PairingController?) -> PairingController? { p }"
                + "\nlet secureNonceCount = 1, makeNonces = 2, readRememberedName = 3, typeOfThing = 4, subtype = 5"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never PairingController(…), never type(of: p).init, never secureNonce()")
        }).isEmpty)
    }
}
