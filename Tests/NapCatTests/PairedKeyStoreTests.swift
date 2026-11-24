// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CryptoKit
import NapCatWire
import Testing
@testable import NapCat

/// F4 slice S-PAIR-C1 (#168): the one paired-phone slot. The real keychain
/// store's logic runs against `RecordingKeychainCalls` (never the keychain);
/// the slot's own logic against `FakeTopicStore`. One item, this Mac only,
/// never synchronized; a pairing replaces it whole; Unpair deletes it; a
/// stored text not exactly this build's form reads as unreadable, never as a
/// key.
struct PairedKeyStoreTests {
    static let key = Array(P256.Signing.PrivateKey().publicKey.x963Representation)
    static let otherKey = Array(P256.Signing.PrivateKey().publicKey.x963Representation)
    static let pairedAt = Date(timeIntervalSince1970: 1_800_000_000.75)

    static func phone(_ key: [UInt8] = key, at date: Date = pairedAt) throws -> PairedPhone {
        try #require(PairedPhone(publicKey: key, pairedAt: date))
    }

    // MARK: - The paired phone

    @Test func aPairedPhoneIsItsKeyItsCodeAndAWholeSecond() throws {
        let phone = try Self.phone()
        #expect(phone.publicKey == Self.key)
        #expect(phone.fingerprint == PairingFingerprint(digest: Array(SHA256.hash(data: Self.key))))
        #expect(phone.pairedAt == Date(timeIntervalSince1970: 1_800_000_000), "whole seconds")
        #expect(PairedPhone(publicKey: Array(Self.key.dropLast()), pairedAt: Self.pairedAt) == nil)
        #expect(PairedPhone(publicKey: [0x04] + Array(repeating: 0xab, count: 64), pairedAt: Self.pairedAt) == nil, "no curve point")
        #expect(PairedPhone(publicKey: Self.key, pairedAt: Date(timeIntervalSince1970: -1)) == nil)
    }

    // MARK: - The stored text

    @Test func theStoredTextIsFourFixedLines() throws {
        let phone = try Self.phone()
        let text = PairedKeyStore.text(of: phone)
        #expect(text == "napcat-paired-v1\nkey:\(ApprovalSigning.lowercaseHex(Self.key))\n"
                + "fingerprint:\(phone.fingerprint.lowercaseHex)\npaired:1800000000\n")
        #expect(PairedKeyStore.phone(from: text) == phone)
    }

    @Test func anythingButThatFormIsUnreadable() throws {
        let phone = try Self.phone()
        let good = PairedKeyStore.text(of: phone)
        let other = try Self.phone(Self.otherKey)
        let swaps: [(String, String)] = [
            ("another header", good.replacingOccurrences(of: "napcat-paired-v1", with: "napcat-paired-v2")),
            ("no final line feed", String(good.dropLast())),
            ("an extra line", good + "note:x\n"),
            ("CRLF", good.replacingOccurrences(of: "\n", with: "\r\n")),
            ("uppercase key hex", good.replacingOccurrences(of: ApprovalSigning.lowercaseHex(Self.key),
                                                            with: ApprovalSigning.lowercaseHex(Self.key).uppercased())),
            ("an odd key", good.replacingOccurrences(of: "key:04", with: "key:4")),
            ("a code not the key's", good.replacingOccurrences(of: phone.fingerprint.lowercaseHex, with: other.fingerprint.lowercaseHex)),
            ("a leading zero", good.replacingOccurrences(of: "paired:1800000000", with: "paired:01800000000")),
            ("a negative time", good.replacingOccurrences(of: "paired:1800000000", with: "paired:-1")),
            ("a fractional time", good.replacingOccurrences(of: "paired:1800000000", with: "paired:1800000000.5")),
            ("lines reordered", good.replacingOccurrences(of: "key:", with: "kez:")),
            ("empty", ""),
        ]
        for (name, text) in swaps {
            #expect(text != good, "\(name) did not apply")
            #expect(PairedKeyStore.phone(from: text) == nil, "\(name) read as a pairing")
        }
    }

    // MARK: - The slot over a store

    @Test func theSlotReadsCommitsAndUnpairs() throws {
        let items = FakeTopicStore()
        let store = PairedKeyStore(items: items)
        #expect(store.read() == .notPaired)
        let first = try Self.phone()
        #expect(store.commit(first))
        #expect(store.read() == .paired(first))
        // Re-pair replaces the one slot in one write.
        let second = try Self.phone(Self.otherKey)
        #expect(store.commit(second))
        #expect(store.read() == .paired(second) && items.writeCount == 2)
        #expect(store.unpair())
        #expect(store.read() == .notPaired)
        #expect(store.unpair(), "unpairing nothing is done")
    }

    @Test func aFailedCommitLeavesTheSlotAsItWas() throws {
        let items = FakeTopicStore()
        let store = PairedKeyStore(items: items)
        let first = try Self.phone()
        #expect(store.commit(first))
        items.setFailWrites(true)
        #expect(!store.commit(try Self.phone(Self.otherKey)))
        #expect(store.read() == .paired(first), "the old key stays committed")
    }

    @Test func aKeychainThatRefusesOrHoldsJunkReadsUnreadable() {
        let items = FakeTopicStore("not a pairing")
        let store = PairedKeyStore(items: items)
        #expect(store.read() == .unreadable)
        items.setReadAnswer(.failed(status: errSecUserCanceled))
        #expect(store.read() == .unreadable)
        items.setReadAnswer(.notFound)
        #expect(store.read() == .notPaired)
    }

    // MARK: - The real store's item (recording fake keychain)

    /// One generic-password item addressed by its own account, labelled for
    /// Keychain Access, never synchronizable; the topic's item untouched.
    @Test func thePairedKeyIsItsOwnNonSynchronizableItem() throws {
        #expect(KeychainItemName.pairedPhone == KeychainItemName(service: "com.muratalkan.napcat", account: "paired-iphone-key"))
        #expect(KeychainItemName.pairedPhone != KeychainItemName.ntfyTopic)
        let fake = RecordingKeychainCalls()
        let items = KeychainTopicStore(item: .pairedPhone, calls: fake.api)
        let add = items.addAttributes(Data("x".utf8))
        #expect(add[kSecAttrAccount as String] as? String == "paired-iphone-key")
        #expect(add[kSecAttrLabel as String] as? String == "NapCat paired iPhone key")
        #expect(add[kSecAttrSynchronizable as String] == nil && add[kSecUseDataProtectionKeychain as String] == nil)
        #expect(KeychainTopicStore(item: .ntfyTopic, calls: fake.api).addAttributes(Data())[kSecAttrLabel as String] as? String
                == KeychainTopicStore.itemLabel, "the topic's label is unchanged")

        // A pairing is one add, then an update in place: one item, swapped whole.
        let store = PairedKeyStore(items: items)
        #expect(store.commit(try Self.phone()))
        #expect(store.commit(try Self.phone(Self.otherKey)))
        #expect(fake.calls.map(\.name) == ["update", "add", "update"])
        #expect(store.read() == .paired(try Self.phone(Self.otherKey)))
        #expect(store.unpair() && fake.storedData == nil)
    }
}
