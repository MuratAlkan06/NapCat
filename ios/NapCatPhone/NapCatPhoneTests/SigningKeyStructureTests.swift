import Foundation
import Testing

/// F4 slice S-PAIR-B (#161): the locks over the phone's signing key, read
/// from the sources (the simulator has no Secure Enclave, so what the
/// enclave file asks of the hardware is pinned as text).
///
/// 1. Biometrics only, everywhere (CL-3): no source names a passcode or any
///    other fallback, in an access control or a policy.
/// 2. The key is made under ONE access control, on its pinned line: usable
///    after a match of the biometrics enrolled now, for signing, on this
///    device only, while unlocked. The enclave is named in one file, and a
///    key is made there once and restored there once.
/// 3. The key items: the keychain functions are named in one file; no
///    source names synchronization; the only accessibility named is
///    "when unlocked, this device only"; every item query is in the
///    data-protection keychain.
/// 4. Software keys stay fixtures: the software enclave and the in-memory
///    store are built only under Fixtures/ (and by tests).
/// 5. The signing tests touch nothing live: no enclave, no keychain, no
///    context, no live binding.
///
/// Each lock is a pure function over comment-stripped sources and catches
/// planted canaries, so none can pass vacuously.
@Suite struct SigningKeyStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir = CloudKitStructureTests.appDir
    static let enclaveFile = "\(appDir)/Live/SecureEnclaveSigner.swift"
    static let keychainFile = "\(appDir)/Live/KeychainSigningKeyStore.swift"
    static let softwareFile = "\(appDir)/Fixtures/SoftwareEnclave.swift"

    static func app() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: appDir)
    }

    static func mutate(_ sources: [Source], _ path: String, _ transform: (String) -> String) -> [Source] {
        sources.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
    }

    // MARK: 1. Biometrics only

    /// Every fallback an access control or a policy can name: the passcode,
    /// "user presence" (biometrics OR the passcode), an `.or`, any enrolled
    /// set instead of the current one, an app password, a companion device
    /// or a watch, and the policies that allow any of them.
    static let fallbackPatterns = [
        #"\.devicePasscode\b"#, #"\.userPresence\b"#, #"\.or\b"#, #"\.biometryAny\b"#, #"\.applicationPassword\b"#,
        #"\.companion\b"#, #"\.watch\b"#, #"\bkSecAccessControl\w+"#, #"\bdeviceOwnerAuthentication(?!WithBiometrics\b)\w*"#,
    ]

    static func fallbackFailures(_ app: [Source]) -> [String] {
        app.flatMap { path, text in
            let code = CloudKitStructureTests.codeOnly(text)
            return fallbackPatterns.filter { CloudKitStructureTests.hits($0, in: code) }
                .map { "'\($0)' in \(path) — biometrics only, no fallback (CL-3)" }
        }
    }

    @Test func noSourceNamesAFallback() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.enclaveFile }, "vacuity: the scan sees the enclave file")
        #expect(Self.fallbackFailures(app).isEmpty, "\(Self.fallbackFailures(app))")
        let plants = [
            "[.privateKeyUsage, .biometryCurrentSet, .or, .devicePasscode]", "[.privateKeyUsage, .userPresence]",
            "[.privateKeyUsage, .biometryAny]", "let p = LAPolicy.deviceOwnerAuthentication",
            "let p = LAPolicy.deviceOwnerAuthenticationWithBiometricsOrCompanion", "let f: SecAccessControlCreateFlags = .companion",
            "let f = kSecAccessControlDevicePasscode",
        ]
        for plant in plants {
            let mutant = Self.mutate(app, Self.enclaveFile) { $0 + "\nlet x = \(plant)" }
            #expect(!Self.fallbackFailures(mutant).isEmpty, "canary '\(plant)' was NOT caught")
        }
        // The biometric policy itself, and words that merely begin alike, pass.
        #expect(Self.fallbackFailures(Self.mutate(app, Self.enclaveFile) {
            $0 + "\nlet p = LAPolicy.deviceOwnerAuthenticationWithBiometrics\nlet c = Color.orange\n// never .devicePasscode"
        }).isEmpty)
    }

    // MARK: 2. One access control, one enclave file

    static let accessControlLine =
        "SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)"
    static let makeLine = "let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else { return nil }"
    static let restoreLine =
        "let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: context)"

    static func accessControlFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            if path != enclaveFile, CloudKitStructureTests.hits(#"\bSecureEnclave\b|\bSecAccessControl"#, in: code) {
                failures.append("\(path) names the enclave or an access control — only \(enclaveFile) may")
            }
        }
        let enclave = CloudKitStructureTests.codeOnly(app.first { $0.path == enclaveFile }?.text ?? "")
        failures += CloudKitStructureTests.siteFailures(#"\bSecAccessControlCreateWithFlags\b"#, in: enclave, file: enclaveFile,
                                                       allowed: [accessControlLine: 1], rule: "the key's one access control")
        failures += CloudKitStructureTests.siteFailures(#"\bSecureEnclave\s*\.\s*P256\b"#, in: enclave, file: enclaveFile,
                                                       allowed: [makeLine: 1, restoreLine: 1],
                                                       rule: "a key is made once and restored once")
        return failures
    }

    @Test func theKeyIsMadeUnderOneAccessControl() throws {
        let app = try Self.app()
        #expect(Self.accessControlFailures(app).isEmpty, "\(Self.accessControlFailures(app))")
        let enclave = Self.enclaveFile
        let mutants: [(String, [Source])] = [
            ("any enrolled set", Self.mutate(app, enclave) { $0.replacingOccurrences(of: ".biometryCurrentSet]", with: ".biometryAny]") }),
            ("a weaker accessibility", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "kSecAttrAccessibleWhenUnlockedThisDeviceOnly", with: "kSecAttrAccessibleAfterFirstUnlock") }),
            ("no biometrics at all", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "[.privateKeyUsage, .biometryCurrentSet]", with: "[.privateKeyUsage]") }),
            ("a key with no access control", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "PrivateKey(accessControl: access)", with: "PrivateKey()") }),
            ("a second restore", Self.mutate(app, enclave) {
                $0 + "\nfunc spare(d: Data) { _ = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: d) }" }),
            ("the enclave named elsewhere", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nlet spare = SecureEnclave.isAvailable" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.accessControlFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 3. The key items

    static let keychainFunctions = #"\bSecItem(?:Add|Update|CopyMatching|Delete)\b"#
    static let accessibility = #"\bkSecAttrAccessible\w+"#
    static let dataProtection = "kSecUseDataProtectionKeychain as String: true,"

    static func keychainFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            if path != keychainFile, CloudKitStructureTests.hits(keychainFunctions, in: code) {
                failures.append("\(path) calls the keychain — only \(keychainFile) may")
            }
            if CloudKitStructureTests.hits(#"\bkSecAttrSynchronizable\w*"#, in: code) {
                failures.append("\(path) names synchronization — the key items never leave the phone")
            }
            for constant in CloudKitStructureTests.matches(accessibility, in: code)
            where constant != "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" {
                failures.append("\(path) names \(constant) — the only accessibility is when unlocked, this device only")
            }
        }
        let keychain = CloudKitStructureTests.codeOnly(app.first { $0.path == keychainFile }?.text ?? "")
        if CloudKitStructureTests.occurrences(of: dataProtection, in: keychain) != 1
            || !keychain.contains("func baseQuery(_ slot: KeySlot) -> [String: Any] {") {
            failures.append("every item query must start from the one base query, in the data-protection keychain")
        }
        if CloudKitStructureTests.occurrences(of: "kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,",
                                              in: keychain) != 1 {
            failures.append("a new item must be made readable only while unlocked, on this device only")
        }
        return failures
    }

    @Test func theKeyItemsStayOnThisPhone() throws {
        let app = try Self.app()
        #expect(Self.keychainFailures(app).isEmpty, "\(Self.keychainFailures(app))")
        let keychain = Self.keychainFile
        let mutants: [(String, [Source])] = [
            ("synchronized", Self.mutate(app, keychain) {
                $0.replacingOccurrences(of: Self.dataProtection, with: Self.dataProtection + " kSecAttrSynchronizable as String: true,") }),
            ("synchronizable any", Self.mutate(app, keychain) { $0 + "\nlet q = [kSecAttrSynchronizableAny: true]" }),
            ("readable after the first unlock", Self.mutate(app, keychain) {
                $0.replacingOccurrences(of: "kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
                                        with: "kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock") }),
            ("restorable elsewhere", Self.mutate(app, keychain) {
                $0.replacingOccurrences(of: "kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
                                        with: "kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked") }),
            ("the file keychain", Self.mutate(app, keychain) {
                $0.replacingOccurrences(of: Self.dataProtection, with: "kSecUseDataProtectionKeychain as String: false,") }),
            ("a keychain call elsewhere", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nfunc spare(q: CFDictionary) { _ = SecItemDelete(q) }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keychainFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 4. Software keys stay fixtures

    static let softwareTypes = ["SoftwareEnclave", "MemorySigningKeyStore", "FixedEnrollment"]

    static func softwareFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app where !path.hasPrefix("\(appDir)/Fixtures/") {
            let code = RecordPathStructureTests.constructionSpelling(CloudKitStructureTests.codeOnly(text))
            for type in softwareTypes where CloudKitStructureTests.hits(#"\b"# + type + #"\("#, in: code) {
                failures.append("\(path) builds \(type) — software keys are for fixtures and tests only")
            }
        }
        return failures
    }

    @Test func softwareKeysStayFixtures() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.softwareFile }, "vacuity: the software enclave is where the lock looks")
        #expect(Self.softwareFailures(app).isEmpty, "\(Self.softwareFailures(app))")
        for type in Self.softwareTypes {
            for spelling in ["\(type)()", "\(type).init()", "\(type) ()"] {
                let mutant = Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") { $0 + "\nlet spare = \(spelling)" }
                #expect(!Self.softwareFailures(mutant).isEmpty, "canary '\(spelling)' was NOT caught")
            }
        }
    }

    // MARK: 5. The signing tests touch nothing live

    static let testsDir = CloudKitStructureTests.testsDir
    static let signingTestFiles = ["PhoneKeyringTests.swift", "KeychainSigningKeyStoreTests.swift"]

    /// The enclave, the keychain functions, a context, and the live
    /// bindings and conformers.
    static let liveTokens = ["SecureEnclave.", "SecItemAdd", "SecItemUpdate", "SecItemCopyMatching", "SecItemDelete",
                             "LAContext", "SecureEnclaveSigner(", ".securityFramework", "phoneKeychain",
                             "LocalAuthenticationMatch(", "LocalAuthenticationEnrollment(", "LocalAuthenticationGate("]

    static func liveFailures(_ tests: [Source]) -> [String] {
        tests.flatMap { path, text in
            let code = RecordPathStructureTests.constructionSpelling(CloudKitStructureTests.codeOnly(text))
            return liveTokens.filter { code.contains($0) }.map { "'\($0)' in \(path) — the signing tests touch nothing live" }
        }
    }

    static func signingTests() throws -> [Source] {
        let all = try CloudKitStructureTests.swiftFiles(under: testsDir)
        return signingTestFiles.map { name in
            let path = "\(testsDir)/\(name)"
            return (path, all.first { $0.path == path }?.text ?? "")
        }
    }

    @Test func theSigningTestsTouchNothingLive() throws {
        let tests = try Self.signingTests()
        #expect(tests.allSatisfy { !$0.text.isEmpty }, "vacuity: every listed file was read")
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let k = try SecureEnclave.P256.Signing.PrivateKey()", "_ = SecItemCopyMatching(q, &r)", "let c = LAContext()",
                        "let e = SecureEnclaveSigner()", "let e = SecureEnclaveSigner.init()", "let s = KeychainSigningKeyStore.phoneKeychain",
                        "let s = KeychainSigningKeyStore(calls: .securityFramework)", "let g = LocalAuthenticationGate()"] {
            let mutant = tests.map { ($0.path, $0.text + "\n" + planted) }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }
}
