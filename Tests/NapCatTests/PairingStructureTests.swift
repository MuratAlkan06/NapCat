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
///    names the slot (S-PAIR-C2 wires it, under its own locks). AMENDED for
///    S-PAIR-C2 (#181), deliberately: the slot reaches the decision path as
///    itself, at the verifier's one entry, handed on by the intake — no
///    approval file or the verifier names a pairing type anywhere else,
///    `PairedPhoneRead` included (a C1 security review probe's shape).
/// 4. The C1 tests touch nothing live.
/// 5. The sheet's keys: Esc ends it in every state; nothing answers Return.
/// 6. The nonce is fresh — the system's random source fills all of it — and
///    the app's controller is the one `makeIfEnabled` builds, whole.
///
/// AMENDED (the C1 security review's R3-R5): lock 1 also keeps the slot's
/// item private to it and pins every name that leads to the real keychain;
/// lock 2 pins every line of the sheet naming the payload and its one image;
/// lock 6 is new.
///
/// AMENDED (S-PAIR-C1.5, #170, the C1 security delta check's follow-ups): lock 1
/// also pins every use of the keychain store's calls and every account it
/// sets (d); lock 6 pins the live record source in the wiring and the
/// remembered name read from the app's own domain; and lock 7 is new:
///
/// 7. Nothing reflects, and the code never prints: no reflection in the four
///    targets but the redactions' own empty mirrors (a); the values holding
///    the nonce or the payload redact themselves, as types (b); and the QR
///    view is named at its sites alone (c).
///
/// AMENDED (S-PAIR-C1.5, the C1.5 security review's R1, R4 and R5): lock 7
/// also bans `descendant` and every `_forEachField…` reader and pins
/// `customMirror` to the redactions (a), redacts the controller, the slot
/// and the keychain store as types (b), and pins the sheet view and bans
/// off-screen rendering (c); lock 1 pins every `kSec…` line of the store.
///
/// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's F-A): lock 7
/// also bans, with no allowed site, every declaration that reaches the
/// runtime by name — `_silgen_name`, `_extern` — and every
/// `swift_reflectionMirror…` name (a). Runtime reflection ignores a type's
/// redaction; these bans, not the redactions, stop the Swift runtime's
/// field reader by name.
///
/// AMENDED (S-PAIR-C1.5, the delta re-check's round 2, F-D): the ObjC
/// runtime's ivar reader ignores the redaction too, so lock 7 also bans
/// the ObjC runtime's C API (`class_…`, `object_…`, `ivar_…` and their kin)
/// and `NSClassFromString`, with no allowed site (a). Raw-pointer reads
/// remain the accepted R-1 residual.
///
/// AMENDED (S-PAIR-C1.5, the delta re-check's round 3, F-F): a class, a
/// selector or a protocol looked up by name reaches what no pinned word
/// names — its S5 built a real container from MenuStateModel, with no
/// CloudKit import, by `Bundle.classNamed` and `NSSelectorFromString`. So
/// lock 7 bans every dynamic lookup by name — `NSClassFromString`,
/// `NSSelectorFromString`, `Selector`, `classNamed`, `NSProtocolFromString` —
/// beside the runtime's C API, with no allowed site (a). What the ObjC bans
/// stop: the runtime's C API (its ivar, method and property readers among
/// it) and lookup by name. Raw-pointer reads remain the accepted R-1
/// residual.
///
/// AMENDED (#240): lock 8 is new —
///
/// 8. Unpair runs after the owner's confirmation, or as Try Again while a
///    refused deletion stands; every Unpair runs the kill switch.
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
         ["KeychainTopicStore.swift": ["struct KeychainTopicStore: TopicStore {": 1, topicStoreLine: 1, itemLine: 1,
                                       "extension KeychainTopicStore" + conformance: 1],
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
        // S-PAIR-C1.5 (the C1 security delta check's (d)): inside the keychain store every use of its
        // calls is pinned, and the item's account is set at one place, from
        // its name — no hand-built query reaches the paired item.
        failures += appSiteFailures(#"\bcalls\b"#, in: sources.filter { $0.name == storeFile }, allowed: [storeFile: callsSites],
                                    rule: "the store's four keychain calls are made at their four sites, on its own query")
        failures += appSiteFailures(#"\bkSecAttrAccount\b"#, in: sources, allowed: [storeFile: [accountLine: 1]],
                                    rule: "an item's account is set at one place, in the store's base query, from its name")
        // The C1.5 security review's R4: every keychain attribute and value the store names.
        failures += appSiteFailures(#"\bkSec\w+"#, in: sources.filter { $0.name == storeFile }, allowed: [storeFile: keychainConstantSites],
                                    rule: "the store names keychain attributes in its three queries and its one update alone")
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    static let storeFile = "KeychainTopicStore.swift"
    static let accountLine = "kSecAttrAccount as String: item.account,"
    /// The C1.5 security review's R4 (its N-34d: `let put = <the add call>` and a
    /// hand-built query, in the store's own file, passed every lock): every
    /// line of the store naming a `kSec…` attribute or value — its base,
    /// read and add queries and its one update — so a query built anywhere
    /// else in its file is off the list. Chosen over banning the attributes'
    /// raw strings (`"acct"`, `"svce"`, `"v_Data"`): a ban on string literals
    /// is a deny-list that splitting defeats (RP4' itself split the account),
    /// and a dictionary of raw keys does nothing until a keychain call takes
    /// it — every call is pinned: each item call named once, as a word, at
    /// its binding (KeychainTopicStoreTests, R4's other half), and the store's
    /// `calls` at their four sites (above). A raw key slipped into the item's
    /// own queries is caught by value: the query tests pin each query's exact
    /// size and the absent sync, data-protection and access-group keys
    /// (`theQueriesAddressOneNonSynchronizableGenericPasswordItem`).
    static let keychainConstantSites = ["kSecClass as String: kSecClassGenericPassword,": 2, "kSecAttrService as String: item.service,": 1,
                                        accountLine: 1, "kSecReturnData as String: true,": 1, "kSecMatchLimit as String: kSecMatchLimitOne,": 2,
                                        "kSecValueData as String: data,": 1, "kSecAttrLabel as String: label,": 1,
                                        "kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,": 2,
                                        "let updated = calls.update(baseQuery, [kSecValueData as String: data])": 1]
    /// Every `calls` in the store's file: its stored calls, the two real
    /// stores handed the real ones, and its four uses.
    static let callsSites = ["let calls: KeychainItemCalls": 1, topicStoreLine: 1, itemLine: 1,
                             "let answer = calls.copyData(readQuery)": 1,
                             "let updated = calls.update(baseQuery, [kSecValueData as String: data])": 1,
                             "let added = calls.add(addAttributes(data))": 1, "let status = calls.delete(baseQuery)": 1]

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
            // The C1 security delta check's (d): a hand-built query written through the store's own
            // calls, inside its file; an account set anywhere else.
            ("a hand-built paired-key write through the store's calls", Self.mutate(sources, store) {
                $0 + "\nextension KeychainTopicStore {\n    func zz(_ d: Data) -> OSStatus {\n"
                    + "        calls.add([kSecClass as String: kSecClassGenericPassword, kSecValueData as String: d])\n    }\n}" }),
            ("the calls kept aside", Self.mutate(sources, store) {
                $0 + "\nextension KeychainTopicStore { var zz: KeychainItemCalls { calls } }" }),
            ("an account set elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz: [String: Any] = [kSecAttrAccount as String: \"x\"]" }),
            ("a second account in the store's query", Self.mutate(sources, store) {
                $0.replacingOccurrences(of: Self.accountLine, with: Self.accountLine + "\n            kSecAttrAccount as String: \"x\",") }),
        ]
        // The C1.5 security review's R4: its RP4', as planted (a keychain write
        // from a new site in the store's file — the call unapplied, the
        // account by its raw key, the literal split), and a query built aside
        // or widened in place. (The item-call half of R4 is
        // KeychainTopicStoreTests'; the call is spelled split here too.)
        let add = "Sec" + "Item" + "Add"
        let r4: [(String, Sources)] = [
            ("RP4': a keychain write from a new site in the store's file", Self.mutate(sources, store) {
                $0 + "\nfunc zzSecRevPlant(_ data: Data) -> OSStatus {\n    let put = " + add + "\n"
                    + "    return put([kSecClass as String: kSecClassGenericPassword, \"svce\": \"com.muratalkan.napcat\",\n"
                    + "                \"acct\": \"paired-\" + \"iphone-key\", \"v_Data\": data] as CFDictionary, nil)\n}\n" }),
            ("a query built aside in the store's file", Self.mutate(sources, store) {
                $0 + "\nextension KeychainItemName { static let zzQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword] }" }),
            ("an attribute added to the item's queries", Self.mutate(sources, store) {
                $0.replacingOccurrences(of: Self.accountLine, with: Self.accountLine + "\n            kSecAttrIsInvisible as String: true,") }),
            ("the read asks for every match", Self.mutate(sources, store) {
                $0.replacingOccurrences(of: "kSecMatchLimit as String: kSecMatchLimitOne,", with: "kSecMatchLimit as String: kSecMatchLimitAll,") }),
        ]
        for (name, mutant) in mutants + r3 + r4 {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.compareFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // R4: in lock 1 it is the kSec pin that catches RP4' (its account is
        // a raw key, split, and it makes its own call: nothing else here sees it).
        let rp4Failures = Self.compareFailures(r4[0].1)
        #expect(!rp4Failures.isEmpty && rp4Failures.allSatisfy { $0.contains(#"'\bkSec\w+'"#) }, "\(rp4Failures)")
        // R4 over-match controls, in the store's own file: a word that only
        // contains the prefix, and a whole-line comment naming an attribute.
        #expect(Self.compareFailures(Self.mutate(sources, store) {
            $0 + "\nlet zzkSecond = 1, isKSec = 2"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never kSecAttrSynchronizable, never kSecClass outside a query")
        }).isEmpty)
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
        // AMENDED (S-PAIR-C1.5, #170): and a remembered name of any other
        // shape than a pairing record's is forgotten, unused.
        let remembered = ApprovalRecordPathStructureTests.siteTally(#"\bwriteRemembered\s*\("#, in: controller)
        if remembered != ["writeRemembered(name)": 1, "if gone, readRemembered() == name { writeRemembered(nil) }": 1,
                          "if await source.delete(recordName: name), readRemembered() == name { writeRemembered(nil) }": 1,
                          "writeRemembered(nil)": 1] {
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

    // MARK: - 3. Nothing arms; the slot is wired to the verifier alone

    /// AMENDED for S-PAIR-C2 (#181), deliberately: `PairedPhoneRead` joined
    /// the list — `\bPairedPhone\b` does not match it, so a verifier handed a
    /// slot's reading (a C1 security review probe's shape) named no pinned
    /// type.
    static let pairingTypes = ["PairedKeyStore", "PairedPhone", "PairedPhoneRead", "PairingController", "PairingCeremonyState",
                               "PairingCandidate"]
    /// The approval files and the verifier.
    static let unwiredFiles = ApprovalRecordPathStructureTests.approvalFiles + [ApprovalRecordPathStructureTests.verifierFile]
    static let armingTokens = ApprovalRecordPathStructureTests.verdictAPITokens
        + ApprovalRecordPathStructureTests.verifierTypes + ["ApprovalDecision", "signatureVerified"]

    /// AMENDED for S-PAIR-C2 (#181), deliberately: the slot reaches the
    /// decision path, as the slot itself and no reading of it — the
    /// verifier's one entry takes it (and reads it there,
    /// `ApprovalRecordPathStructureTests` lock 9f), and the intake hands it
    /// on. No approval file or the verifier names a pairing type anywhere
    /// else: none keeps a slot, a paired phone or a reading of one.
    static let wiredSlotSites: [String: [String: Int]] = [
        ApprovalRecordPathStructureTests.verifierFile: [
            "static func verify(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,": 1],
        ApprovalChannelStructureTests.intakeFile: [
            "func receiveDecision(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,": 1],
    ]

    static func unwiredFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where pairingFiles.contains(name) {
            for token in armingTokens where text.contains(token) && !(name == controllerFile && token == "RemoteApprovalsController") {
                failures.append("'\(token)' in \(name) — pairing names nothing of the verdict API (the toggle only for its kill switch)")
            }
        }
        let typePattern = #"\b(?:"# + pairingTypes.joined(separator: "|") + #")\b"#
        failures += appSiteFailures(typePattern, in: sources.filter { unwiredFiles.contains($0.name) }, allowed: wiredSlotSites,
                                    rule: "the slot reaches the decision path as itself, at the verifier's one entry, handed on by "
                                        + "the intake (S-PAIR-C2)")
        let controller = text(controllerFile, in: sources)
        if ApprovalChannelStructureTests.count("RemoteApprovalsController", in: controller) != 1
            || !controller.contains("killSwitch: { [weak remoteApprovals] in remoteApprovals?.setEnabled(false) })") {
            failures.append("the pairing reaches the toggle once: Unpair's kill switch (setEnabled(false))")
        }
        return failures
    }

    @Test func nothingArmsAndTheSlotIsWiredToTheVerifierAlone() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.unwiredFailures(sources).isEmpty, "\(Self.unwiredFailures(sources))")
        let verifier: String = ApprovalRecordPathStructureTests.verifierFile
        let head: String = "enum DecisionVerifier {\n"
        #expect(Self.text(verifier, in: sources).contains(head), "vacuity: the verifier's body is where the in-body canary plants")
        let mutants: [(String, Sources)] = [
            ("the verifier keeps a slot", Self.mutate(sources, verifier) { $0 + "\nenum ZZ { static var keys: PairedKeyStore? }" }),
            ("the intake reads the slot", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nlet zz: PairedPhone? = nil" }),
            // A C1 security review probe, as planted, and in the verifier's body.
            ("the verifier reads the slot through PairedPhoneRead, as the probe planted it", Self.mutate(sources, verifier) {
                $0 + "\nextension DecisionVerifier { static func zz(_ r: PairedPhoneRead) -> [UInt8]? { "
                    + "if case .paired(let p) = r { return p.publicKey }; return nil } }" }),
            ("the same read in the verifier's body", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: head, with: head + "    static func zz(_ r: PairedPhoneRead) -> [UInt8]? { "
                    + "if case .paired(let p) = r { return p.publicKey }; return nil }\n") }),
            ("the intake keeps a reading", Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
                $0 + "\nextension ApprovalIntake { static let zzRead = PairedPhoneRead.notPaired }" }),
            ("the host keeps the slot", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0 + "\nlet zzKeys: PairedKeyStore? = nil" }),
            ("the toggle keeps a paired phone", Self.mutate(sources, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nlet zzPhone: `PairedPhone`? = nil" }),
            ("the slot's entry moved", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "copy: ForwardedCopy?, keys: PairedKeyStore,", with: "copy: ForwardedCopy?, keys: PairedKeyStore?,") }),
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
        // Over-match controls: names that only start like the pairing types,
        // and a whole-line comment naming them, in the approval files.
        #expect(Self.unwiredFailures(Self.mutate(sources, ApprovalChannelStructureTests.intakeFile) {
            $0 + "\nlet pairedKeyStoreCount = 0, PairedPhoneReadings = 1"
                + LidGuardStructureTests.codeOnly("\n/// never a PairedKeyStore kept, never a PairedPhoneRead handed in")
        }).isEmpty)
    }

    // MARK: - 4. The C1 tests touch nothing live

    /// AMENDED (S-PAIR-C1.5, #170): and the live transport's tests, which
    /// play CloudKit's part on the real operations through a scripted
    /// database — never the live one or its factory.
    static let testFiles = ["PairingCeremonyTests.swift", "PairingControllerTests.swift", "PairingPresentationTests.swift",
                            "PairingResponseReaderTests.swift", "PairedKeyStoreTests.swift", "PairingFingerprintVectorTests.swift",
                            "CloudKitPairingRecordsTests.swift"]
    /// The live parts: the real keychain items and bindings (split so no
    /// test file spells them), the real defaults, the app's factories, the
    /// live tick, the system random source, the announcer, and CloudKit's
    /// container and database (and, since S-PAIR-C1.5, the live pairing
    /// database and its factory).
    static let liveTokens = ["pairedPhone" + "Keychain", "login" + "Keychain", "security" + "Framework", "Sec" + "Item",
                             "UserDefaults.standard", "makeIfEnabled(", "TimerPairingTicker", "secureNonce", "Pairing" + "Announcer",
                             "CKContainer", "CKDatabase", "SecRandomCopyBytes", "NSApp.", "makeKeyAndOrderFront",
                             "makeLive" + "PairingDatabase", "Live" + "PairingRecordDatabase"]

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
    /// (since S-PAIR-C1.5 the live `CloudKitPairingRecords`; the C1 stub
    /// `NoPairingRecords` is gone — ApprovalRecordPathStructureTests lock 10),
    /// and no seam overridden there or by a changed
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
    /// AMENDED (S-PAIR-C1.5, #170): the record source is the live one
    /// (`CloudKitPairingRecords` over the probe-gated live database; the C1
    /// stub is gone), and the remembered name is read from the app's own
    /// persistent domain only — never the defaults search list.
    static let readRememberedLine = "readRemembered: { Self.rememberedName(in: defaults.persistentDomain(forName: domain)) },"
    static let makeIfEnabledBody = "static func makeIfEnabled(remoteApprovals: RemoteApprovalsController?, keys: PairedKeyStore,"
        + " defaults: UserDefaults) -> PairingController? {"
        + " guard let remoteApprovals else { return nil }"
        + " let domain = Bundle.main.bundleIdentifier ?? \"\""
        + " return PairingController( " + PhoneTransportStructureTests.pairingWiring
        + " " + readRememberedLine
        + " writeRemembered: { name in"
        + " if let name { defaults.set(name, forKey: DefaultsKey.pairingRecordToDelete) }"
        + " else { defaults.removeObject(forKey: DefaultsKey.pairingRecordToDelete) } },"
        + " killSwitch: { [weak remoteApprovals] in remoteApprovals?.setEnabled(false) }) }"
    /// AMENDED (#205): the remote-approvals toggle is read from the app's own
    /// persistent domain too — by its one reader, which its factory alone
    /// calls, on the app's own domain name — so a launch argument, the global
    /// domain or a registered default can never turn it on.
    static let toggleReadLine: String =
        "RemoteApprovalsPolicy.enabled(stored: defaults.persistentDomain(forName: domain)?[DefaultsKey.remoteApprovalsEnabled],"
    static let toggleReaderHead: String = "nonisolated static func storedToggle(_ defaults: UserDefaults, domain: String) -> Bool {"
    static let toggleReaderCall: String = "readStored: { Self.storedToggle(defaults, domain: Bundle.main.bundleIdentifier ?? \"\") },"

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
                                                     readRememberedLine: 1]],
         "every call of the controller's init names readRemembered — makeIfEnabled's is the one"),
        // S-PAIR-C1.5 (#170): the app's own persistent domain is read once,
        // by the remembered name's one reader — and (#205) once more, by the
        // remote-approvals toggle's one reader: exactly two sites.
        (#"\bpersistentDomain\b"#, [controllerFile: [readRememberedLine: 1], ApprovalChannelStructureTests.toggleFile: [toggleReadLine: 1]],
         "the app's own persistent domain is read by the remembered name's reader and the toggle's, nothing else"),
        (#"\brememberedName\b"#, [controllerFile: [readRememberedLine: 1,
                                                   "nonisolated static func rememberedName(in domain: [String: Any]?) -> String? {": 1]],
         "the remembered name has one reader, called by makeIfEnabled alone"),
        // #205: the toggle's reader is called by its factory alone, on the
        // app's own domain name.
        (#"\bstoredToggle\b"#, [ApprovalChannelStructureTests.toggleFile: [toggleReaderHead: 1, toggleReaderCall: 1]],
         "the toggle has one reader, called by its factory alone, on the app's own domain"),
    ]
    static let rememberedNameBody = "nonisolated static func rememberedName(in domain: [String: Any]?) -> String? {"
        + " domain?[DefaultsKey.pairingRecordToDelete] as? String }"
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
                             (makeIfEnabledBody, "makeIfEnabled builds the controller on the live record source, reading the "
                                + "remembered name from the app's own domain, no seam overridden — exactly as pinned"),
                             (rememberedNameBody, "the remembered name is the app domain's text, nothing else — exactly as pinned")]
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
        let toggle: String = ApprovalChannelStructureTests.toggleFile
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
                $0.replacingOccurrences(of: "source: CloudKitPairingRecords(database: { CloudKitMessageSender.makeLivePairingDatabase() }), keys: keys,",
                                        with: "source: SpareRecords(), keys: keys,") }),
            // S-PAIR-C1.5 (#170): the remembered name read through the
            // defaults search list again, from another domain, or as more
            // than text; and a second reader of the persistent domain.
            ("the remembered name read through the search list", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: Self.readRememberedLine,
                                        with: "readRemembered: { defaults.string(forKey: DefaultsKey.pairingRecordToDelete) },") }),
            ("the remembered name read from the global domain", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "let domain = Bundle.main.bundleIdentifier ?? \"\"",
                                        with: "let domain = UserDefaults.globalDomain") }),
            ("the remembered name taken in any form", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "domain?[DefaultsKey.pairingRecordToDelete] as? String",
                                        with: "domain?[DefaultsKey.pairingRecordToDelete].map { \"\\($0)\" }") }),
            ("a second reader of the persistent domain", Self.mutate(sources, controller) {
                $0 + "\nextension PairingController { static func zz(_ d: UserDefaults) -> Any? { d.persistentDomain(forName: \"x\") } }" }),
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
            // #205: the toggle read through the search list alone, from the
            // global domain, or by a second caller; and a third reader of the
            // persistent domain beside the two, in the toggle or the model.
            ("the toggle read through the search list alone", Self.mutate(sources, toggle) {
                $0.replacingOccurrences(of: "stored: defaults.persistentDomain(forName: domain)?[DefaultsKey.remoteApprovalsEnabled],",
                                        with: "stored: defaults.object(forKey: DefaultsKey.remoteApprovalsEnabled),") }),
            ("the toggle read from the global domain", Self.mutate(sources, toggle) {
                $0.replacingOccurrences(of: "domain: Bundle.main.bundleIdentifier ?? \"\") },", with: "domain: UserDefaults.globalDomain) },") }),
            ("the toggle's reader called again", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = RemoteApprovalsController.storedToggle(.standard, domain: \"x\")" }),
            ("a third reader of the persistent domain, in the toggle", Self.mutate(sources, toggle) {
                $0 + "\nextension RemoteApprovalsController { static func zz(_ d: UserDefaults) -> Any? { d.persistentDomain(forName: \"x\") } }" }),
            ("a third reader of the persistent domain, in the model", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet zz = UserDefaults.standard.persistentDomain(forName: \"com.muratalkan.napcat\")" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.freshFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // #205 vacuity: the toggle's two pinned lines are where the canaries
        // plant; and an over-match control — words that only contain the
        // pinned ones.
        for line in [Self.toggleReadLine, Self.toggleReaderCall] {
            #expect(ApprovalChannelStructureTests.count(line, in: Self.text(toggle, in: sources)) == 1, "vacuity: '\(line.prefix(40))'")
        }
        let wordsOnly: Sources = Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet storedToggles = 1, persistentDomains = 2" }
        #expect(wordsOnly.map { $0.text } != sources.map { $0.text } && Self.freshFailures(wordsOnly).isEmpty,
                "over-match: \(Self.freshFailures(wordsOnly))")
        // Over-match controls: the controller held, passed and asked for its
        // factory (the app's own uses); words that only contain the pinned
        // ones; and a whole-line comment naming the shapes.
        #expect(Self.freshFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nfunc zz(_ p: PairingController?) -> PairingController? { p }"
                + "\nlet secureNonceCount = 1, makeNonces = 2, readRememberedName = 3, typeOfThing = 4, subtype = 5"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never PairingController(…), never type(of: p).init, never secureNonce()")
        }).isEmpty)
    }

    // MARK: - 7. Nothing reflects, and the code never prints (S-PAIR-C1.5, the C1 security delta check)

    /// The C1 security delta check's follow-ups (a)-(c), its MN1 probe as planted: a
    /// `Mirror` reached the paired-key slot's private item from a file
    /// holding the controller, and an accessibility hint carried
    /// `String(describing:)` of the sheet's content.
    /// (a) No reflection in the four targets — `Mirror` by any spelling, and
    ///     the runtime's underscored field readers — but the redactions' own
    ///     childless mirrors, on their pinned lines. (`ObservedStayAwakeMirror`
    ///     and its kin are other words.)
    /// (b) The values that hold the nonce (the state machine; the event that
    ///     hands it in) or the payload (the sheet's content; the QR view)
    ///     describe, debug-describe and reflect as their type's name alone:
    ///     each conformance pinned whole, the type's own, so it holds however
    ///     and wherever the value is described (the behaviour is
    ///     `PairingPresentationTests.theCodeIsNeverPrintedDumpedOrReflected`).
    /// (c) The QR view is named at its declaration, its redaction and its one
    ///     use, nowhere else in the four targets.
    ///
    /// AMENDED (S-PAIR-C1.5, the C1.5 security review's R1 and R5): its RP1
    /// wrote a fake key into the slot from MenuStateModel through
    /// `[pairing].customMirror.descendant(0, "keys", "items")` — no `Mirror`
    /// named — and its RP5 rendered a second sheet view off screen. So:
    /// (a) also bans `descendant` and every `_forEachField…` reader, and
    ///     `customMirror` is named by the redactions' declarations alone (no
    ///     mirror is read or walked);
    /// (b) also covers what leads to the paired-key slot — the controller
    ///     (on its declaration: an extension of it is banned, lock 6), the
    ///     slot and the keychain store — so no print, description or
    ///     `Mirror`-based walk, through any wrapper, reaches the slot's item
    ///     or the real calls (the behaviour is
    ///     `PairingControllerTests.noReflectionReachesThePairedKeySlot` and
    ///     `KeychainTopicStoreTests.theStoreReflectsAndPrintsNothing`). The
    ///     runtimes' own readers ignore the redaction: the bans of (a) stop
    ///     the Swift runtime's field reader by name and the ObjC runtime's
    ///     ivar reader; raw-pointer reads remain the accepted R-1 residual
    ///     (AMENDED again below);
    /// (c) also pins the sheet view to its declaration and its one
    ///     presentation, and bans rendering a view, a window or the screen
    ///     to an image or a document off screen, in the four targets.
    static let reflectionPattern = #"\bMirror\b|\b_forEachField\w*|\b_reflect\b|\b_getChild\w*|\bdescendant\b"#
    static let structMirror = "var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }"
    static let enumMirror = "var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }"
    static let classMirror = "var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }"
    /// The alert topic the gate's floor is handed (#253): a public type of
    /// the wire, so its members are public, its conformance on its
    /// declaration.
    static let floorFile = "ApprovalFloor.swift"
    static let topicMirror = "public " + enumMirror
    /// Each line holds two matches (the type and its construction).
    static let mirrorSites: [String: [String: Int]] = [
        ceremonyFile: [structMirror: 2, enumMirror: 2],
        sheetFile: [structMirror: 2, "nonisolated " + structMirror: 2],
        controllerFile: ["nonisolated " + classMirror: 2],
        slotFile: [structMirror: 2],
        storeFile: [structMirror: 2],
        floorFile: [topicMirror: 2],
    ]
    /// R1: `customMirror` is named once on each of those lines — its
    /// declaration — and nowhere else.
    static let customMirrorSites = mirrorSites.mapValues { lines in lines.mapValues { _ in 1 } }
    static let redactionConformances = "CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable"
    static let conformance = ": " + redactionConformances + " {"
    static func members(_ text: String, _ mirror: String, nonisolated: Bool = false) -> String {
        let prefix = nonisolated ? "nonisolated " : ""
        return prefix + "var description: String { \"" + text + "\" } " + prefix + "var debugDescription: String { description } "
            + prefix + mirror
    }
    static func redaction(_ type: String, _ text: String, _ mirror: String, nonisolated: Bool = false) -> String {
        "extension " + type + conformance + " " + members(text, mirror, nonisolated: nonisolated) + " }"
    }
    /// R1: the controller's conformance is on its declaration, its members
    /// in its body (no extension of the controller is allowed, lock 6). The
    /// fixed words name no type: a `PairingController(` or a
    /// `KeychainTopicStore` in a string would be a site of locks 6 and 1.
    static let controllerDeclaration = "final class PairingController: ObservableObject, " + redactionConformances + " {"
    static let redactions: [(file: String, block: String)] = [
        (ceremonyFile, redaction("PairingCeremonyState", "PairingCeremonyState(redacted)", structMirror)),
        (ceremonyFile, redaction("PairingEvent", "PairingEvent(redacted)", enumMirror)),
        (sheetFile, redaction("PairingSheetContent", "PairingSheetContent(redacted)", structMirror)),
        (sheetFile, redaction("QRCodeView", "QR code (redacted)", structMirror, nonisolated: true)),
        (controllerFile, controllerDeclaration),
        (controllerFile, members("pairing (redacted)", classMirror, nonisolated: true)),
        (slotFile, redaction("PairedKeyStore", "paired key slot (redacted)", structMirror)),
        (storeFile, redaction("KeychainTopicStore", "keychain item (redacted)", structMirror)),
        (floorFile, "public enum ApprovalFloorTopic: Sendable, " + redactionConformances + " {"),
        (floorFile, "public var description: String { \"alert topic (redacted)\" } public var debugDescription: String { description } "
            + topicMirror),
    ]
    /// The types that redact themselves, file by file, and the members that
    /// do it: each declared once per type, in its redaction (no other
    /// `description` and the like in their files).
    static let redactingTypes = [ceremonyFile: 2, sheetFile: 2, controllerFile: 1, slotFile: 1, storeFile: 1, floorFile: 1]
    static let redactionMembers = [#"\bvar\s+description\b"#, #"\bvar\s+debugDescription\b"#, #"\bvar\s+customMirror\b"#]
    static let qrViewSites: [String: [String: Int]] = [
        sheetFile: ["QRCodeView(payload: payload)": 1, "struct QRCodeView: View {": 1, "extension QRCodeView" + conformance: 1],
    ]
    /// R5: the sheet view, at its declaration and its one presentation (the
    /// probe's second sheet view in a hosting view, and RP5's in an image
    /// renderer, each name it).
    static let sheetViewSites: [String: [String: Int]] = [
        sheetFile: ["struct PairingSheetView: View {": 1],
        "MenuContentView.swift": ["settingsWindow.presentSheet(PairingSheetView(pairing: pairing))": 1],
    ]
    /// R5: what renders a view, a window or the screen to an image or a
    /// document off screen — SwiftUI's renderer, AppKit's cached display and
    /// PDF/EPS forms, CoreGraphics' window and display captures (a word
    /// prefix: every variant), ScreenCaptureKit's screenshots. Zero uses in
    /// the four targets.
    static let offscreenCaptureTokens = [#"\bImageRenderer\b"#, #"\bcacheDisplay\b"#, #"\bbitmapImageRepForCachingDisplay\b"#,
                                         #"\bdataWithPDF\b"#, #"\bdataWithEPS\b"#, #"\bCGWindowListCreateImage\w*"#,
                                         #"\bCGDisplayCreateImage\w*"#, #"\bSCScreenshotManager\b"#]

    static func reflectionFailures(_ sources: Sources) -> [String] {
        guard !text(ceremonyFile, in: sources).isEmpty, !text(sheetFile, in: sources).isEmpty,
              redactingTypes.keys.allSatisfy({ !text($0, in: sources).isEmpty }) else {
            return ["a pairing file is missing — the reflection lock would be vacuous"]
        }
        var failures = appSiteFailures(reflectionPattern, in: sources, allowed: mirrorSites,
                                       rule: "nothing reflects but the redactions' own childless mirrors")
        failures += appSiteFailures(#"\bcustomMirror\b"#, in: sources, allowed: customMirrorSites,
                                    rule: "customMirror is the redactions' own declaration — no mirror is read or walked")
        for (file, block) in redactions where ApprovalChannelStructureTests.count(block, in: MenuPanelStructureTests.flat(text(file, in: sources))) != 1 {
            failures.append("a value holding the code or the slot redacts itself, as a type — exactly as pinned: \(block)")
        }
        for (name, text) in sources {
            guard let expected = redactingTypes[name] else { continue }
            for member in redactionMembers where ApprovalRecordPathStructureTests.matches(member, in: text).count != expected {
                failures.append("'\(member)' in \(name) — declared by the redactions alone")
            }
        }
        failures += appSiteFailures(#"\bQRCodeView\b"#, in: sources, allowed: qrViewSites,
                                    rule: "the QR view is named at its declaration, its redaction and its one use")
        failures += appSiteFailures(#"\bPairingSheetView\b"#, in: sources, allowed: sheetViewSites,
                                    rule: "the sheet view is named at its declaration and its one presentation")
        for token in offscreenCaptureTokens {
            failures += appSiteFailures(token, in: sources, allowed: [:],
                                        rule: "nothing renders a view, a window or the screen off screen")
        }
        failures += runtimeEntryFailures(sources)
        failures += objcRuntimeFailures(sources)
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    /// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's F-A): its G1b
    /// declared the runtime's own field reader by name —
    /// `@_silgen_name("swift_reflectionMirror_count")` and `_subscript` —
    /// and read the slot's item straight through the redacted controller (at
    /// runtime it wrote an attacker's key into the fake slot). That reader
    /// is the one `_forEachField` wraps: it ignores `CustomReflectable` and
    /// reads the stored fields as declared, so no type redaction can stop it,
    /// and it names no `Mirror`, `descendant`, `customMirror` or
    /// `_forEachField` — as planted it passed every lock. So (a) also bans,
    /// in the four targets, in every scan copy, with no allowed site: an
    /// `@_silgen_name` and an `@_extern` (each declares a runtime or C entry
    /// point by name) and any `swift_reflectionMirror…` name (the reader's
    /// entry points, however they would be reached). The redactions stop
    /// printing, describing and `Mirror`-based walks; these bans, not the
    /// redactions, stop the Swift runtime's field reader by name, and the
    /// ObjC runtime bans below stop its ivar reader. Raw-pointer reads
    /// remain the accepted R-1 residual.
    static let runtimeEntryTokens = [#"\b_silgen_name\b"#, #"\b_extern\b"#, #"\bswift_reflectionMirror\w*"#]

    static func runtimeEntryFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for token in runtimeEntryTokens {
            failures += appSiteFailures(token, in: sources, allowed: [:],
                                        rule: "nothing declares a runtime entry point — the runtime's field reader ignores every redaction")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    /// AMENDED (S-PAIR-C1.5, the C1.5 security delta re-check's round 2,
    /// F-D): the ObjC runtime reads a pure Swift class's stored properties
    /// too — `class_copyIvarList`, `ivar_getName` and `object_getIvar` list
    /// and read every one, and ignore `CustomReflectable` (the re-check saw
    /// the redacted controller's mirror show no child while its ivar list
    /// showed all eighteen stored properties). Its N10b walked a live
    /// database's own ivars to its private database from an extension in the
    /// sender; its N10x walked pairing → source → live → database from
    /// MenuStateModel, through the redacted controller. Neither named a
    /// banned word; each passed every suite. So (a) also bans, in the four
    /// targets, in every scan copy, with no allowed site (none today): the
    /// ObjC runtime's C API by its families' prefixes (`class_`, `object_`,
    /// `ivar_`, `method_`, `property_`, `protocol_`, `sel_`, `imp_`, `objc_`)
    /// and `NSClassFromString`. These bans and the entry-point bans above
    /// stop the Swift runtime's field reader by name and the ObjC runtime's
    /// ivar reader; raw-pointer reads remain the accepted R-1 residual.
    ///
    /// AMENDED (S-PAIR-C1.5, the delta re-check's round 3, F-F): its S5
    /// looked up `CKContainer` by `Bundle(identifier:)?.classNamed(_:)` and
    /// built a real container by `perform(NSSelectorFromString(…))` from
    /// MenuStateModel — no CloudKit import, neither factory, no entitlement
    /// probe — and its S4b sent a real request by a looked-up selector: c9
    /// banned `NSClassFromString` alone, and each passed every lock. So (a)
    /// also bans, the same way, every lookup by name — of a class
    /// (`NSClassFromString`, `classNamed`), a selector (`NSSelectorFromString`,
    /// `Selector`) or a protocol (`NSProtocolFromString`) — with no allowed
    /// site (none today; `#selector` names a declared method, and is another
    /// word). What these two bans stop, and no more: a call of the runtime's
    /// C API (its ivar, method and property readers among it), and a class,
    /// a selector or a protocol reached by a string. Raw-pointer reads remain
    /// the accepted R-1 residual.
    static let objcRuntimeTokens: [String] = [#"\b(?:class|object|ivar|method|property|protocol|sel|imp|objc)_[A-Za-z]\w*"#]
    static let objcLookupTokens: [String] = [#"\bNSClassFromString\b"#, #"\bNSSelectorFromString\b"#, #"\bSelector\b"#,
                                             #"\bclassNamed\b"#, #"\bNSProtocolFromString\b"#]

    /// The lookup ban alone.
    static func objcLookupFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for token in objcLookupTokens {
            failures += appSiteFailures(token, in: sources, allowed: [:],
                                        rule: "nothing looks up a class, a selector or a protocol by name — a string reaches what no pinned word names")
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    /// Both ObjC bans: the runtime's C API, then lookup by name.
    static func objcRuntimeFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for token in objcRuntimeTokens {
            failures += appSiteFailures(token, in: sources, allowed: [:],
                                        rule: "nothing calls the ObjC runtime's C API — its ivar reader ignores every redaction")
        }
        failures += objcLookupFailures(sources)
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    /// The round-2 re-check's F-D, its canaries: N10b and N10x's model-side
    /// chain, verbatim. Lock 7 catches each, and by the ObjC runtime ban
    /// alone: its other rules miss both, the gap. Each family bites alone,
    /// and N10b's four reader names match in every scan copy of its text.
    /// AMENDED (round 3, F-F; renamed from `nothingReachesTheObjCRuntime`,
    /// which claimed more than the bans stop): S5 and S4b, verbatim, each
    /// caught within lock 7 by the lookup ban alone; each lookup word bites
    /// its own probe alone; S5's lookups match in every scan copy.
    @Test func nothingCallsTheObjCRuntimeOrLooksUpByName() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.objcRuntimeFailures(sources).isEmpty, "\(Self.objcRuntimeFailures(sources))")
        let sender = "CloudKitMessageSender.swift"
        let model = "MenuStateModel.swift"
        #expect(!Self.text(sender, in: sources).isEmpty && !Self.text(model, in: sources).isEmpty, "vacuity: both files are in the scan")
        // The re-check's texts (its gapplant.py), verbatim.
        let n10b: String = "\nextension LivePairingRecordDatabase {\n    func zz(_ i: CKRecord.ID) {\n        var n: UInt32 = 0\n"
            + "        guard let list = class_copyIvarList(object_getClass(self), &n) else { return }\n        defer { free(list) }\n"
            + "        for k in 0..<Int(n) where ivar_getName(list[k]).map({ String(cString: $0) }) == \"data\" + \"base\" {\n"
            + "            (object_getIvar(self, list[k]) as? CKDatabase)?.fetch(withRecordID: i) { _, _ in }\n        }\n    }\n}\n"
        let n10xChain: [String] = [
            "\nextension MenuStateModel {\n    func zzIvarChain(_ name: String) {\n        guard let pairing else { return }\n",
            "        func get(_ o: AnyObject, _ label: String) -> AnyObject? {\n            var n: UInt32 = 0\n",
            "            guard let list = class_copyIvarList(object_getClass(o), &n) else { return nil }\n            defer { free(list) }\n",
            "            for k in 0..<Int(n) where ivar_getName(list[k]).map({ String(cString: $0) }) == label { return object_getIvar(o, list[k]) as AnyObject? }\n",
            "            return nil\n        }\n",
            "        zzUseDatabase(get(pairing, \"source\").flatMap { get($0, \"live\") }.flatMap { get($0, \"data\" + \"base\") }, name)\n    }\n}\n",
        ]
        let n10x: String = n10xChain.joined()
        let lookup: String = "\nlet zz: AnyClass? = NSClassFromString(\"zz\")\n"
        let mutants: [(String, Sources)] = [
            ("N10b: a live database's own ivars walked to its private database", Self.mutate(sources, sender) { $0 + n10b }),
            ("N10x: pairing, source, live, database walked from the model", Self.mutate(sources, model) { $0 + n10x }),
            ("a class looked up by name, in the seam", Self.mutate(sources, ApprovalChannelStructureTests.seamFile) { $0 + lookup }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            let caught = Self.objcRuntimeFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            // Within lock 7, the new ban alone: every other rule misses it.
            #expect(Self.reflectionFailures(mutant) == caught, "canary '\(name)': another lock 7 rule fired")
        }
        // Each family bites, through the lock's own engine (and only its own
        // pattern).
        let families: [String] = ["class_copyIvarList(c, &n)", "object_getIvar(o, i)", "ivar_getName(i)", "method_getImplementation(m)",
                                  "property_getName(p)", "protocol_copyPropertyList(p, &n)", "sel_registerName(s)",
                                  "imp_implementationWithBlock(b)", "objc_getAssociatedObject(o, k)"]
        for probe in families {
            #expect(ApprovalRecordPathStructureTests.hits(Self.objcRuntimeTokens[0], in: probe), "'\(probe)' was NOT caught")
            #expect(Self.objcLookupTokens.allSatisfy { !ApprovalRecordPathStructureTests.hits($0, in: probe) })
        }
        // N10b's four reader names, in every scan copy of its exact text.
        let copies: [String] = [n10b, n10b.replacingOccurrences(of: "`", with: ""), LidGuardStructureTests.cleaned(n10b)]
        let readers: [String] = ["class_copyIvarList", "object_getClass", "ivar_getName", "object_getIvar"]
        for copy in copies {
            #expect(ApprovalRecordPathStructureTests.matches(Self.objcRuntimeTokens[0], in: copy) == readers)
        }
        // Round 3's F-F: S5 (a container built from a looked-up class and
        // selector, in the model, with no CloudKit import) and S4b (a request
        // sent by a looked-up selector), verbatim. Within lock 7, the lookup
        // ban alone: the C API ban and every other rule miss both, the gap.
        let roundThree: [(String, Sources)] = [
            ("S5: a container built and asked by looked-up names", Self.mutate(sources, model) { $0 + PhoneTransportStructureTests.s5Model }),
            ("S4b: a request sent by a looked-up selector", Self.mutate(sources, model) { $0 + PhoneTransportStructureTests.s4bModel }),
        ]
        for (name, mutant) in roundThree {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            let caught: [String] = Self.objcLookupFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            #expect(Self.reflectionFailures(mutant) == caught, "canary '\(name)': another lock 7 rule fired")
        }
        // Each lookup word bites its own probe alone, through the lock's own
        // engine (and the C API ban none of them).
        let lookups: [String] = ["NSClassFromString(n)", "NSSelectorFromString(s)", "Selector((\"zz\"))", "b.classNamed(n)",
                                 "NSProtocolFromString(n)"]
        #expect(lookups.count == Self.objcLookupTokens.count)
        for (i, token) in Self.objcLookupTokens.enumerated() {
            for (j, probe) in lookups.enumerated() {
                #expect(ApprovalRecordPathStructureTests.hits(token, in: probe) == (i == j), "'\(token)' against '\(probe)'")
            }
        }
        #expect(lookups.allSatisfy { !ApprovalRecordPathStructureTests.hits(Self.objcRuntimeTokens[0], in: $0) })
        // S5's lookups, in every scan copy of its exact text.
        let s5: String = PhoneTransportStructureTests.s5Model
        let s5Copies: [String] = [s5, s5.replacingOccurrences(of: "`", with: ""), LidGuardStructureTests.cleaned(s5)]
        for copy in s5Copies {
            #expect(ApprovalRecordPathStructureTests.matches(Self.objcLookupTokens[3], in: copy) == ["classNamed"])
            #expect(ApprovalRecordPathStructureTests.matches(Self.objcLookupTokens[1], in: copy)
                    == ["NSSelectorFromString", "NSSelectorFromString"])
        }
        // Over-match controls: words that only contain the banned ones, the
        // ObjC attributes, Swift's own `class` and `protocol`, a `#selector`
        // and its argument label, and a whole-line comment naming the lookups.
        let near: String = "\nlet zzclass_x = 1, isObject_y = 2, Ivar_z = 3, objcName = 4, selector = 5, method = 6"
            + "\n@objc protocol ZZP {}\nfinal class ZZC: NSObject { @objc func zz() {} }\nlet zzNSClassFromStringCount = 7"
            + "\nlet zzSelector = #selector(ZZC.zz), Selectors = 8, isClassNamed = 9, classNamedCount = 10, zzNSSelectorFromString = 11"
            + "\nfunc zz(_ c: NotificationCenter, _ o: ZZC) { c.addObserver(o, selector: #selector(ZZC.zz), name: nil, object: nil) }"
            + LidGuardStructureTests.codeOnly("\n/// never NSSelectorFromString(s), never Selector(\"zz\"), never classNamed(_:)")
        #expect(Self.reflectionFailures(Self.mutate(sources, model) { $0 + near }).isEmpty)
    }

    @Test func nothingReflectsAndTheCodeNeverPrints() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.reflectionFailures(sources).isEmpty, "\(Self.reflectionFailures(sources))")
        let model = "MenuStateModel.swift"
        let hintAnchor = "                    .accessibilityFocused($titleFocused)\n"
        // The delta check's MN1, as planted (both halves, each alone too).
        let mn1Reflect = "\nextension MenuStateModel {\n    func zzReflectWrite(_ p: PairedPhone) -> Bool {\n"
            + "        guard let pairing, let item = Mirror(reflecting: pairing).descendant(\"keys\", \"items\") as? any TopicStore else { return false }\n"
            + "        return item.write(PairedKeyStore.text(of: p))\n    }\n}\n"
        let mn1Hint = hintAnchor + "                    .accessibilityHint(Text(verbatim: String(describing: content)))\n"
        #expect(Self.text(Self.sheetFile, in: sources).contains(hintAnchor), "vacuity: MN1's hint plants on the title")
        let mutants: [(String, Sources)] = [
            ("MN1 as planted", Self.mutate(Self.mutate(sources, model) { $0 + mn1Reflect }, Self.sheetFile) {
                $0.replacingOccurrences(of: hintAnchor, with: mn1Hint) }),
            ("MN1's Mirror route alone", Self.mutate(sources, model) { $0 + mn1Reflect }),
            ("a module-qualified Mirror", Self.mutate(sources, model) { $0 + "\nfunc zz(_ x: Any) -> Int { Swift.Mirror(reflecting: x).children.count }" }),
            ("a backticked Mirror", Self.mutate(sources, model) { $0 + "\nfunc zz(_ x: Any) -> Int { `Mirror`(reflecting: x).children.count }" }),
            ("an aliased Mirror", Self.mutate(sources, "NapCatApp.swift") { $0 + "\ntypealias ZZ = Mirror" }),
            ("the runtime's field reader", Self.mutate(sources, model) {
                $0 + "\nfunc zz(_ t: Any.Type) { _ = _forEachField(of: t, options: []) { _, _, _, _ in true } }" }),
            ("a reflection in another target", Self.mutate(sources, "SeamSocket.swift") { $0 + "\nfunc zz(_ x: Any) { _ = Mirror(reflecting: x) }" }),
            ("another type's mirror, exposing the code", Self.mutate(sources, Self.controllerFile) {
                $0 + "\nextension PairingController: CustomReflectable {\n    var customMirror: Mirror { Mirror(self, children: [\"code\": state.qrPayload as Any]) }\n}" }),
            // (b): a redaction dropped, bent, or given children.
            ("the content's redaction dropped", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "extension PairingSheetContent" + Self.conformance,
                                        with: "extension PairingSheetContent: CustomDebugStringConvertible, CustomReflectable {") }),
            ("the content described by its payload", Self.mutate(sources, Self.sheetFile) {
                $0.replacingOccurrences(of: "var description: String { \"PairingSheetContent(redacted)\" }",
                                        with: "var description: String { qrPayload ?? \"\" }") }),
            ("the state's mirror given its parts", Self.mutate(sources, Self.ceremonyFile) {
                $0.replacingOccurrences(of: "var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }",
                                        with: "var customMirror: Mirror { Mirror(reflecting: self) }") }),
            ("the event's debug description its default", Self.mutate(sources, Self.ceremonyFile) {
                $0.replacingOccurrences(of: "extension PairingEvent" + Self.conformance,
                                        with: "extension PairingEvent: CustomStringConvertible, CustomReflectable {")
                    .replacingOccurrences(of: "    var debugDescription: String { description }\n    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }",
                                          with: "    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }") }),
            ("a second description in the sheet", Self.mutate(sources, Self.sheetFile) {
                $0 + "\nextension PairingCodeText: CustomStringConvertible {\n    nonisolated var description: String { \"x\" }\n}" }),
            // (c): the QR view named elsewhere.
            ("a second QR view", Self.mutate(sources, "MenuContentView.swift") { $0 + "\nlet zz = QRCodeView(payload: \"x\")" }),
            ("the QR's image drawn elsewhere", Self.mutate(sources, model) { $0 + "\nlet zz = QRCodeView.image(\"x\")" }),
            ("an aliased QR view", Self.mutate(sources, Self.sheetFile) { $0 + "\ntypealias ZZ = QRCodeView" }),
        ]
        // The C1.5 security review's R1: its RP1 (MN1 by another spelling: no
        // `Mirror` named) and its Optional-wrapper variant, as planted; the
        // banned words each alone; and each new redaction dropped or given
        // its parts.
        let rp1 = "\nextension MenuStateModel {\n    func zzSecRevReflectWrite(_ p: PairedPhone) -> Bool {\n"
            + "        guard let pairing, let item = [pairing].customMirror.descendant(0, \"keys\", \"items\") as? any TopicStore else { return false }\n"
            + "        return item.write(PairedKeyStore.text(of: p))\n    }\n}\n"
        let rp1Optional = "\nextension MenuStateModel {\n"
            + "    func zzA3() -> Any? { Optional(pairing).customMirror.descendant(\"some\", \"some\", \"keys\", \"items\") }\n}\n"
        let r1: [(String, Sources)] = [
            ("RP1: the slot written by customMirror.descendant", Self.mutate(sources, model) { $0 + rp1 }),
            ("RP1 through an Optional wrapper", Self.mutate(sources, model) { $0 + rp1Optional }),
            ("a mirror read, nothing walked", Self.mutate(sources, model) {
                $0 + "\nfunc zz(_ x: [PairingController]) -> Int { x.customMirror.children.count }" }),
            ("a field reader by a longer name", Self.mutate(sources, model) {
                $0 + "\nfunc zz<T>(_ t: T.Type) { _ = _forEachFieldWithKeyPath(of: t, options: .classType) { _, _ in true } }" }),
            ("the controller's redaction dropped", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: Self.controllerDeclaration, with: "final class PairingController: ObservableObject {") }),
            ("the controller's mirror given the slot", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "Mirror(self, children: [], displayStyle: .class)",
                                        with: "Mirror(self, children: [\"keys\": keys], displayStyle: .class)") }),
            ("the controller described by its state", Self.mutate(sources, Self.controllerFile) {
                $0.replacingOccurrences(of: "nonisolated var description: String { \"pairing (redacted)\" }",
                                        with: "nonisolated var description: String { \"pairing\" }") }),
            ("the slot's redaction dropped", Self.mutate(sources, Self.slotFile) {
                $0.replacingOccurrences(of: "extension PairedKeyStore" + Self.conformance,
                                        with: "extension PairedKeyStore: CustomStringConvertible, CustomDebugStringConvertible {")
                    .replacingOccurrences(of: "    var debugDescription: String { description }\n    " + Self.structMirror + "\n",
                                          with: "    var debugDescription: String { description }\n") }),
            ("the store's mirror given its calls", Self.mutate(sources, Self.storeFile) {
                $0.replacingOccurrences(of: Self.structMirror,
                                        with: "var customMirror: Mirror { Mirror(self, children: [\"calls\": calls], displayStyle: .struct) }") }),
            ("another type's mirror in another file", Self.mutate(sources, "LidGuardController.swift") {
                $0 + "\nextension LidGuardController: CustomReflectable {\n    var customMirror: Mirror { Mirror(self, children: []) }\n}" }),
        ]
        // The C1.5 security review's R5: its RP5 (the QR rendered off screen
        // by a second sheet view), as planted; the probe's second sheet view
        // in a hosting view; and each capture door alone.
        let rp5 = "\nextension MenuStateModel {\n    func zzSecRevRender() -> NSImage? {\n        guard let pairing else { return nil }\n"
            + "        return ImageRenderer(content: PairingSheetView(pairing: pairing)).nsImage\n    }\n}\n"
        let r5: [(String, Sources)] = [
            ("RP5: the sheet rendered off screen", Self.mutate(sources, model) { $0 + rp5 }),
            ("a second sheet view in a hosting view", Self.mutate(sources, model) {
                $0 + "\nextension MenuStateModel {\n    func zzC5() -> NSView? { pairing.map { NSHostingView(rootView: PairingSheetView(pairing: $0)) } }\n}\n" }),
            ("an unapplied sheet view", Self.mutate(sources, "SettingsWindowController.swift") { $0 + "\nlet zz = PairingSheetView.init" }),
            ("the window's view cached to a bitmap", Self.mutate(sources, "SettingsWindowController.swift") {
                $0 + "\nfunc zz(_ v: NSView) -> NSBitmapImageRep? {\n    guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }\n"
                    + "    v.cacheDisplay(in: v.bounds, to: r)\n    return r\n}" }),
            ("the window's view as a PDF", Self.mutate(sources, "SettingsWindowController.swift") {
                $0 + "\nfunc zz(_ v: NSView) -> Data { v.dataWithPDF(inside: v.bounds) }" }),
            ("the screen captured", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet zz = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, [])" }),
        ]
        for (name, mutant) in mutants + r1 + r5 {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.reflectionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Each R1/R5 word bites through the lock's own engine, alone.
        let captureProbes: [String] = ["ImageRenderer(content: v)", "v.cacheDisplay(in: r, to: b)", "v.bitmapImageRepForCachingDisplay(in: r)",
                                       "v.dataWithPDF(inside: r)", "v.dataWithEPS(inside: r)", "CGWindowListCreateImageFromArray(r, a, o)",
                                       "CGDisplayCreateImage(d)", "SCScreenshotManager.captureImage"]
        var probes: [(String, String)] = [(Self.reflectionPattern, "x.descendant(0)"), (Self.reflectionPattern, "_forEachFieldWithKeyPath(of: t)"),
                                          (#"\bcustomMirror\b"#, "[p].customMirror")]
        probes += zip(Self.offscreenCaptureTokens, captureProbes).map { ($0, $1) }
        #expect(probes.count == 3 + Self.offscreenCaptureTokens.count)
        for (pattern, probe) in probes {
            #expect(ApprovalRecordPathStructureTests.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
        // R1's canary that names neither `Mirror` nor `descendant` is caught
        // by the customMirror pin alone; R5's hosting view by the sheet
        // view's pin alone.
        #expect(Self.appSiteFailures(Self.reflectionPattern, in: r1[2].1, allowed: Self.mirrorSites, rule: "").isEmpty)
        #expect(!Self.appSiteFailures(#"\bcustomMirror\b"#, in: r1[2].1, allowed: Self.customMirrorSites, rule: "").isEmpty)
        #expect(Self.offscreenCaptureTokens.allSatisfy { Self.appSiteFailures($0, in: r5[1].1, allowed: [:], rule: "").isEmpty })
        #expect(!Self.appSiteFailures(#"\bPairingSheetView\b"#, in: r5[1].1, allowed: Self.sheetViewSites, rule: "").isEmpty)
        // Over-match controls: the stay-awake mirror's names (other words,
        // shipped today), words that only contain the banned ones, and a
        // whole-line comment naming the shapes.
        #expect(Self.text("NapCatApp.swift", in: sources).contains("stayAwakeMirror: sleepController.observedMirror"),
                "vacuity: the stay-awake mirror is in the scan")
        #expect(Self.reflectionFailures(Self.mutate(sources, model) {
            $0 + "\nlet zzObservedStayAwakeMirror = 1, stayAwakeMirror = 2, observedMirror = 3, Mirrors = 4, reflected = 5"
                + "\nlet zzQRCodeViews = 6, isQRCodeView = 7"
                // R1/R5: words that only contain the new ones.
                + "\nlet zzCustomMirrors = 8, customMirrorCount = 9, descendants = 10, isDescendant = 11, forEachFieldName = 12"
                + "\nlet zzPairingSheetViews = 13, imageRendererName = 14, cacheDisplayed = 15, dataWithPDFCount = 16"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never Mirror(reflecting:), never QRCodeView(payload:) here"
                    + "\n/// never [pairing].customMirror.descendant(0, \"keys\"), never _forEachFieldWithKeyPath"
                    + "\n/// never ImageRenderer(content: PairingSheetView(pairing: p)), never cacheDisplay(in:to:)")
        }).isEmpty)
    }

    /// The C1.5 security delta re-check's F-A, its canaries: G1b, verbatim
    /// (the runtime's field reader declared by `@_silgen_name`, the fields
    /// read by `T.self`), and the re-check's first spelling, by `type(of:)`
    /// (caught before by lock 6's dynamic-type rule alone, an unrelated
    /// one). Lock 7 catches each, and by the new ban alone: its other rules
    /// miss both, the gap the re-check found. Each word bites alone, and
    /// G1b's entry points match in every scan copy.
    @Test func nothingDeclaresARuntimeEntryPoint() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.runtimeEntryFailures(sources).isEmpty, "\(Self.runtimeEntryFailures(sources))")
        let model = "MenuStateModel.swift"
        // The two declarations both spellings open with, as planted.
        let entryPoints: [String] = [
            "\ntypealias ZZFree = @convention(c) (UnsafePointer<CChar>?) -> Void\n",
            "@_silgen_name(\"swift_reflectionMirror_count\") func zzN<T>(_: T, type: Any.Type) -> Int\n",
            "@_silgen_name(\"swift_reflectionMirror_subscript\") func zzC<T>(of: T, type: Any.Type, index: Int, ",
            "outName: UnsafeMutablePointer<UnsafePointer<CChar>?>, outFreeFunc: UnsafeMutablePointer<ZZFree?>) -> Any\n",
        ]
        let itemRead: String = "let item = zzField(keys, \"items\") as? any TopicStore else { return false }\n"
        let g1bGuard: String = "        guard let pairing, let keys = zzField(pairing, \"keys\") as? PairedKeyStore, " + itemRead
        let typeOfGuard: String = "        guard let pairing, let keys = zzField(pairing, \"keys\"), " + itemRead
        let g1bReader: [String] = [
            "func zzField<T>(_ v: T, _ label: String) -> Any? {\n    for i in 0..<zzN(v, type: T.self) {\n",
            "        var n: UnsafePointer<CChar>?\n        var f: ZZFree?\n",
            "        let c = zzC(of: v, type: T.self, index: i, outName: &n, outFreeFunc: &f)\n",
            "        let name = n.map { String(cString: $0) }\n        f?(n)\n        if name == label { return c }\n    }\n    return nil\n}\n",
            "extension MenuStateModel {\n    func zzSilgenWrite(_ p: PairedPhone) -> Bool {\n",
            g1bGuard,
            "        return item.write(PairedKeyStore.text(of: p))\n    }\n}\n",
        ]
        let typeOfReader: [String] = [
            "func zzField(_ v: Any, _ label: String) -> Any? {\n    for i in 0..<zzN(v, type: type(of: v)) {\n",
            "        var n: UnsafePointer<CChar>?\n        var f: ZZFree?\n",
            "        let c = zzC(of: v, type: type(of: v), index: i, outName: &n, outFreeFunc: &f)\n",
            "        let name = n.map { String(cString: $0) }\n        f?(n)\n        if name == label { return c }\n    }\n    return nil\n}\n",
            "extension MenuStateModel {\n    func zzSilgenWrite(_ p: PairedPhone) -> Bool {\n",
            typeOfGuard,
            "        return item.write(PairedKeyStore.text(of: p))\n    }\n}\n",
        ]
        let head: String = entryPoints.joined()
        let g1b: String = head + g1bReader.joined()
        let typeOf: String = head + typeOfReader.joined()
        let seamReader: String = "\n@_silgen_name(\"swift_reflectionMirror_count\") func zzN<T>(_: T, type: Any.Type) -> Int\n"
        let wireExtern: String = "\n@_extern(c, \"zz_reader\") func zzReader() -> Int\n"
        let mutants: [(String, Sources)] = [
            ("G1b: the slot written through the runtime's field reader, by T.self", Self.mutate(sources, model) { $0 + g1b }),
            ("G1b's first spelling, by type(of:)", Self.mutate(sources, model) { $0 + typeOf }),
            ("the reader declared in another target", Self.mutate(sources, ApprovalChannelStructureTests.seamFile) { $0 + seamReader }),
            ("an entry point by @_extern, in the wire", Self.mutate(sources, "AlertWire.swift") { $0 + wireExtern }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            let caught = Self.runtimeEntryFailures(mutant)
            #expect(!caught.isEmpty, "canary '\(name)' was NOT caught")
            // Within lock 7, the new ban alone: every other rule misses it.
            #expect(Self.reflectionFailures(mutant) == caught, "canary '\(name)': another lock 7 rule fired")
        }
        // Each word bites alone, through the lock's own engine (and only
        // its own probe).
        let probes: [String] = ["@_silgen_name(\"zz\") func zz()", "@_extern(c, \"zz\") func zz()",
                                "let zz = \"swift_reflectionMirror_subscript\""]
        #expect(probes.count == Self.runtimeEntryTokens.count)
        for (i, token) in Self.runtimeEntryTokens.enumerated() {
            for (j, probe) in probes.enumerated() {
                #expect(ApprovalRecordPathStructureTests.hits(token, in: probe) == (i == j), "'\(token)' against '\(probe)'")
            }
        }
        // G1b's two entry points, in every scan copy of its exact text.
        let copies: [String] = [g1b, g1b.replacingOccurrences(of: "`", with: ""), LidGuardStructureTests.cleaned(g1b)]
        let attributes: [String] = ["_silgen_name", "_silgen_name"]
        let names: [String] = ["swift_reflectionMirror_count", "swift_reflectionMirror_subscript"]
        for copy in copies {
            #expect(ApprovalRecordPathStructureTests.matches(Self.runtimeEntryTokens[0], in: copy) == attributes)
            #expect(ApprovalRecordPathStructureTests.matches(Self.runtimeEntryTokens[2], in: copy) == names)
        }
        // Over-match controls: words that only contain the banned ones.
        let near: String = "\nlet zzSilgenName = 1, silgen_name = 2, _external = 3, extern = 4, swift_reflection = 5, reflectionMirror = 6"
        #expect(Self.reflectionFailures(Self.mutate(sources, model) { $0 + near }).isEmpty)
    }

    // MARK: - 8. Unpair: after the owner's confirmation, or as Try Again (#240)

    /// The slot's deletion is reached by the controller's Unpair alone, and
    /// that by the owner's confirmed alert and by Try Again alone; Try Again
    /// is the Settings button's, through the model, and runs Unpair only
    /// while a refusal stands (so a late click never unpairs a phone paired
    /// since). Every Unpair runs the kill switch, whatever the deletion came
    /// to, and remembers a refusal; the refusal is set there alone and
    /// cleared by a deletion that goes through or a key written.
    ///
    /// Every `unpair` is pinned as a whole word, so a reference taken
    /// unapplied (`let go = p.unpair`, then `go()`) is off the list as well
    /// as a call; the word's other lines are the alert's Unpair button, a
    /// local of that name. Every mention of the refusal flag is pinned too,
    /// so no write escapes however it is spelled (`=`, `.toggle()`,
    /// `&unpairFailed`, `self.`, a key path): in every file, each one not
    /// behind a dot (the audit's and the pane's cases are declared bare),
    /// and in the controller, which keeps the flag private, each one behind
    /// a dot as well (those two cases, used). The model's Try Again is
    /// pinned whole, so its call cannot move into `refresh()`.
    static let unpairSites: [String: [String: Int]] = [
        slotFile: ["func unpair() -> Bool {": 1],
        controllerFile: ["func unpair() {": 1, "let gone = keys.unpair()": 1, "unpair()": 1],
        "MenuContentView.swift": ["pairing?.unpair()": 1,
                                  "let unpair = alert.addButton(withTitle: MenuStateModel.unpairAlertConfirm)": 1,
                                  "unpair.hasDestructiveAction = true": 1, "unpair.keyEquivalent = \"\"": 1],
        "MenuStateModel.swift": ["func unpair() { requestUnpair?() }": 1],
        "SettingsPanes.swift": ["Button(MenuStateModel.unpairButtonTitle) { model.unpair() }": 1],
    ]
    static let retrySites: [String: [String: Int]] = [
        controllerFile: ["func retryUnpair() {": 1],
        "MenuStateModel.swift": ["func retryUnpair() {": 1, "pairing?.retryUnpair()": 1],
        "SettingsPanes.swift": ["Button(MenuStateModel.unpairRetryButtonTitle) { model.retryUnpair() }": 1],
    ]
    /// Every mention of `unpairFailed` not behind a dot: the audit's case,
    /// the pane's case, and the flag's declaration, reads and writes.
    static let refusalSites: [String: [String: Int]] = [
        ceremonyFile: ["case unpairFailed": 1],
        controllerFile: ["case unpairFailed": 1, "private var unpairFailed = false": 1,
                         "if unpairFailed { return .unpairFailed }": 1,
                         "let rotating = if case .paired = paired, !unpairFailed { true } else { false }": 1,
                         "let before = (read: paired, failed: unpairFailed)": 1, "unpairFailed = !gone": 1,
                         "if paired != before.read || unpairFailed != before.failed { onPaneChange?() }": 1,
                         "guard unpairFailed else { return }": 1,
                         "if case .paired = state.phase { unpairFailed = false }": 1],
    ]
    /// Every mention of `unpairFailed` behind a dot in the controller: the
    /// pane's case and the audit's, nothing through `self` or a key path.
    static let refusalMemberSites: [String: [String: Int]] = [
        controllerFile: ["if unpairFailed { return .unpairFailed }": 1, "audit(gone ? .unpaired : .unpairFailed)": 1],
    ]
    static let unpairBody = "func unpair() { let gone = keys.unpair() killSwitch() audit(gone ? .unpaired : .unpairFailed)"
        + " let before = (read: paired, failed: unpairFailed) unpairFailed = !gone paired = keys.read()"
        + " if paired != before.read || unpairFailed != before.failed { onPaneChange?() } }"
    static let retryBody = "func retryUnpair() { guard unpairFailed else { return } unpair() }"
    static let modelRetryBody = "func retryUnpair() { pairing?.retryUnpair() refresh() }"

    static func unpairFailures(_ sources: Sources) -> [String] {
        let controller = text(controllerFile, in: sources)
        guard controller.contains("final class PairingController") else { return ["the controller is missing — the Unpair lock would be vacuous"] }
        let model = text("MenuStateModel.swift", in: sources)
        guard model.contains("final class MenuStateModel") else { return ["the model is missing — the Unpair lock would be vacuous"] }
        var failures = appSiteFailures(#"\bunpair\b"#, in: sources, allowed: unpairSites,
                                       rule: "the slot is deleted by Unpair alone, run by the confirmed alert and Try Again alone")
        failures += appSiteFailures(#"\bretryUnpair\b"#, in: sources, allowed: retrySites,
                                    rule: "Try Again is the Settings button's, through the model, to the controller")
        failures += appSiteFailures(#"(?<!\.)\bunpairFailed\b"#, in: sources, allowed: refusalSites,
                                    rule: "a refusal is set by Unpair alone, and cleared by its deletion or a key written")
        failures += appSiteFailures(#"\.\s*unpairFailed\b"#, in: sources.filter { $0.name == controllerFile },
                                    allowed: refusalMemberSites,
                                    rule: "the controller names the refusal behind a dot as the pane's and the audit's cases alone")
        for (body, file, what) in [
            (unpairBody, controller, "every Unpair runs the kill switch and remembers a refusal — exactly as pinned"),
            (retryBody, controller, "Try Again runs Unpair only while a refusal stands — exactly as pinned"),
            (modelRetryBody, model, "the model's Try Again calls the controller's, then refreshes — exactly as pinned"),
        ] where ApprovalChannelStructureTests.count(body, in: MenuPanelStructureTests.flat(file)) != 1 {
            failures.append(what)
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    @Test func unpairRunsAfterTheConfirmationOrAsTryAgain() throws {
        let sources = try ApprovalChannelStructureTests.sources()
        #expect(Self.unpairFailures(sources).isEmpty, "\(Self.unpairFailures(sources))")
        let controller = Self.controllerFile
        let model = "MenuStateModel.swift"
        let readLine = "        let read = keys.read()\n"
        let retryCall = "        pairing?.retryUnpair()\n"
        let refreshHead = "    func refresh() {\n"
        let movedRetry = Self.mutate(sources, model) {
            $0.replacingOccurrences(of: retryCall + "        refresh()\n", with: "        refresh()\n")
                .replacingOccurrences(of: refreshHead, with: refreshHead + retryCall)
        }
        let mutants: [(String, Sources)] = [
            ("Try Again without its guard", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "        guard unpairFailed else { return }\n", with: "") }),
            ("Try Again straight to Unpair from the model", Self.mutate(sources, model) {
                $0.replacingOccurrences(of: "pairing?.retryUnpair()", with: "pairing?.unpair()") }),
            ("Unpair with no alert, from the model", Self.mutate(sources, model) { $0 + "\nfunc zz(_ p: PairingController?) { p?.unpair() }" }),
            ("the slot deleted from the model", Self.mutate(sources, model) { $0 + "\nfunc zz(_ k: PairedKeyStore) -> Bool { k.unpair() }" }),
            ("a backticked Unpair", Self.mutate(sources, "MenuContentView.swift") { $0 + "\nfunc zz(_ p: PairingController) { p.`unpair`() }" }),
            ("Try Again from the panel", Self.mutate(sources, "MenuPanelView.swift") {
                $0 + "\nstruct ZZ: View { let model: MenuStateModel; var body: some View { Button(\"x\") { model.retryUnpair() } } }" }),
            ("the kill switch only after a deletion", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "        killSwitch()\n        audit(gone", with: "        if gone { killSwitch() }\n        audit(gone") }),
            ("the refusal forgotten at a read", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "        let read = keys.read()\n", with: "        let read = keys.read()\n        unpairFailed = false\n") }),
            ("the refusal kept from a read that failed", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: "unpairFailed = !gone", with: "unpairFailed = !gone && keys.read() != .unreadable") }),
            // Unapplied: no call to count, so only the whole word sees them.
            ("an unapplied Unpair", Self.mutate(sources, model) {
                $0 + "\nfunc zz(_ p: PairingController) {\n    let go = p.unpair\n    go()\n}" }),
            ("the slot's deletion taken unapplied", Self.mutate(sources, controller) {
                $0 + "\nfunc zz(_ k: PairedKeyStore) -> Bool {\n    let del = k.unpair\n    return del()\n}" }),
            // The refusal written however it is spelled, and its name in
            // another file.
            ("the refusal toggled off at a read", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: readLine, with: readLine + "        if unpairFailed { unpairFailed.toggle() }\n") }),
            ("the refusal cleared through inout", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: readLine, with: readLine + "        zzClear(&unpairFailed)\n") }),
            ("the refusal cleared through self", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: readLine, with: readLine + "        self.unpairFailed = false\n") }),
            ("the refusal cleared by key path", Self.mutate(sources, controller) {
                $0.replacingOccurrences(of: readLine, with: readLine + "        self[keyPath: \\.unpairFailed] = false\n") }),
            ("a flag of that name in another file", Self.mutate(sources, model) {
                $0 + "\nfunc zz(_ unpairFailed: inout Bool) { unpairFailed.toggle() }" }),
            ("the model's Try Again call moved into refresh", movedRetry),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.unpairFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Vacuity: the read the refusal canaries plant after, and the move
        // itself (the call gone from Try Again, now first in refresh, its
        // sites unchanged — only the pinned body sees it).
        #expect(ApprovalChannelStructureTests.count(readLine, in: Self.text(controller, in: sources)) == 1)
        let moved = Self.text(model, in: movedRetry)
        #expect(!moved.contains(retryCall + "        refresh()\n") && moved.contains(refreshHead + retryCall))
        #expect(Self.appSiteFailures(#"\bretryUnpair\b"#, in: movedRetry, allowed: Self.retrySites, rule: "").isEmpty)
        // Over-match controls: words that only contain the pinned ones, the
        // audit's and the pane's own `.unpairFailed`, a comparison, and a
        // whole-line comment naming the shapes.
        #expect(Self.unpairFailures(Self.mutate(sources, model) {
            $0 + "\nlet zzUnpaired = 1, unpairCount = 2, retryUnpairs = 3, isUnpairFailed = 4, zz = MenuStateModel.unpairAlertConfirm"
                + "\nfunc zz(_ p: PairingPaneState) -> Bool { p == .unpairFailed }"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never pairing?.unpair() here, never unpairFailed = false")
        }).isEmpty)
    }
}
