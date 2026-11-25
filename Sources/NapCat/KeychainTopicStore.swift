import Foundation
import os
import Security

/// The name of one of NapCat's keychain items — service + account in a
/// single constant, so the app and `scripts/uninstall.sh` address the same
/// item (KeychainTopicStoreTests parity-lints the uninstaller's two literals
/// against the topic's value).
struct KeychainItemName: Equatable, Sendable {
    let service: String
    let account: String

    /// The ntfy topic (issue #103, audit F-2).
    static let ntfyTopic = KeychainItemName(service: "com.muratalkan.napcat", account: "ntfy-topic")
    /// F4 slice S-PAIR-C1 (#168): the paired iPhone's PUBLIC key, the one
    /// slot (`PairedKeyStore`). Not a secret, but what it authenticates is
    /// the point, so it lives beside the topic under the same rules: this
    /// Mac only, never synchronized.
    static let pairedPhone = KeychainItemName(service: "com.muratalkan.napcat", account: "paired-iphone-key")
}

/// What one read of the stored topic found. The value travels only inside
/// `.found` — it is never logged.
enum TopicStoreRead: Equatable, Sendable {
    case found(String)
    case notFound
    /// The keychain answered with an error, or with bytes that are not UTF-8
    /// text. `status` is the OSStatus — a number, not a secret.
    case failed(status: Int32)
}

/// The storage seam for the ntfy topic — a bearer credential, so it lives in
/// the keychain, not in UserDefaults (issue #103, audit F-2). The app's one
/// conformer is `KeychainTopicStore.loginKeychain`; tests substitute a fake
/// and never reach the real keychain (lint-locked in KeychainTopicStoreTests).
protocol TopicStore: Sendable {
    func read() -> TopicStoreRead
    /// Creates or replaces the item. True only when the keychain reported
    /// success.
    func write(_ topic: String) -> Bool
    /// Removes the item. True when it is gone — deleted now, or never there.
    func delete() -> Bool
}

/// The four keychain calls the store makes, as plain closures, so the
/// store's own logic — the upsert, the status mapping, the query shape — is
/// fixture-tested with a recording fake. `securityFramework` binds the real
/// Security functions: this file is the only one in the repo that names them
/// (lint-locked), and no test file may name this binding.
struct KeychainItemCalls: Sendable {
    let copyData: @Sendable (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    let add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    let update: @Sendable (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    let delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let securityFramework = KeychainItemCalls(
        copyData: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { attributes in SecItemAdd(attributes as CFDictionary, nil) },
        update: { query, changes in SecItemUpdate(query as CFDictionary, changes as CFDictionary) },
        delete: { query in SecItemDelete(query as CFDictionary) }
    )
}

/// The topic as ONE generic-password item in the user's login keychain.
/// (Since S-PAIR-C1 the same store, over `KeychainItemName.pairedPhone`,
/// keeps the paired iPhone's public key as text: `PairedKeyStore`.)
///
/// Item attributes (gate ruling, #103): class generic password;
/// `kSecAttrAccessibleAfterFirstUnlock`; NO `kSecAttrSynchronizable`, so the
/// item never leaves this Mac through iCloud Keychain. There is no access
/// group (a plain `make` build carries no entitlements), so the item lives in
/// the file-based login keychain — which, per Apple's documentation, drops
/// `kSecAttrAccessible` (it applies only to the data-protection keychain). It
/// is set anyway: it states the intent and holds if the item ever moves.
///
/// That keychain guards each item with an access list naming the app that
/// created it. An ad-hoc signed rebuild is a new code identity, so its first
/// read of an existing item asks the user once (Allow / Always Allow); a
/// stably signed release does not.
///
/// Every call blocks until the keychain answers — including while that
/// dialog is up. The lid guard reads the item ONCE, at startup, and keeps the
/// topic in memory; the sleep path never comes here.
struct KeychainTopicStore: TopicStore {
    private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "keychain")

    let item: KeychainItemName
    let calls: KeychainItemCalls

    /// The app's store: the real keychain. Referenced by the app wiring only.
    static let loginKeychain = KeychainTopicStore(item: .ntfyTopic, calls: .securityFramework)

    /// S-PAIR-C1 (#168): the paired key's slot in the real keychain.
    /// Referenced by the app wiring only, handed to `PairedKeyStore`.
    static let pairedPhoneKeychain = KeychainTopicStore(item: .pairedPhone, calls: .securityFramework)

    /// The label Keychain Access (and the Allow dialog) shows for the item.
    static let itemLabel = "NapCat ntfy topic"
    /// ... and for the paired key's item.
    static let pairedPhoneItemLabel = "NapCat paired iPhone key"

    /// This store's item label.
    var label: String { item == .pairedPhone ? Self.pairedPhoneItemLabel : Self.itemLabel }

    /// The item's identity — class, service, account. Every call starts here.
    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
    }

    var readQuery: [String: Any] {
        baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
    }

    /// What a NEW item is created with.
    func addAttributes(_ data: Data) -> [String: Any] {
        baseQuery.merging([
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
    }

    func read() -> TopicStoreRead {
        let answer = calls.copyData(readQuery)
        switch answer.status {
        case errSecSuccess:
            guard let data = answer.data, let value = String(data: data, encoding: .utf8) else {
                Self.logger.error("keychain: the stored item is not UTF-8 text — ignored")
                return .failed(status: errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            Self.logger.error("keychain: read failed (OSStatus \(answer.status, privacy: .public))")
            return .failed(status: answer.status)
        }
    }

    /// Upsert: replace the data of an existing item, and create the item only
    /// when there is none. Updating in place keeps the item's access list.
    func write(_ topic: String) -> Bool {
        let data = Data(topic.utf8)
        let updated = calls.update(baseQuery, [kSecValueData as String: data])
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Self.logger.error("keychain: update failed (OSStatus \(updated, privacy: .public))")
            return false
        }
        let added = calls.add(addAttributes(data))
        if added == errSecSuccess { return true }
        Self.logger.error("keychain: add failed (OSStatus \(added, privacy: .public))")
        return false
    }

    func delete() -> Bool {
        let status = calls.delete(baseQuery)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        Self.logger.error("keychain: delete failed (OSStatus \(status, privacy: .public))")
        return false
    }
}
