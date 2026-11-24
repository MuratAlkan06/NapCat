import Foundation
import Testing

/// F4 slice S-PAIR-B (#161): the locks over the phone's signing key, read
/// from the sources (the simulator has no Secure Enclave, so what the
/// enclave file asks of the hardware is pinned as text).
///
/// 1. Biometrics only, everywhere (CL-3): no source names a passcode or any
///    other fallback, in an access control or a policy. The biometric
///    policy is named once, as the gate's `policy`; no source builds a
///    policy (a raw value reaches the passcode's under no fallback's name)
///    or names a reuse duration (a recent unlock is not a match).
/// 2. The key is made under ONE access control, on its pinned line: usable
///    after a match of the biometrics enrolled now, for signing, on this
///    device only, while unlocked. The enclave is named in one file, and a
///    key is made there once and restored there once.
/// 3. The key items: the keychain functions are named in one file; no
///    source names synchronization; the only accessibility named is
///    "when unlocked, this device only"; every item query is in the
///    data-protection keychain.
/// 4. Software keys stay fixtures: the software enclave, the in-memory
///    store and the fixed enrollment are named only under Fixtures/ (and by
///    tests), in any form: built, typed, or as a generic argument.
/// 5. The signing tests touch nothing live: no enclave, no keychain, no
///    context, no live binding.
/// 6. The live key wiring: the live keyring (the keychain, the Secure
///    Enclave, the live enrollment) is built once, in `RequestInbox.make`,
///    and handed to the live inbox there; no file under Fixtures/ names a
///    live key part, so no fixture can mix one with a software key.
///
/// Each lock is a pure function over comment-stripped sources and catches
/// planted canaries, so none can pass vacuously.
@Suite struct SigningKeyStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir = CloudKitStructureTests.appDir
    static let enclaveFile = "\(appDir)/Live/SecureEnclaveSigner.swift"
    static let keychainFile = "\(appDir)/Live/KeychainSigningKeyStore.swift"
    static let gateFile = "\(appDir)/Live/LocalAuthenticationGate.swift"
    static let inboxFile = "\(appDir)/Model/RequestInbox.swift"
    static let fixturesDir = "\(appDir)/Fixtures/"
    static let softwareFile = "\(fixturesDir)SoftwareEnclave.swift"

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

    /// The policy's one site. Its name is pinned (explicit or implicit
    /// member, every file) to the gate's `policy` line, which the gate
    /// alone evaluates (`MatchHygieneStructureTests`).
    static let policyName = #"\bdeviceOwnerAuthenticationWithBiometrics\b"#
    static let policyLine = "static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics"
    /// A policy built, not named: `LAPolicy(rawValue: 2)` is the passcode's.
    /// Read in every constructor scan copy, so a spaced, backticked or
    /// comment-split construction is one too.
    static let policyBuilt = #"\bLAPolicy\s*(?:\(|\.\s*init\b)"#
    /// `touchIDAuthenticationAllowableReuseDuration` and its maximum: a
    /// device unlock within the window passes for a match.
    static let reuseDuration = "AllowableReuseDuration"

    static func policyFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        var sites: [String: Int] = [:]
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            for (line, count) in CloudKitStructureTests.siteTally(policyName, in: code) {
                sites["\(path): \(line)", default: 0] += count
            }
            if CloudKitStructureTests.constructorScanCopies(code).contains(where: { CloudKitStructureTests.hits(policyBuilt, in: $0) }) {
                failures.append("\(path) builds an LAPolicy — the policy is named, never built (CL-3)")
            }
            if code.contains(reuseDuration) {
                failures.append("\(path) names a reuse duration — a recent unlock is not a match (CL-3)")
            }
        }
        if sites != ["\(gateFile): \(policyLine)": 1] {
            failures.append("the biometric policy is named once, as the gate's policy (CL-3): found \(sites)")
        }
        return failures
    }

    @Test func thePolicyIsNamedOnceAndNeverBuilt() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.gateFile }, "vacuity: the gate is where the policy is pinned")
        #expect(Self.policyFailures(app).isEmpty, "\(Self.policyFailures(app))")
        let gate = Self.gateFile
        let carrier = "\(Self.appDir)/Live/LocalAuthenticationMatch.swift"
        let mutants: [(String, [Source])] = [
            // The security review's B1 and B2, as planted.
            ("B1: the policy built from a raw value (the passcode's)", Self.mutate(app, gate) {
                $0.replacingOccurrences(of: Self.policyLine, with: "static let policy = LAPolicy(rawValue: 2)!") }),
            ("B2: a reuse duration on the confirming context", Self.mutate(app, gate) {
                $0.replacingOccurrences(of: "        context.localizedFallbackTitle = \"\"\n",
                                        with: "        context.localizedFallbackTitle = \"\"\n"
                                            + "        context.touchIDAuthenticationAllowableReuseDuration = 300\n") }),
            ("the init spelling", Self.mutate(app, carrier) { $0 + "\nlet spare = LAPolicy.init(rawValue: 2)" }),
            ("a spaced construction", Self.mutate(app, carrier) { $0 + "\nlet spare = LAPolicy (rawValue: 2)" }),
            ("a backticked construction", Self.mutate(app, carrier) { $0 + "\nlet spare = `LAPolicy`(rawValue: 2)" }),
            ("a comment-split construction", Self.mutate(app, carrier) { $0 + "\nlet spare = LAPolicy/* x */(rawValue: 2)" }),
            ("an unapplied init", Self.mutate(app, carrier) { $0 + "\nlet spare = LAPolicy.init" }),
            ("the policy named a second time", Self.mutate(app, carrier) {
                $0 + "\nlet spare = LAPolicy.deviceOwnerAuthenticationWithBiometrics" }),
            ("the policy as an implicit member elsewhere", Self.mutate(app, carrier) {
                $0.replacingOccurrences(of: "canEvaluatePolicy(LocalAuthenticationGate.policy,",
                                        with: "canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,") }),
            ("the reuse maximum", Self.mutate(app, gate) {
                $0 + "\nlet spare = LATouchIDAuthenticationMaximumAllowableReuseDuration" }),
            ("a reuse duration set by key", Self.mutate(app, carrier) {
                $0 + "\nfunc spare(c: NSObject) { c.setValue(300, forKey: \"touchIDAuthenticationAllowableReuseDuration\") }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.policyFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // A doc comment may name what the lock bans, and a type that merely
        // begins alike is not the policy.
        #expect(Self.policyFailures(Self.mutate(app, gate) {
            $0 + "\n/// never LAPolicy(rawValue: 2), never a touchIDAuthenticationAllowableReuseDuration\nlet spare = LAPolicyNote()"
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

    /// The type's NAME, not a call shape: `let e: SoftwareEnclave = .init()`
    /// builds one without a `SoftwareEnclave(` in sight.
    static func softwareFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app where !path.hasPrefix(fixturesDir) {
            let code = CloudKitStructureTests.codeOnly(text)
            for type in softwareTypes where CloudKitStructureTests.hits(#"\b"# + type + #"\b"#, in: code) {
                failures.append("\(path) names \(type) — software keys are for fixtures and tests only")
            }
        }
        return failures
    }

    @Test func softwareKeysStayFixtures() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.softwareFile }, "vacuity: the software enclave is where the lock looks")
        #expect(Self.softwareFailures(app).isEmpty, "\(Self.softwareFailures(app))")
        for type in Self.softwareTypes {
            for plant in ["let spare = \(type)()", "let spare = \(type).init()", "let spare = \(type) ()", "let spare = `\(type)`()",
                          "let spare: \(type) = .init()", "typealias Spare = \(type)", "let spare = Optional<\(type)>.none",
                          "let spare = [\(type)]()"] {
                let mutant = Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") { $0 + "\n\(plant)" }
                #expect(!Self.softwareFailures(mutant).isEmpty, "canary '\(plant)' was NOT caught")
            }
        }
        // The security review's B8, as planted.
        let typed = Self.mutate(app, Self.inboxFile) { $0 + "\nlet spareEnclave: SoftwareEnclave = .init()" }
        #expect(typed.map { $0.text } != app.map { $0.text }, "canary 'B8' did not apply")
        #expect(!Self.softwareFailures(typed).isEmpty, "canary 'B8: a software enclave by typed implicit init' was NOT caught")
        // A doc comment may name them.
        #expect(Self.softwareFailures(Self.mutate(app, Self.inboxFile) {
            $0 + "\n/// fixtures sign with a SoftwareEnclave over a MemorySigningKeyStore and a FixedEnrollment"
        }).isEmpty)
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

    // MARK: 6. The live key wiring

    static let makeHead = "static func make(options: LaunchOptions, now: Date) -> RequestInbox {"
    /// The live keyring, whitespace collapsed.
    static let liveKeyring = "PhoneKeyring(store: KeychainSigningKeyStore.phoneKeychain, enclave: SecureEnclaveSigner(), "
        + "enrollment: LocalAuthenticationEnrollment())"
    /// In `make`: bound, then handed to the inbox the branch returns (any
    /// writer), so an unused live keyring beside a fixture one is caught.
    static let liveHandOff = NSRegularExpression.escapedPattern(for: "let keyring = \(liveKeyring) return RequestInbox(writer: ")
        + #"[^;{}]*?"# + NSRegularExpression.escapedPattern(for: ", biometrics: biometrics, keyring: keyring) }")
    static let liveParts = ["KeychainSigningKeyStore", "phoneKeychain", "SecureEnclaveSigner", "LocalAuthenticationEnrollment"]

    static func liveWiringFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        var built: [String: Int] = [:]
        for (path, text) in app {
            let count = CloudKitStructureTests.occurrences(of: liveKeyring, in: SettingsReachabilityTests.flat(text))
            if count > 0 { built[path] = count }
        }
        if built != [inboxFile: 1] {
            failures.append("the live keyring is built once, in \(inboxFile): found \(built)")
        }
        let inbox = CloudKitStructureTests.codeOnly(app.first { $0.path == inboxFile }?.text ?? "")
        if let make = CloudKitStructureTests.body(after: makeHead, in: inbox) {
            if !CloudKitStructureTests.hits(liveHandOff, in: SettingsReachabilityTests.flat(make)) {
                failures.append("RequestInbox.make must hand the live keyring to the live inbox")
            }
        } else {
            failures.append("RequestInbox.make moved (the lock would be vacuous)")
        }
        for (path, text) in app where path.hasPrefix(fixturesDir) {
            let code = CloudKitStructureTests.codeOnly(text)
            for part in liveParts where CloudKitStructureTests.hits(#"\b"# + part + #"\b"#, in: code) {
                failures.append("\(path) names \(part) — no fixture reaches a live key part")
            }
        }
        return failures
    }

    @Test func theLiveKeyringIsBuiltOnceOverTheEnclave() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.inboxFile }, "vacuity: the inbox is where the lock looks")
        #expect(app.filter { $0.path.hasPrefix(Self.fixturesDir) }.count > 1, "vacuity: the scan sees the fixtures")
        #expect(Self.liveWiringFailures(app).isEmpty, "\(Self.liveWiringFailures(app))")
        let asWritten = "            let keyring = PhoneKeyring(store: KeychainSigningKeyStore.phoneKeychain, enclave: SecureEnclaveSigner(),\n"
            + "                                       enrollment: LocalAuthenticationEnrollment())\n"
        let factory = "\nextension PhoneKeyring { static func handy() -> PhoneKeyring { PhoneKeyring(store: KeychainSigningKeyStore.phoneKeychain, "
            + "enclave: SoftwareEnclave(), enrollment: FixedEnrollment(hash: nil)) } }"
        let swapped: ([Source]) -> [Source] = {
            Self.mutate($0, Self.inboxFile) { $0.replacingOccurrences(of: asWritten, with: "            let keyring = PhoneKeyring.handy()\n") }
        }
        let fixture = "\(Self.fixturesDir)FixtureRequests.swift"
        let mutants: [(String, [Source])] = [
            // The security review's B7, as planted, and each half of it.
            ("B7: the live inbox over a software enclave via a Fixtures/ factory",
             swapped(Self.mutate(app, Self.softwareFile) { $0 + factory })),
            ("B7's inbox half: the live keyring swapped out", swapped(app)),
            ("B7's fixture half: a factory mixing the live store in", Self.mutate(app, Self.softwareFile) { $0 + factory }),
            ("a fixture keyring handed to the live inbox", Self.mutate(app, Self.inboxFile) {
                $0.replacingOccurrences(of: "biometrics: biometrics, keyring: keyring)",
                                        with: "biometrics: biometrics, keyring: FixtureRequests.keyring(.paired))") }),
            ("a second live keyring", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") { $0 + "\nlet spare = \(Self.liveKeyring)" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.liveWiringFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Each live part on its own, in any form, in a fixture.
        for (part, plant) in [("KeychainSigningKeyStore", "let spare = KeychainSigningKeyStore(calls: .securityFramework)"),
                              ("phoneKeychain", "let spare = PhoneKeyring(store: .phoneKeychain, enclave: SoftwareEnclave(), "
                                  + "enrollment: FixedEnrollment(hash: nil))"),
                              ("SecureEnclaveSigner", "let spare: SecureEnclaveSigner = .init()"),
                              ("LocalAuthenticationEnrollment", "let spare = LocalAuthenticationEnrollment.init()")] {
            let failures = Self.liveWiringFailures(Self.mutate(app, fixture) { $0 + "\n\(plant)" })
            #expect(failures.contains { $0.contains("names \(part) ") }, "canary '\(plant)' was NOT caught by name: \(failures)")
        }
        // A fixture may say what it is not, and may use the real biometric
        // gate (the fixtures do).
        #expect(Self.liveWiringFailures(Self.mutate(app, fixture) {
            $0 + "\n/// unlike KeychainSigningKeyStore.phoneKeychain, nothing here persists\nlet spare = LocalAuthenticationGate()"
        }).isEmpty)
    }
}
