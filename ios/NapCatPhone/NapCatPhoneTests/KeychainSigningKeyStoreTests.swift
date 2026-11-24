import Foundation
@testable import NapCatPhone
import Security
import Testing

/// The keychain calls, played by a test: every query recorded, every
/// answer scripted. The real keychain is never reached.
final class RecordingKeychain: @unchecked Sendable {
    enum Call: Equatable {
        case copy, add, update, delete
    }

    private let lock = NSLock()
    private var log: [(call: Call, query: [String: Any])] = []
    var copyAnswer: (status: OSStatus, item: [String: Any]?) = (errSecItemNotFound, nil)
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecItemNotFound
    var deleteStatus: OSStatus = errSecSuccess

    var calls: PhoneKeychainCalls {
        PhoneKeychainCalls(
            copy: { query in self.note(.copy, query); return self.copyAnswer },
            add: { attributes in self.note(.add, attributes); return self.addStatus },
            update: { query, changes in self.note(.update, query.merging(changes) { _, new in new }); return self.updateStatus },
            delete: { query in self.note(.delete, query); return self.deleteStatus }
        )
    }

    private func note(_ call: Call, _ query: [String: Any]) {
        lock.lock()
        log.append((call, query))
        lock.unlock()
    }

    var recorded: [(call: Call, query: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}

/// The phone's key items (F4 slice S-PAIR-B): one generic password per
/// slot, in the data-protection keychain, readable only while unlocked, on
/// this device only, and never synchronized; and the store's own logic,
/// over recorded calls.
@Suite struct KeychainSigningKeyStoreTests {
    static let key = StoredSigningKey(keyData: Data([1, 2, 3, 4]), enrollment: Data([9, 9]))

    static func store(_ keychain: RecordingKeychain) -> KeychainSigningKeyStore {
        KeychainSigningKeyStore(calls: keychain.calls)
    }

    /// Every query names the item exactly and the data-protection keychain,
    /// and none names synchronization at all.
    @Test(arguments: KeySlot.allCases)
    func everyQueryNamesTheItemAndNeverSynchronizes(_ slot: KeySlot) {
        let keychain = RecordingKeychain()
        let store = Self.store(keychain)
        _ = store.read(slot)
        _ = store.write(Self.key, to: slot)
        _ = store.delete(slot)
        #expect(keychain.recorded.map(\.call) == [.copy, .update, .add, .delete])
        for (_, query) in keychain.recorded {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "com.muratalkan.napcat.phone")
            #expect(query[kSecAttrAccount as String] as? String == slot.account)
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecAttrSynchronizable as String] == nil, "never synchronized: the key is not set at all")
        }
    }

    /// A new item: the key block, the enrollment hash, readable only while
    /// the phone is unlocked, on this device only.
    @Test func aNewItemIsThisDeviceOnlyWhenUnlocked() throws {
        let keychain = RecordingKeychain()
        #expect(Self.store(keychain).write(Self.key, to: .committed))
        let add = try #require(keychain.recorded.first { $0.call == .add }?.query)
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(add[kSecValueData as String] as? Data == Self.key.keyData)
        #expect(add[kSecAttrGeneric as String] as? Data == Self.key.enrollment)
        #expect(add[kSecAttrLabel as String] as? String == "NapCat signing key")
    }

    /// The two slots are two items.
    @Test func theSlotsAreTwoItems() {
        #expect(Set(KeySlot.allCases.map(\.account)).count == KeySlot.allCases.count)
        #expect(KeySlot.committed.account == "signing-key")
        #expect(KeySlot.provisional.account == "signing-key-provisional")
    }

    // MARK: Upsert

    @Test func anExistingItemIsUpdatedInPlace() {
        let keychain = RecordingKeychain()
        keychain.updateStatus = errSecSuccess
        #expect(Self.store(keychain).write(Self.key, to: .committed))
        #expect(keychain.recorded.map(\.call) == [.update])
    }

    @Test func aFailedUpdateAddsNothing() {
        let keychain = RecordingKeychain()
        keychain.updateStatus = errSecInteractionNotAllowed
        #expect(!Self.store(keychain).write(Self.key, to: .committed))
        #expect(keychain.recorded.map(\.call) == [.update])
    }

    @Test func aFailedAddIsAFailedWrite() {
        let keychain = RecordingKeychain()
        keychain.addStatus = errSecDuplicateItem
        #expect(!Self.store(keychain).write(Self.key, to: .committed))
    }

    /// An unreadable hash is stored as an empty one and read back as none.
    @Test func anUnreadableEnrollmentRoundTripsAsNone() throws {
        let keychain = RecordingKeychain()
        _ = Self.store(keychain).write(StoredSigningKey(keyData: Data([7]), enrollment: nil), to: .provisional)
        let add = try #require(keychain.recorded.first { $0.call == .add }?.query)
        #expect(add[kSecAttrGeneric as String] as? Data == Data())
        keychain.copyAnswer = (errSecSuccess, [kSecValueData as String: Data([7]), kSecAttrGeneric as String: Data()])
        #expect(Self.store(keychain).read(.provisional) == .found(StoredSigningKey(keyData: Data([7]), enrollment: nil)))
    }

    // MARK: Reading

    struct ReadRow: CustomTestStringConvertible, @unchecked Sendable {
        let name: String
        let status: OSStatus
        let item: [String: Any]?
        let expected: SigningKeyRead
        var testDescription: String { name }
    }

    static let readRows: [ReadRow] = [
        ReadRow(name: "found", status: errSecSuccess,
                item: [kSecValueData as String: Data([1, 2]), kSecAttrGeneric as String: Data([3])],
                expected: .found(StoredSigningKey(keyData: Data([1, 2]), enrollment: Data([3])))),
        ReadRow(name: "found, no hash attribute", status: errSecSuccess, item: [kSecValueData as String: Data([1, 2])],
                expected: .found(StoredSigningKey(keyData: Data([1, 2]), enrollment: nil))),
        ReadRow(name: "an item with no key", status: errSecSuccess, item: [kSecAttrGeneric as String: Data([3])],
                expected: .failed(status: errSecDecode)),
        ReadRow(name: "an empty key", status: errSecSuccess, item: [kSecValueData as String: Data()],
                expected: .failed(status: errSecDecode)),
        ReadRow(name: "no item", status: errSecItemNotFound, item: nil, expected: .notFound),
        ReadRow(name: "locked", status: errSecInteractionNotAllowed, item: nil, expected: .failed(status: errSecInteractionNotAllowed)),
    ]

    @Test(arguments: readRows)
    func aReadSaysWhatItFound(_ row: ReadRow) throws {
        let keychain = RecordingKeychain()
        keychain.copyAnswer = (row.status, row.item)
        #expect(Self.store(keychain).read(.committed) == row.expected)
        let query = try #require(keychain.recorded.first?.query)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test(arguments: [(errSecSuccess, true), (errSecItemNotFound, true), (errSecInteractionNotAllowed, false)])
    func aDeleteIsDoneWhenTheItemIsGone(_ status: OSStatus, _ done: Bool) {
        let keychain = RecordingKeychain()
        keychain.deleteStatus = status
        #expect(Self.store(keychain).delete(.provisional) == done)
    }
}
