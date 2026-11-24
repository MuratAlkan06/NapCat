import Foundation
import os
import Security

/// The four keychain calls the key store makes, as plain closures, so the
/// store's own logic (the upsert, the status mapping, the query shape) is
/// fixture-tested with a recording fake. `securityFramework` binds the real
/// Security functions: this file is the only one in the app that names them
/// (lint-locked), and no test names this binding. The Mac's topic store
/// (#108) is built the same way.
struct PhoneKeychainCalls: Sendable {
    let copy: @Sendable (_ query: [String: Any]) -> (status: OSStatus, item: [String: Any]?)
    let add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    let update: @Sendable (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    let delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let securityFramework = PhoneKeychainCalls(
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? [String: Any])
        },
        add: { attributes in SecItemAdd(attributes as CFDictionary, nil) },
        update: { query, changes in SecItemUpdate(query as CFDictionary, changes as CFDictionary) },
        delete: { query in SecItemDelete(query as CFDictionary) }
    )
}

/// The phone's key items (F4 slice S-PAIR-B, #161): one generic password
/// per `KeySlot`, holding the enclave's encrypted block for the key (Apple:
/// "Storing CryptoKit Keys in the Keychain") and, in its generic attribute,
/// the enrollment hash the key was made under.
///
/// Item attributes: class generic password; the data-protection keychain;
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (readable only while the
/// phone is unlocked, never restored onto another device); and NO
/// `kSecAttrSynchronizable`, ever, so the item never travels through iCloud
/// Keychain — the account is the very channel the pairing does not trust.
/// The block alone is no key: only this phone's Secure Enclave can restore
/// one from it, and only after the match its access control asks for.
struct KeychainSigningKeyStore: SigningKeyStore {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat.phone", category: "signing")

    /// The items' service; each slot's account is `KeySlot.account`.
    static let service = "com.muratalkan.napcat.phone"
    /// The label a keychain listing shows.
    static let itemLabel = "NapCat signing key"

    let calls: PhoneKeychainCalls

    /// The app's store: the real keychain.
    static let phoneKeychain = KeychainSigningKeyStore(calls: .securityFramework)

    /// The item's identity: class, service, account, keychain. Every call
    /// starts here.
    func baseQuery(_ slot: KeySlot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: slot.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func readQuery(_ slot: KeySlot) -> [String: Any] {
        baseQuery(slot).merging([
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
    }

    /// What changes in an existing item: the block and the hash (an empty
    /// hash stands for "unreadable").
    func changes(_ key: StoredSigningKey) -> [String: Any] {
        [
            kSecValueData as String: key.keyData,
            kSecAttrGeneric as String: key.enrollment ?? Data(),
        ]
    }

    /// What a NEW item is created with.
    func addAttributes(_ key: StoredSigningKey, _ slot: KeySlot) -> [String: Any] {
        baseQuery(slot).merging(changes(key)) { _, new in new }.merging([
            kSecAttrLabel as String: Self.itemLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
    }

    func read(_ slot: KeySlot) -> SigningKeyRead {
        let answer = calls.copy(readQuery(slot))
        switch answer.status {
        case errSecSuccess:
            guard let data = answer.item?[kSecValueData as String] as? Data, !data.isEmpty else {
                Self.logger.error("keychain: the \(slot.rawValue, privacy: .public) item holds no key")
                return .failed(status: errSecDecode)
            }
            let enrollment = answer.item?[kSecAttrGeneric as String] as? Data
            return .found(StoredSigningKey(keyData: data, enrollment: enrollment?.isEmpty == false ? enrollment : nil))
        case errSecItemNotFound:
            return .notFound
        default:
            Self.logger.error("keychain: read failed (OSStatus \(answer.status, privacy: .public))")
            return .failed(status: answer.status)
        }
    }

    /// Upsert: replace an existing item's block and hash, and create the
    /// item only when there is none.
    func write(_ key: StoredSigningKey, to slot: KeySlot) -> Bool {
        let updated = calls.update(baseQuery(slot), changes(key))
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Self.logger.error("keychain: update failed (OSStatus \(updated, privacy: .public))")
            return false
        }
        let added = calls.add(addAttributes(key, slot))
        if added == errSecSuccess { return true }
        Self.logger.error("keychain: add failed (OSStatus \(added, privacy: .public))")
        return false
    }

    func delete(_ slot: KeySlot) -> Bool {
        let status = calls.delete(baseQuery(slot))
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        Self.logger.error("keychain: delete failed (OSStatus \(status, privacy: .public))")
        return false
    }
}
