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
    static let bindingTokens = ["security" + "Framework", "login" + "Keychain"]

    static func testFileViolations(_ sources: [(name: String, text: String)]) -> [String] {
        sources.flatMap { file in
            itemCallNames(in: file.text).map { "\(file.name) names '\($0)'" }
                + bindingTokens.filter { file.text.contains($0) }.map { "\(file.name) names '\($0)'" }
        }
    }

    /// The only file that talks to the keychain is KeychainTopicStore.swift:
    /// each Security item call appears there and nowhere else in Sources
    /// (NapCatWire included).
    @Test func onlyKeychainTopicStoreNamesTheSecurityItemCalls() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        for (name, text) in sources {
            let found = Self.itemCallNames(in: text)
            #expect(found.isEmpty || name == "KeychainTopicStore.swift",
                    "\(found) in \(name) — keychain access belongs in KeychainTopicStore.swift")
        }
        let store = try #require(sources.first { $0.name == "KeychainTopicStore.swift" })
        #expect(Set(Self.itemCallNames(in: store.text)) == Set(Self.itemCallTokens),
                "KeychainTopicStore.swift makes exactly the four item calls — and the lint is not vacuous")
        for token in Self.itemCallTokens {
            #expect(store.text.components(separatedBy: token + "(").count - 1 == 1, "'\(token)' is called once, in the binding")
        }
        let wire = LidGuardStructureTests.repoRoot().appendingPathComponent("Sources/NapCatWire/AlertWire.swift")
        #expect(Self.itemCallNames(in: try String(contentsOf: wire, encoding: .utf8)).isEmpty)

        // The binding to the real calls is used only where it is defined, and
        // nothing anywhere asks for a synchronizable or data-protection item.
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
