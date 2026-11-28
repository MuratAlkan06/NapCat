// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

// MARK: - Test doubles (shared with the lid-guard and persistence tests)

/// In-memory `TopicStore`: what every lid-guard and migration test uses
/// instead of the keychain. Faithful to `KeychainTopicStore`'s contract (the
/// same contract test runs against both, below); failures and odd read
/// answers can be injected, and every call is counted.
final class FakeTopicStore: TopicStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var reads = 0
    private var writes = 0
    private var deletes = 0
    private var failWrites = false
    private var failDeletes = false
    private var readAnswerOverride: TopicStoreRead?
    private var observer: ((String) -> Void)?

    init(_ value: String? = nil) { self.value = value }

    var storedValue: String? { locked { value } }
    var readCount: Int { locked { reads } }
    var writeCount: Int { locked { writes } }
    var deleteCount: Int { locked { deletes } }

    /// Changes the stored value behind the app's back (another process, a
    /// hand edit in Keychain Access) — nothing is counted.
    func replaceValue(_ newValue: String?) { locked { value = newValue } }
    func setFailWrites(_ fail: Bool) { locked { failWrites = fail } }
    func setFailDeletes(_ fail: Bool) { locked { failDeletes = fail } }
    /// Every later read answers this instead of the stored value (nil: stop).
    func setReadAnswer(_ answer: TopicStoreRead?) { locked { readAnswerOverride = answer } }
    /// Called with "read" / "write" / "delete" at the start of each call, on
    /// the caller's thread (the migration tests run on one thread).
    func setObserver(_ handler: ((String) -> Void)?) { locked { observer = handler } }

    func read() -> TopicStoreRead {
        notify("read")
        return locked {
            reads += 1
            if let readAnswerOverride { return readAnswerOverride }
            return value.map(TopicStoreRead.found) ?? .notFound
        }
    }

    func write(_ topic: String) -> Bool {
        notify("write")
        return locked {
            writes += 1
            guard !failWrites else { return false }
            value = topic
            return true
        }
    }

    func delete() -> Bool {
        notify("delete")
        return locked {
            deletes += 1
            guard !failDeletes else { return false }
            value = nil
            return true
        }
    }

    private func notify(_ operation: String) {
        let handler = locked { observer }
        handler?(operation)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A fake keychain behind `KeychainItemCalls`: one in-memory item, every
/// query recorded, any call's status overridable. It lets the REAL store's
/// logic run end to end without the real keychain ever being touched.
final class RecordingKeychainCalls: @unchecked Sendable {
    struct Call {
        let name: String
        let query: [String: Any]
        let changes: [String: Any]?
    }

    private let lock = NSLock()
    private var item: Data?
    private var log: [Call] = []
    private var statusOverride: [String: OSStatus] = [:]
    private var copyDataOverride: Data??

    init(item: Data? = nil) { self.item = item }

    var calls: [Call] { locked { log } }
    var storedData: Data? { locked { item } }

    /// Make every later `name` call ("copyData" / "add" / "update" /
    /// "delete") answer `status` without touching the item.
    func fail(_ name: String, with status: OSStatus) { locked { statusOverride[name] = status } }
    /// Make a successful `copyData` hand back these bytes instead of the item.
    func answerCopyData(with data: Data?) { locked { copyDataOverride = .some(data) } }

    var api: KeychainItemCalls {
        KeychainItemCalls(
            copyData: { query in
                self.locked {
                    self.log.append(Call(name: "copyData", query: query, changes: nil))
                    if let status = self.statusOverride["copyData"] { return (status, nil) }
                    if let override = self.copyDataOverride { return (errSecSuccess, override) }
                    guard let item = self.item else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, item)
                }
            },
            add: { attributes in
                self.locked {
                    self.log.append(Call(name: "add", query: attributes, changes: nil))
                    if let status = self.statusOverride["add"] { return status }
                    guard self.item == nil else { return errSecDuplicateItem }
                    self.item = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            update: { query, changes in
                self.locked {
                    self.log.append(Call(name: "update", query: query, changes: changes))
                    if let status = self.statusOverride["update"] { return status }
                    guard self.item != nil else { return errSecItemNotFound }
                    self.item = changes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { query in
                self.locked {
                    self.log.append(Call(name: "delete", query: query, changes: nil))
                    if let status = self.statusOverride["delete"] { return status }
                    guard self.item != nil else { return errSecItemNotFound }
                    self.item = nil
                    return errSecSuccess
                }
            }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Tests

/// Issue #103 (audit F-2): the ntfy topic's keychain seam. The REAL store's
/// logic runs against `RecordingKeychainCalls` (never the keychain itself);
/// the lid guard and the migration are tested against `FakeTopicStore`. The
/// structure lints at the bottom keep it that way: `KeychainTopicStore.swift`
/// is the only file naming the Security item calls, and no test can reach
/// them.
struct KeychainTopicStoreTests {
    private func makeStore(_ fake: RecordingKeychainCalls) -> KeychainTopicStore {
        KeychainTopicStore(item: .ntfyTopic, calls: fake.api)
    }

    // MARK: Item identity and attributes

    /// The item's name is locked: a silent rename would orphan every stored
    /// topic, and uninstall.sh deletes the item by these two strings.
    @Test func theItemNameIsLocked() {
        #expect(KeychainItemName.ntfyTopic == KeychainItemName(service: "com.muratalkan.napcat", account: "ntfy-topic"))
        #expect(KeychainTopicStore.itemLabel == "NapCat ntfy topic")
    }

    /// Exactly one generic-password item, addressed by service + account;
    /// created AfterFirstUnlock with a label; never synchronizable, so it
    /// cannot leave this Mac through iCloud Keychain.
    @Test func theQueriesAddressOneNonSynchronizableGenericPasswordItem() {
        let store = makeStore(RecordingKeychainCalls())
        let base = store.baseQuery
        #expect(base.count == 3)
        #expect(base[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(base[kSecAttrService as String] as? String == "com.muratalkan.napcat")
        #expect(base[kSecAttrAccount as String] as? String == "ntfy-topic")

        let read = store.readQuery
        #expect(read.count == 5)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)

        let add = store.addAttributes(Data("napcat-x".utf8))
        #expect(add.count == 6)
        #expect(add[kSecValueData as String] as? Data == Data("napcat-x".utf8))
        #expect(add[kSecAttrLabel as String] as? String == KeychainTopicStore.itemLabel)
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)

        for query in [base, read, add] {
            #expect(query[kSecAttrSynchronizable as String] == nil, "the item must never sync")
            #expect(query[kSecUseDataProtectionKeychain as String] == nil, "ad-hoc builds have no keychain entitlement")
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
    }

    // MARK: The real store's logic, against a recording fake

    /// Upsert: the first write finds no item and creates it; the next one
    /// replaces the data in place (keeping the item's access list). Reads
    /// return the bytes, byte for byte.
    @Test func writeCreatesTheItemOnceThenUpdatesItInPlace() {
        let fake = RecordingKeychainCalls()
        let store = makeStore(fake)
        #expect(store.read() == .notFound)

        #expect(store.write("napcat-first-7q2m9x"))
        #expect(fake.calls.map(\.name) == ["copyData", "update", "add"])
        #expect(store.read() == .found("napcat-first-7q2m9x"))

        let longest = String(repeating: "Az9_-", count: 12) + "Az9_"   // 64 characters
        #expect(store.write(longest))
        #expect(fake.calls.map(\.name) == ["copyData", "update", "add", "copyData", "update"],
                "an existing item is updated, never re-added")
        #expect(store.read() == .found(longest))
        #expect(fake.storedData == Data(longest.utf8))

        let update = fake.calls[4]
        #expect(update.changes?.count == 1, "an update changes the data and nothing else")
        #expect(update.changes?[kSecValueData as String] as? Data == Data(longest.utf8))
        #expect(update.query.count == 3, "updates match on the item's identity alone")
    }

    @Test func aRefusedWriteReportsFailureAndAddsNothing() {
        let refusedUpdate = RecordingKeychainCalls(item: Data("napcat-old".utf8))
        refusedUpdate.fail("update", with: errSecAuthFailed)
        #expect(!makeStore(refusedUpdate).write("napcat-new"))
        #expect(refusedUpdate.calls.map(\.name) == ["update"], "only a missing item falls through to add")
        #expect(refusedUpdate.storedData == Data("napcat-old".utf8))

        let refusedAdd = RecordingKeychainCalls()
        refusedAdd.fail("add", with: errSecNotAvailable)
        #expect(!makeStore(refusedAdd).write("napcat-new"))
        #expect(refusedAdd.calls.map(\.name) == ["update", "add"])
        #expect(refusedAdd.storedData == nil)
    }

    /// Read mapping: success with UTF-8 bytes is the value; a missing item is
    /// `.notFound`; any other status, or bytes that are not text, is
    /// `.failed` with a status — never a value the caller could mistake for
    /// the topic.
    @Test func readMapsEveryKeychainAnswer() {
        let fake = RecordingKeychainCalls(item: Data("napcat-lid-8f3k2p".utf8))
        let store = makeStore(fake)
        #expect(store.read() == .found("napcat-lid-8f3k2p"))

        fake.answerCopyData(with: Data([0xFF, 0xFE, 0xFD]))
        #expect(store.read() == .failed(status: errSecDecode), "non-UTF-8 bytes are not a topic")
        fake.answerCopyData(with: nil)
        #expect(store.read() == .failed(status: errSecDecode), "success without data is not a topic")

        fake.fail("copyData", with: errSecUserCanceled)   // "Deny" on the Allow dialog
        #expect(store.read() == .failed(status: errSecUserCanceled))
        fake.fail("copyData", with: errSecInteractionNotAllowed)
        #expect(store.read() == .failed(status: errSecInteractionNotAllowed))
        fake.fail("copyData", with: errSecItemNotFound)
        #expect(store.read() == .notFound)
    }

    @Test func deleteTreatsAMissingItemAsGone() {
        let fake = RecordingKeychainCalls(item: Data("napcat-x".utf8))
        let store = makeStore(fake)
        #expect(store.delete())
        #expect(fake.storedData == nil)
        #expect(store.delete(), "deleting what is not there is success")
        #expect(fake.calls.map(\.name) == ["delete", "delete"])
        #expect(fake.calls.allSatisfy { $0.query.count == 3 }, "delete matches on the item's identity alone")

        fake.fail("delete", with: errSecAuthFailed)
        #expect(!store.delete())
    }

    /// One contract, two conformers: the real store over the recording fake
    /// and the in-memory `FakeTopicStore` the lid-guard tests use must answer
    /// the same sequence identically — so a test passing against the fake
    /// says something about the app.
    @Test func theFakeStoreHonoursTheRealStoresContract() {
        let stores: [(name: String, store: TopicStore)] = [
            ("KeychainTopicStore", makeStore(RecordingKeychainCalls())),
            ("FakeTopicStore", FakeTopicStore()),
        ]
        for (name, store) in stores {
            #expect(store.read() == .notFound, "\(name): starts empty")
            #expect(store.delete(), "\(name): deleting nothing succeeds")
            #expect(store.write("napcat-a"), "\(name)")
            #expect(store.read() == .found("napcat-a"), "\(name)")
            #expect(store.write("napcat-b"), "\(name): a second write replaces")
            #expect(store.read() == .found("napcat-b"), "\(name)")
            #expect(store.write(""), "\(name): an empty value is still a value")
            #expect(store.read() == .found(""), "\(name)")
            #expect(store.delete(), "\(name)")
            #expect(store.read() == .notFound, "\(name): gone after delete")
        }
    }

    /// S-PAIR-C1.5, the C1.5 security review's R1: the store holds the real
    /// keychain calls, and no reflection — its own mirror, or a wrapper's
    /// `customMirror.descendant` — reaches them or its item's name; it
    /// prints, debug-prints and dumps as a fixed word. A control: a plain
    /// holder of the same calls is reached the same way. (`Mirror` routes
    /// only: the runtimes' own readers ignore the redaction —
    /// `PairingStructureTests.nothingDeclaresARuntimeEntryPoint` and
    /// `nothingCallsTheObjCRuntimeOrLooksUpByName` stop them; raw-pointer
    /// reads remain the accepted R-1 residual.)
    @Test func theStoreReflectsAndPrintsNothing() {
        let fake = RecordingKeychainCalls()
        let store = KeychainTopicStore(item: .pairedPhone, calls: fake.api)
        #expect(Mirror(reflecting: store).children.isEmpty)
        let routes: [(String, Any?)] = [("its mirror", Mirror(reflecting: store).descendant("calls")),
                                        ("an array's", [store].customMirror.descendant(0, "calls")),
                                        ("an optional's", Optional(store).customMirror.descendant("some", "item"))]
        for (name, reached) in routes {
            #expect(reached == nil, "\(name) reached a part of the store")
        }
        var dumped = ""
        dump(store, to: &dumped)
        for text in [String(describing: store), String(reflecting: store), "\(store)", dumped] {
            #expect(text.contains("keychain item (redacted)") && !text.contains(KeychainItemName.pairedPhone.account)
                    && !text.contains("calls"), "\(text)")
        }
        struct Unredacted { let calls: KeychainItemCalls }
        #expect(Mirror(reflecting: Unredacted(calls: fake.api)).descendant("calls") is KeychainItemCalls,
                "vacuity: the route reaches an unredacted holder's calls")
        #expect(fake.calls.isEmpty, "nothing reached the keychain")
    }

    // MARK: - uninstall.sh deletes the item, value-silently

    private static func uninstallScript() throws -> String {
        try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent("scripts/uninstall.sh"),
                   encoding: .utf8)
    }

    /// The item-name literals in uninstall.sh must be the app's own
    /// (`KeychainItemName.ntfyTopic`, and since S-PAIR-C1.5 `.pairedPhone`)
    /// — the hookVersion-style parity lock.
    static let parityVariables = [("KEYCHAIN_SERVICE", KeychainItemName.ntfyTopic.service),
                                  ("KEYCHAIN_ACCOUNT", KeychainItemName.ntfyTopic.account),
                                  ("PAIRED_KEY_SERVICE", KeychainItemName.pairedPhone.service),
                                  ("PAIRED_KEY_ACCOUNT", KeychainItemName.pairedPhone.account)]

    static func keychainParityFailures(_ script: String) -> [String] {
        let lines = script.split(separator: "\n").map(String.init)
        var failures: [String] = []
        for (variable, value) in parityVariables {
            let definitions = lines.filter { $0.hasPrefix(variable + "=") }
            if definitions != ["\(variable)=\"\(value)\""] {
                failures.append("uninstall.sh must define \(variable)=\"\(value)\" exactly once, found \(definitions)")
            }
        }
        return failures
    }

    /// One keychain step of uninstall.sh: its exact call (the delete form
    /// only, all output discarded), the variable holding its exit status, and
    /// its outcome's exact lines.
    struct KeychainStep {
        let item: String
        let call: String
        let status: String
        let removed: String
        let reverted: String
        let nothing: String
        let failure: String
    }

    static let keychainDeleteCall = #"/usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1"#
    static let keychainDeleteUser = #"/bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \"#
    static let topicStep = KeychainStep(
        item: "the ntfy topic", call: keychainDeleteCall, status: "KEYCHAIN_STATUS",
        removed: #"echo "removed: the ntfy topic from the login keychain""#,
        reverted: #"REVERTED+=("ntfy topic removed from the login keychain")"#,
        nothing: #"echo "ok: no NapCat ntfy topic in the keychain — nothing to remove""#,
        failure: "FAILURES+=(\"could not remove the ntfy topic from the keychain")
    /// S-PAIR-C1.5 (#170): the paired iPhone's public key, step 8.
    static let pairedStep = KeychainStep(
        item: "the paired iPhone key",
        call: #"/usr/bin/security delete-generic-password -s "$PAIRED_KEY_SERVICE" -a "$PAIRED_KEY_ACCOUNT" >/dev/null 2>&1"#,
        status: "PAIRED_KEY_STATUS",
        removed: #"echo "removed: the paired iPhone key from the login keychain""#,
        reverted: #"REVERTED+=("paired iPhone key removed from the login keychain")"#,
        nothing: #"echo "ok: no NapCat paired iPhone key in the keychain — nothing to remove""#,
        failure: "FAILURES+=(\"could not remove the paired iPhone key from the keychain")

    /// Every value-silence / user-context violation of the keychain steps in
    /// an uninstall.sh text; empty == locked. AMENDED (S-PAIR-C1.5, #170):
    /// two steps — the topic's, then the paired key's — each its own exact
    /// call, as the user, value-silent, with its own outcome.
    static func keychainDeleteFailures(_ script: String) -> [String] {
        let code = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var failures: [String] = []
        let calls = code.indices.filter { code[$0].contains("security ") }
        let steps = [topicStep, pairedStep]
        guard calls.count == steps.count else {
            return ["uninstall.sh must invoke `security` exactly \(steps.count) times (the two item deletes), found \(calls.count)"]
        }
        for (call, step) in zip(calls, steps) {
            if code[call] != step.call {
                failures.append("\(step.item)'s keychain step must be exactly '\(step.call)', got '\(code[call])'")
            }
            if call == 0 || code[call - 1] != keychainDeleteUser {
                failures.append("\(step.item)'s keychain step must run as the user: '\(keychainDeleteUser)' on the line before")
            }
            for token in [" -g", " -w", "find-", "dump-keychain", "export"] where code[call].contains(token) {
                failures.append("'\(token)' in \(step.item)'s keychain step could print the item")
            }
            // Outcome: 0 is reported, 44 (errSecItemNotFound) is nothing to
            // do, anything else is a collected failure — and no line prints a
            // value.
            let tail = code[(call + 1)...].prefix(12)
            let expected = ["\(step.status)=$?", "case \"$\(step.status)\" in", "0)", step.removed, step.reverted, ";;", "44)",
                            step.nothing, ";;", "*)"]
            if Array(tail.prefix(expected.count)) != expected {
                failures.append("\(step.item)'s keychain step's outcome must be: 0 reported, 44 nothing to do, else a failure")
            }
            if !tail.contains(where: { $0.hasPrefix(step.failure) }) {
                failures.append("any other exit of \(step.item)'s keychain step must be a collected failure")
            }
        }
        // Inside the invoking-user block, after the defaults step, the topic's first.
        if let defaultsDelete = code.firstIndex(where: { $0.contains(#"/usr/bin/defaults delete "$DEFAULTS_DOMAIN""#) }),
           defaultsDelete > calls[0] {
            failures.append("the keychain steps must follow the defaults step")
        }
        return failures
    }

    @Test func theUninstallerDeletesTheSameItemValueSilently() throws {
        let script = try Self.uninstallScript()
        #expect(Self.keychainParityFailures(script).isEmpty, "\(Self.keychainParityFailures(script))")
        #expect(Self.keychainDeleteFailures(script).isEmpty, "\(Self.keychainDeleteFailures(script))")
    }

    /// Canary: a drifted name, a printing flag, a find- form, kept output, a
    /// root-context run, or "not found" counted as a failure must each trip —
    /// for either item (S-PAIR-C1.5: the paired key's step too, and its loss).
    @Test func theUninstallerKeychainLockCatchesMutants() throws {
        let script = try Self.uninstallScript()
        try #require(Self.keychainParityFailures(script).isEmpty && Self.keychainDeleteFailures(script).isEmpty,
                     "canary baseline must be clean")
        let parityMutants: [(String, String, String)] = [
            ("service drifted", #"KEYCHAIN_SERVICE="com.muratalkan.napcat""#, #"KEYCHAIN_SERVICE="com.muratalkan.NapCat""#),
            ("account drifted", #"KEYCHAIN_ACCOUNT="ntfy-topic""#, #"KEYCHAIN_ACCOUNT="ntfyTopic""#),
            ("the paired key's service drifted", #"PAIRED_KEY_SERVICE="com.muratalkan.napcat""#, #"PAIRED_KEY_SERVICE="com.napcat""#),
            ("the paired key's account drifted", #"PAIRED_KEY_ACCOUNT="paired-iphone-key""#, #"PAIRED_KEY_ACCOUNT="paired-phone-key""#),
            ("the paired key's account defined twice", #"PAIRED_KEY_ACCOUNT="paired-iphone-key""#,
             "PAIRED_KEY_ACCOUNT=\"paired-iphone-key\"\nPAIRED_KEY_ACCOUNT=\"ntfy-topic\""),
        ]
        for (name, target, replacement) in parityMutants {
            let mutant = script.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != script, "canary setup '\(name)'")
            #expect(!Self.keychainParityFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        let call = "delete-generic-password -s \"$KEYCHAIN_SERVICE\" -a \"$KEYCHAIN_ACCOUNT\" >/dev/null 2>&1"
        let pairedCall = "delete-generic-password -s \"$PAIRED_KEY_SERVICE\" -a \"$PAIRED_KEY_ACCOUNT\" >/dev/null 2>&1"
        let pairedOpen = "    /bin/launchctl asuser \"$TARGET_UID\" /usr/bin/sudo -u \"$TARGET_USER\" \\\n        /usr/bin/security " + pairedCall + "\n"
        let deleteMutants: [(String, String, String)] = [
            ("password printed (-g)", call, call.replacingOccurrences(of: " -a", with: " -g -a")),
            ("find- form", "delete-generic-password -s", "find-generic-password -w -s"),
            ("stdout kept", " >/dev/null 2>&1\n    KEYCHAIN_STATUS", " 2>/dev/null\n    KEYCHAIN_STATUS"),
            ("run as root", #"/bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \"# + "\n        /usr/bin/security",
             "/usr/bin/security"),
            ("not found counted as a failure", "        44)\n", "        4)\n"),
            ("second security call", "    KEYCHAIN_STATUS=$?\n",
             "    KEYCHAIN_STATUS=$?\n    /usr/bin/security find-generic-password -s x\n"),
            // S-PAIR-C1.5 (#170): the paired key's step alone.
            ("the paired key's step dropped", pairedOpen, ""),
            ("the paired key printed (-w)", pairedCall, pairedCall.replacingOccurrences(of: " -a", with: " -w -a")),
            ("the paired key's output kept", " >/dev/null 2>&1\n    PAIRED_KEY_STATUS", "\n    PAIRED_KEY_STATUS"),
            ("the paired key deleted as root", pairedOpen, "    /usr/bin/security " + pairedCall + "\n"),
            ("the paired key's not-found a failure", "case \"$PAIRED_KEY_STATUS\" in\n        0)",
             "case \"$PAIRED_KEY_STATUS\" in\n        44) FAILURES+=(\"x\") ;;\n        0)"),
            ("the paired key's failure not collected", "FAILURES+=(\"could not remove the paired iPhone key from the keychain",
             "echo \"could not remove the paired iPhone key from the keychain"),
        ]
        for (name, target, replacement) in deleteMutants {
            let mutant = script.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != script, "canary setup '\(name)'")
            #expect(!Self.keychainDeleteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Structure lints

    /// The Security item calls, spelled so this file does not contain them.
    static let itemCallTokens = ["Add", "Update", "CopyMatching", "Delete"].map { "Sec" + "Item" + $0 }

    /// Any identifier STARTING with the item-call prefix — the four calls
    /// and their relatives. Word-anchored, so the `errSecItem…` status constants a fake
    /// legitimately answers with do not count.
    static let itemCallPattern = "(?<![A-Za-z0-9_])" + "Sec" + "Item" + "[A-Za-z0-9_]*"

    static func itemCallNames(in text: String) -> [String] {
        var names: [String] = []
        var cursor = text.startIndex
        while let range = text.range(of: itemCallPattern, options: .regularExpression, range: cursor..<text.endIndex) {
            names.append(String(text[range]))
            cursor = range.upperBound
        }
        return names
    }

    /// Every test source as (name, text) — this file included.
    static func testSources() throws -> [(name: String, text: String)] {
        let dir = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// What would let a test reach the real keychain: a Security item call,
    /// the binding to the real calls, or the app's real store. Raw text,
    /// comments included — a test file has no reason to name any of them.
    /// S-PAIR-C1 (#168): and the real paired-key item.
    static let bindingTokens = ["security" + "Framework", "login" + "Keychain", "pairedPhone" + "Keychain"]

    static func testFileViolations(_ sources: [(name: String, text: String)]) -> [String] {
        sources.flatMap { file in
            itemCallNames(in: file.text).map { "\(file.name) names '\($0)'" }
                + bindingTokens.filter { file.text.contains($0) }.map { "\(file.name) names '\($0)'" }
        }
    }

    static let storeFile = "KeychainTopicStore.swift"

    /// Each item call's one line in the store: the binding to the real
    /// calls (spelled split, as above; one `let` each, so no literal mixes
    /// concatenations for the type-checker).
    static let itemCallBindings: [String: String] = {
        let prefix: String = "Sec" + "Item"
        let copyMatching: String = prefix + "CopyMatching"
        let add: String = prefix + "Add"
        let update: String = prefix + "Update"
        let delete: String = prefix + "Delete"
        let copyLine: String = "let status = " + copyMatching + "(query as CFDictionary, &result)"
        let addLine: String = "add: { attributes in " + add + "(attributes as CFDictionary, nil) },"
        let updateLine: String = "update: { query, changes in " + update + "(query as CFDictionary, changes as CFDictionary) },"
        let deleteLine: String = "delete: { query in " + delete + "(query as CFDictionary) }"
        return [copyMatching: copyLine, add: addLine, update: updateLine, delete: deleteLine]
    }()

    /// `sources`: the four targets, comment-stripped. No item call outside
    /// the store; inside it, AMENDED (S-PAIR-C1.5, the C1.5 security
    /// review's R4 — its RP4' bound the add call unapplied, `let put = …`,
    /// and wrote a hand-built query with it, and a count of `<call>(` passed):
    /// each of the four calls is named exactly once, as a WORD, on its line
    /// in the binding, in every scan copy — so an unapplied reference, a
    /// second call or a call moved off its line all fail.
    ///
    /// AMENDED (#244): the four targets are named as
    /// `ApprovalChannelStructureTests.pathSources()` names them. Read by file
    /// name alone before, a file under the store's name in another target
    /// was let off the ban; by path, the store's name is the Sources/NapCat
    /// file's alone.
    static func itemCallFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != storeFile {
            let found = itemCallNames(in: text)
            if !found.isEmpty { failures.append("\(found) in \(name) — keychain access belongs in \(storeFile) in Sources/NapCat") }
        }
        guard let store = sources.first(where: { $0.name == storeFile })?.text else {
            return failures + ["\(storeFile) not found — the item-call lint would be vacuous"]
        }
        for copy in LidGuardStructureTests.constructorScanCopies(store) {
            let named = itemCallNames(in: copy).sorted()
            if named != itemCallTokens.sorted() {
                failures.append("\(storeFile) names the item calls \(named) — each of the four exactly once, in the binding")
            }
            for (token, line) in itemCallBindings.sorted(by: { $0.key < $1.key }) {
                failures += ApprovalRecordPathStructureTests.siteFailures(
                    "(?<![A-Za-z0-9_])" + token + "(?![A-Za-z0-9_])", in: copy, file: storeFile, allowed: [line: 1],
                    rule: "the item call is named once, on its line in the binding")
            }
        }
        return ApprovalRecordPathStructureTests.unique(failures)
    }

    /// The only file that talks to the keychain is KeychainTopicStore.swift:
    /// each Security item call appears there and nowhere else in the four
    /// targets (NapCatWire included) — and, since the C1.5 security review's
    /// R4, there exactly once each, on its line in the binding.
    @Test func onlyKeychainTopicStoreNamesTheSecurityItemCalls() throws {
        let sources = try ApprovalChannelStructureTests.pathSources()
        #expect(Self.itemCallFailures(sources).isEmpty, "\(Self.itemCallFailures(sources))")
        #expect(Set(Self.itemCallBindings.keys) == Set(Self.itemCallTokens), "vacuity: one binding line for each call")
        let wire = LidGuardStructureTests.repoRoot().appendingPathComponent("Sources/NapCatWire/AlertWire.swift")
        #expect(Self.itemCallNames(in: try String(contentsOf: wire, encoding: .utf8)).isEmpty)
        #expect(sources.contains { $0.name == "Sources/NapCatWire/AlertWire.swift" }, "vacuity: the scan covers NapCatWire, by path")

        // R4: RP4', as planted, and its neighbours.
        let prefix = "Sec" + "Item"
        let store = Self.storeFile
        func mutate(_ file: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            ApprovalChannelStructureTests.mutate(sources, file, transform)
        }
        let mutants: [(String, [(name: String, text: String)])] = [
            ("RP4': the add call unapplied, a hand-built query, in the store's file", mutate(store) {
                $0 + "\nfunc zzSecRevPlant(_ data: Data) -> OSStatus {\n    let put = " + prefix + "Add\n"
                    + "    return put([kSecClass as String: kSecClassGenericPassword, \"svce\": \"com.muratalkan.napcat\",\n"
                    + "                \"acct\": \"paired-\" + \"iphone-key\", \"v_Data\": data] as CFDictionary, nil)\n}\n" }),
            ("an unapplied call alone", mutate(store) { $0 + "\nlet zzPut = " + prefix + "Delete" }),
            ("a backticked unapplied call", mutate(store) { $0 + "\nlet zzPut = `" + prefix + "Update`" }),
            ("a second call in the store", mutate(store) {
                $0 + "\nfunc zz(_ q: CFDictionary) -> OSStatus { " + prefix + "Delete(q) }" }),
            ("a call moved off its binding line", mutate(store) {
                $0.replacingOccurrences(of: "add: { attributes in " + prefix + "Add(attributes as CFDictionary, nil) },",
                                        with: "add: { attributes in\n            " + prefix + "Add(attributes as CFDictionary, nil)\n        },") }),
            ("a relative of the calls", mutate(store) { $0 + "\nlet zz = " + prefix + "Export" }),
            ("a call in another target", mutate(ApprovalChannelStructureTests.seamPath) {
                $0 + "\nlet zz = " + prefix + "CopyMatching" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.itemCallFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The pre-R4 count of `<call>(` passed RP4' (vacuity of the plant).
        let rp4 = try #require(mutants.first?.1.first(where: { $0.name == store })?.text)
        #expect(Self.itemCallTokens.allSatisfy { rp4.components(separatedBy: $0 + "(").count - 1 == 1 },
                "RP4' is the shape the old call count passed")
        // Over-match controls: the status constants a store answers with,
        // and a whole-line comment naming a call.
        #expect(Self.itemCallFailures(mutate(store) {
            $0 + "\nlet zz = errSecItemNotFound, zzItemAdd = 1"
                + LidGuardStructureTests.codeOnly("\n/// never " + prefix + "Add outside the binding")
        }).isEmpty)
        // #244: a file under the store's name in another target is not the
        // store. One there holding an item call, or the store's own text, is
        // named by the ban, by its path.
        let storeText = ApprovalChannelStructureTests.text(store, in: sources)
        let namesakes = ApprovalChannelStructureTests.namesakes(of: store)
        #expect(namesakes.count == 3 && namesakes.allSatisfy { $0.contains("/") }, "vacuity: a namesake in each other target, by path")
        for path in namesakes {
            for (kind, text) in [("an item call", "let zz = " + prefix + "Delete(q)\n"), ("the store's twin", storeText)] {
                let mutant = ApprovalChannelStructureTests.inserting(sources, path, text)
                #expect(mutant.count == sources.count + 1, "canary '\(kind)' at \(path) did not apply")
                #expect(ApprovalChannelStructureTests.names(Self.itemCallFailures(mutant), path),
                        "canary '\(kind)' at \(path) was NOT named by the item-call ban")
            }
        }

        // The binding to the real calls is used only where it is defined, and
        // nothing anywhere asks for a synchronizable or data-protection item.
        // (#244: the sources name the other targets' files by path, so the
        // name below is the Sources/NapCat file's alone.)
        for (name, text) in sources where text.contains("." + "security" + "Framework") {
            #expect(name == "KeychainTopicStore.swift", "\(name) binds the real keychain calls")
        }
        for (name, text) in sources {
            #expect(!text.contains("kSecAttrSynchronizable"), "\(name): the topic must never sync through iCloud Keychain")
            #expect(!text.contains("kSecUseDataProtectionKeychain"), "\(name): ad-hoc builds cannot use the data-protection keychain")
        }
    }

    /// The matcher itself: identifiers that START with the prefix count; the
    /// status constants that merely contain it do not.
    @Test func theItemCallMatcherIsWordAnchored() {
        let prefix = "Sec" + "Item"
        #expect(Self.itemCallNames(in: "x = \(prefix)Add(q, nil); y = \(prefix)Delete(q)") == [prefix + "Add", prefix + "Delete"])
        #expect(Self.itemCallNames(in: "(\(prefix)CopyMatching") == [prefix + "CopyMatching"])
        #expect(Self.itemCallNames(in: "return errSecItemNotFound; errSecItemNotFound").isEmpty)
    }

    /// No test may reach the real keychain: no test file names a Security
    /// item call, the binding to them, or the app's real store.
    @Test func noTestFileCanReachTheRealKeychain() throws {
        let sources = try Self.testSources()
        #expect(sources.contains { $0.name == "KeychainTopicStoreTests.swift" }, "vacuity: the scan sees this file")
        #expect(sources.count > 30, "vacuity: the scan sees the whole suite")
        let violations = Self.testFileViolations(sources)
        #expect(violations.isEmpty, "\(violations)")
    }

    /// Canary: each way of reaching the real keychain from a test is caught.
    @Test func theTestFileLintCatchesMutants() throws {
        let sources = try Self.testSources()
        try #require(Self.testFileViolations(sources).isEmpty, "canary baseline must be clean")
        let mutants = [
            "_ = " + "Sec" + "ItemCopyMatching(query as CFDictionary, nil)",
            "_ = " + "Sec" + "ItemDelete(query as CFDictionary)",
            "let calls = KeychainItemCalls." + "security" + "Framework",
            "let store = KeychainTopicStore." + "login" + "Keychain",
        ]
        for mutant in mutants {
            let mutated = sources + [(name: "Canary.swift", text: "func canary() { \(mutant) }")]
            #expect(Self.testFileViolations(mutated).contains { $0.hasPrefix("Canary.swift") },
                    "canary '\(mutant)' was NOT caught")
        }
    }
}
