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
///    and handed to the live inbox there (and, since S-PAIR-C1.6, to the
///    live pairing made there alone); no file under Fixtures/ names a live
///    key part or the live pairing, so no fixture can mix one with a
///    software key.
///
/// 7. (S-PAIR-C1.6, #172, N-25) The one signing line: a failed biometric
///    evaluation, key making, restore or signature is logged on ONE fixed
///    public line (`SigningFailureLog`), naming a domain from its closed
///    table and a number, nothing else; it is reached from the gate's and
///    the enclave's catches alone, and nothing else in those files logs.
///
/// AMENDED (#166, the S-PAIR-B security review): lock 4 also bans software
/// keys by SHAPE: outside Fixtures/, each key seam (the enclave, the store,
/// the enrollment) is adopted by its one live conformer only, however the
/// adoption is spelled; and locks 1 and 6, which count constructions, ban
/// an implicit `.init(` anywhere in the app.
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
        // #166: `let p: LAPolicy = .init(rawValue: 2)!` builds one unnamed.
        failures += RecordPathStructureTests.implicitInitFailures(app, rule: "the policy is named, never built (CL-3)")
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
            // #166: built by a typed implicit init, or as an argument.
            ("a policy by typed implicit init", Self.mutate(app, carrier) { $0 + "\nlet spare: LAPolicy = .init(rawValue: 2)!" }),
            ("a policy by implicit init as an argument", Self.mutate(app, carrier) {
                $0.replacingOccurrences(of: "canEvaluatePolicy(LocalAuthenticationGate.policy,", with: "canEvaluatePolicy(.init(rawValue: 2)!,") }),
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
    /// AMENDED (S-PAIR-C1.6, #172, N-25): made in a `do`, so a failure is
    /// logged on the one signing line.
    static let makeLine = "let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)"
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

    /// Each key seam's one adoption outside Fixtures/ (#166): its live
    /// conformer's declaration, in its live file.
    static let seamAdoptions: [(seam: String, file: String, line: String)] = [
        ("SigningEnclave", enclaveFile, "struct SecureEnclaveSigner: SigningEnclave {"),
        ("SigningKeyStore", keychainFile, "struct KeychainSigningKeyStore: SigningKeyStore {"),
        ("EnrollmentState", "\(appDir)/Live/LocalAuthenticationMatch.swift", "struct LocalAuthenticationEnrollment: EnrollmentState {"),
    ]

    /// The type's NAME, not a call shape: `let e: SoftwareEnclave = .init()`
    /// builds one without a `SoftwareEnclave(` in sight.
    ///
    /// AMENDED (#166): and the type's SHAPE, not only the three known names.
    /// Outside Fixtures/, a key seam is adopted only by its live conformer,
    /// on its pinned line: any other type, extension, refining protocol or
    /// typealias adopting one (over any number of lines, in every scan
    /// copy) is a software key by another name.
    ///
    /// AMENDED (#168, the PR #167 review's (c)): a seam's other names — a
    /// typealias of it or a protocol refining it, declared in ANY file,
    /// Fixtures/ included (`CloudKitStructureTests.seamNames`) — are scanned
    /// like the seam: outside Fixtures/, nothing adopts one. (A fixture alias
    /// adopted by a live type was a software key no scan read.)
    ///
    /// AMENDED (the S-PAIR-C1 security review's R2): and inside Fixtures/, a
    /// key seam is adopted only by a type nothing inherits from
    /// (`CloudKitStructureTests.fixtureConformerFailures`) — a live subclass
    /// of a fixture class was a software key with no seam in its clause.
    static func softwareFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let aliases = seamAdoptions.flatMap { CloudKitStructureTests.seamNames($0.seam, in: app).subtracting([$0.seam]) }.sorted()
        for (path, text) in app where !path.hasPrefix(fixturesDir) {
            for alias in aliases
            where CloudKitStructureTests.constructorScanCopies(CloudKitStructureTests.codeOnly(text))
                .contains(where: { CloudKitStructureTests.hits(CloudKitStructureTests.adoptionPattern(alias), in: $0) }) {
                failures.append("\(path) adopts \(alias), another name for a key seam — a software key's shape; only fixtures may")
            }
            let code = CloudKitStructureTests.codeOnly(text)
            for type in softwareTypes where CloudKitStructureTests.hits(#"\b"# + type + #"\b"#, in: code) {
                failures.append("\(path) names \(type) — software keys are for fixtures and tests only")
            }
            for (seam, file, line) in seamAdoptions {
                let allowed = path == file ? [line: 1] : [:]
                for copy in CloudKitStructureTests.constructorScanCopies(code)
                where CloudKitStructureTests.siteTally(CloudKitStructureTests.adoptionPattern(seam), in: copy) != allowed {
                    failures.append("\(path) adopts \(seam) beyond its live conformer — a software key's shape; only fixtures (and tests) may")
                }
            }
        }
        // The S-PAIR-C1 security review's R2: and no fixture conformer a live
        // class could inherit a key seam from.
        for (seam, _, _) in seamAdoptions {
            failures += CloudKitStructureTests.fixtureConformerFailures(seam, in: app)
        }
        return CloudKitStructureTests.unique(failures)
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
        // #166: a software key by another name, by its shape: each seam
        // adopted outside Fixtures/ by a new type, an extension, over lines,
        // through a refining protocol or a typealias, behind a block comment
        // holding a brace, or a second conformer in a live file.
        let keyring = "\(Self.appDir)/Model/PhoneKeyring.swift"
        let shapes: [(String, String, String)] = [
            ("a new enclave", keyring, "struct SpareEnclave: SigningEnclave { var isAvailable: Bool { true } "
                + "func makeKey() -> MadeKey? { nil } func sign(_ m: [UInt8], with k: Data, match: any BiometricMatch) -> SigningOutcome { .keyUnusable } }"),
            ("an enclave by extension", keyring, "extension PhoneKeyring: SigningEnclave {}"),
            ("an enclave over lines", Self.inboxFile, "final class SpareEnclave:\n    NSObject,\n    SigningEnclave {}"),
            ("an enclave through a refining protocol", Self.inboxFile, "protocol SoftEnclave: SigningEnclave {}"),
            ("an enclave through a typealias", Self.inboxFile, "typealias Enclave = SigningEnclave"),
            ("an enclave behind a block comment holding a brace", Self.inboxFile, "struct SpareEnclave /* { */: SigningEnclave {}"),
            ("a second enclave in the live file", Self.enclaveFile, "struct SpareEnclave: SigningEnclave {}"),
            ("an in-memory store", keyring, "final class SpareStore: SigningKeyStore, @unchecked Sendable {}"),
            ("a store over lines", Self.inboxFile, "struct SpareStore:\n    SigningKeyStore {}"),
            ("a fixed enrollment", keyring, "struct SpareEnrollment: EnrollmentState { func current() -> Data? { nil } }"),
            ("an enrollment through a typealias", Self.inboxFile, "typealias Hash = EnrollmentState"),
        ]
        for (name, path, plant) in shapes {
            let mutant = Self.mutate(app, path) { $0 + "\n\(plant)" }
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.softwareFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // #168 (the PR #167 review's (c)), the review's G7 shape: an alias of
        // a key seam declared in Fixtures/, adopted by a live type — and a
        // refining protocol there, and an alias of an alias.
        let fixture = Self.softwareFile
        let aliasShapes: [(String, [Source])] = [
            ("G7: a fixture alias of the store adopted by a live type", Self.mutate(Self.mutate(app, fixture) {
                $0 + "\ntypealias ReviewerStoreSeam = SigningKeyStore" }, keyring) {
                $0 + "\nstruct ReviewerMemoryStore: ReviewerStoreSeam {\n    func read(_ slot: KeySlot) -> SigningKeyRead { .notFound }\n}" }),
            ("a fixture protocol refining the enclave, adopted live", Self.mutate(Self.mutate(app, fixture) {
                $0 + "\nprotocol SoftSigning: SigningEnclave {}" }, Self.inboxFile) { $0 + "\nstruct SpareEnclave: SoftSigning {}" }),
            ("an alias of a fixture alias, adopted live", Self.mutate(Self.mutate(app, fixture) {
                $0 + "\ntypealias Hash = EnrollmentState\ntypealias Hash2 = Hash" }, keyring) { $0 + "\nextension PhoneKeyring: Hash2 {}" }),
            // The S-PAIR-C1 security review's R2: its P4, as planted — a
            // fixture CLASS conforming to the key store, subclassed live —
            // and the class route's neighbours: the fixture store made
            // subclassable, a fixture extension handing the enrollment seam
            // to a class a live one subclasses, and a plain class adopting
            // the enclave through a fixture refining protocol.
            ("P4: a fixture class conforming to the key store, subclassed live", Self.mutate(Self.mutate(app, fixture) {
                $0 + "\nclass ReviewerFixtureStore: SigningKeyStore, @unchecked Sendable {}" }, keyring) {
                $0 + "\nfinal class ReviewerLiveStore: ReviewerFixtureStore, @unchecked Sendable {}" }),
            ("the fixture store made subclassable", Self.mutate(app, fixture) {
                $0.replacingOccurrences(of: "final class MemorySigningKeyStore: SigningKeyStore,", with: "class MemorySigningKeyStore: SigningKeyStore,") }),
            ("the enrollment seam handed to a fixture class by an extension, subclassed live", Self.mutate(Self.mutate(app, fixture) {
                $0 + "\nclass SpareBase {}\nextension SpareBase: EnrollmentState {\n    func current() -> Data? { nil }\n}" }, keyring) {
                $0 + "\nfinal class SpareLive: SpareBase {}" }),
            ("a plain fixture class adopting a fixture protocol refining the enclave", Self.mutate(app, fixture) {
                $0 + "\nprotocol SpareSigning: SigningEnclave {}\nclass SpareBase: SpareSigning {}" }),
        ]
        for (name, mutant) in aliasShapes {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.softwareFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // A fixture may still name a seam another way, and use it there.
        #expect(Self.softwareFailures(Self.mutate(app, fixture) {
            $0 + "\ntypealias FixtureStore = SigningKeyStore\nstruct SpareFixtureStore: FixtureStore {}"
        }).isEmpty)
        // R2's over-match controls: fixture key seams in every shape nothing
        // inherits from, a protocol extension (no adoption), and a plain
        // fixture class that adopts no seam.
        #expect(Self.softwareFailures(Self.mutate(app, fixture) {
            $0 + "\nfinal class SpareA: SigningKeyStore, @unchecked Sendable {}"
                + "\nfinal public class SpareB:\n    SigningEnclave, @unchecked Sendable {}"
                + "\nenum SpareC: EnrollmentState {}\nactor SpareD: EnrollmentState {}"
                + "\nextension SigningKeyStore where Self: Sendable {}\nclass SpareHelper: NSObject {}"
        }).isEmpty)
        // The live conformer renamed in its own file is a new shape too.
        #expect(!Self.softwareFailures(Self.mutate(app, Self.enclaveFile) {
            $0.replacingOccurrences(of: "struct SecureEnclaveSigner: SigningEnclave {", with: "struct SoftSigner: SigningEnclave {")
        }).isEmpty, "canary 'the live enclave's conformer renamed' was NOT caught")
        // A doc comment may name them, a fixture may adopt the seams (they
        // do), and a seam as a parameter or a stored existential (the
        // keyring's own) adopts nothing.
        #expect(Self.softwareFailures(Self.mutate(app, Self.inboxFile) {
            $0 + "\n/// fixtures sign with a SoftwareEnclave over a MemorySigningKeyStore and a FixedEnrollment"
                + "\n/// never struct X: SigningEnclave here\nfunc spare(e: any SigningEnclave, s: any SigningKeyStore) -> Bool { true }"
        }).isEmpty)
        #expect(Self.softwareFailures(Self.mutate(app, Self.softwareFile) {
            $0 + "\nstruct SpareFixtureEnclave:\n    SigningEnclave { var isAvailable: Bool { false } "
                + "func makeKey() -> MadeKey? { nil } func sign(_ m: [UInt8], with k: Data, match: any BiometricMatch) -> SigningOutcome { .keyUnusable } }"
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
    /// AMENDED (S-PAIR-C1.6, #172): and to the live pairing made there, the
    /// same local, so the key a pairing commits is the key the inbox signs
    /// with, and no pairing is made over a fixture key. The live pairing is
    /// made there alone (`livePairingMade`), and no fixture names it.
    static let liveHandOff = NSRegularExpression.escapedPattern(for: "let keyring = \(liveKeyring) return RequestInbox(writer: ")
        + #"[^;{}]*?"# + NSRegularExpression.escapedPattern(
            for: ", biometrics: biometrics, keyring: keyring, pairing: LivePairing.make(keyring: keyring, biometrics: biometrics)) }")
    static let livePairingMade = CloudKitStructureTests.appSites([
        "Model/RequestInbox.swift": ["pairing: LivePairing.make(keyring: keyring, biometrics: biometrics))": 1]])
    static let liveParts = ["KeychainSigningKeyStore", "phoneKeychain", "SecureEnclaveSigner", "LocalAuthenticationEnrollment",
                            "LivePairing"]

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
        // #166: `let k: PhoneKeyring = .init(store: …)` builds one unnamed.
        failures += RecordPathStructureTests.implicitInitFailures(app, rule: "the live keyring is built once, by name, in RequestInbox.make")
        failures += CloudKitStructureTests.appSiteFailures(#"\bLivePairing\s*\.\s*make\b"#,
                                                           in: app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) },
                                                           allowed: livePairingMade, rule: "the live pairing is made once, over the live keyring")
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
                $0.replacingOccurrences(of: "biometrics: biometrics, keyring: keyring,",
                                        with: "biometrics: biometrics, keyring: FixtureRequests.keyring(.paired),") }),
            ("a second live keyring", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") { $0 + "\nlet spare = \(Self.liveKeyring)" }),
            // #166: a second live keyring by typed implicit init.
            ("a second live keyring by typed implicit init", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nlet spare: PhoneKeyring = .init(store: KeychainSigningKeyStore.phoneKeychain, enclave: SecureEnclaveSigner(), "
                    + "enrollment: LocalAuthenticationEnrollment())" }),
            // S-PAIR-C1.6 (#172): the live pairing rides the live keyring.
            ("the live pairing over a fixture keyring", Self.mutate(app, Self.inboxFile) {
                $0.replacingOccurrences(of: "pairing: LivePairing.make(keyring: keyring,",
                                        with: "pairing: LivePairing.make(keyring: FixtureRequests.keyring(.paired),") }),
            ("the live pairing left out of the live inbox", Self.mutate(app, Self.inboxFile) {
                $0.replacingOccurrences(of: ", keyring: keyring,\n                                pairing: LivePairing.make(keyring: keyring, biometrics: biometrics))",
                                        with: ", keyring: keyring)") }),
            ("a second live pairing", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nlet spare = LivePairing.make(keyring: k, biometrics: g)" }),
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
                              ("LocalAuthenticationEnrollment", "let spare = LocalAuthenticationEnrollment.init()"),
                              ("LivePairing", "let spare = LivePairing.make(keyring: k, biometrics: g)")] {
            let failures = Self.liveWiringFailures(Self.mutate(app, fixture) { $0 + "\n\(plant)" })
            #expect(failures.contains { $0.contains("names \(part) ") }, "canary '\(plant)' was NOT caught by name: \(failures)")
        }
        // A fixture may say what it is not, and may use the real biometric
        // gate (the fixtures do).
        #expect(Self.liveWiringFailures(Self.mutate(app, fixture) {
            $0 + "\n/// unlike KeychainSigningKeyStore.phoneKeychain, nothing here persists\nlet spare = LocalAuthenticationGate()"
        }).isEmpty)
    }

    // MARK: 7. The one signing line (S-PAIR-C1.6, #172, N-25)

    static let logFile = "\(appDir)/Live/SigningFailureLog.swift"
    static let matchFile = "\(appDir)/Live/LocalAuthenticationMatch.swift"
    static let logDeclaration = "private static let logger = Logger(subsystem: \"com.muratalkan.napcat.phone\", category: \"signing\")"
    /// THE line, as written: the closed domain's raw value and the code,
    /// each public, and no other interpolation.
    static let logLine = #"logger.error("biometric or enclave operation failed (domain \(domain.rawValue, privacy: .public), "#
        + #"code \(code, privacy: .public))")"#
    static let recordHead = "static func record(_ error: any Error) {"
    static let recordBody = "let (domain, code) = Self.reading(error) " + logLine
    static let readingHead = "static func reading(_ error: any Error) -> (domain: Domain, code: Int) {"
    static let readingBody = "if case CryptoKitError.underlyingCoreCryptoError(let status) = error { return (.coreCrypto, Int(status)) } "
        + "let nsError = error as NSError if error is CryptoKitError { return (.cryptoKit, nsError.code) } "
        + "switch nsError.domain { case LAError.errorDomain: return (.localAuthentication, nsError.code) "
        + "case NSOSStatusErrorDomain: return (.osStatus, nsError.code) default: return (.other, nsError.code) }"
    /// The line is reached from these catches alone: the gate's evaluation,
    /// and the enclave's key making and its restore or signature.
    static let recordSites = CloudKitStructureTests.appSites([
        "Live/SigningFailureLog.swift": ["enum SigningFailureLog {": 1],
        "Live/LocalAuthenticationGate.swift": ["SigningFailureLog.record(error)": 1],
        "Live/SecureEnclaveSigner.swift": ["SigningFailureLog.record(error)": 2],
    ])
    /// Any other way to log, in the four files the line covers.
    static let otherLogging = [#"\bLogger\b"#, #"\bos_log\b"#, #"\bNSLog\b"#, #"\b(?:print|debugPrint|dump)\s*\("#,
                               #"\bOSLog\b"#, #"\bos\s*\."#, #"\bfputs\b"#, #"\bFileHandle\b"#]

    static func signingLineFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        let log = CloudKitStructureTests.codeOnly(app.first { $0.path == logFile }?.text ?? "")
        guard let record = CloudKitStructureTests.body(after: recordHead, in: log),
              let reading = CloudKitStructureTests.body(after: readingHead, in: log) else {
            return ["the signing line or its reading moved (the lock would be vacuous)"]
        }
        if SettingsReachabilityTests.flat(record) != recordBody {
            failures.append("the signing line logs the closed domain and the code, public, and nothing else — exactly as pinned")
        }
        if SettingsReachabilityTests.flat(reading) != readingBody {
            failures.append("the signing line's reading is its closed table — exactly as pinned")
        }
        failures += CloudKitStructureTests.siteFailures(#"\blogger\b"#, in: log, file: logFile,
                                                       allowed: [logDeclaration: 1, logLine: 1], rule: "one logger, one line")
        failures += CloudKitStructureTests.siteFailures(#"\bLogger\b"#, in: log, file: logFile, allowed: [logDeclaration: 1],
                                                       rule: "one logger, in the signing category")
        for pattern in otherLogging where pattern != #"\bLogger\b"# && CloudKitStructureTests.hits(pattern, in: log) {
            failures.append("'\(pattern)' in \(logFile) — the signing line is its one way to log")
        }
        for file in [gateFile, matchFile, enclaveFile] {
            let code = CloudKitStructureTests.codeOnly(app.first { $0.path == file }?.text ?? "")
            for pattern in otherLogging where CloudKitStructureTests.hits(pattern, in: code) {
                failures.append("'\(pattern)' in \(file) — a failure there is logged on the signing line alone")
            }
        }
        failures += CloudKitStructureTests.appSiteFailures(#"\bSigningFailureLog\b"#,
                                                           in: app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) },
                                                           allowed: recordSites,
                                                           rule: "the signing line is reached from the gate's and the enclave's catches alone")
        return failures
    }

    @Test func aFailedMatchOrKeyIsLoggedOnTheOneSigningLine() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.logFile }, "vacuity: the scan sees the signing line's file")
        #expect(Self.signingLineFailures(app).isEmpty, "\(Self.signingLineFailures(app))")
        let log = Self.logFile
        let mutants: [(String, [Source])] = [
            ("the error's own text logged", Self.mutate(app, log) {
                $0.replacingOccurrences(of: "code \\(code, privacy: .public))", with: "code \\(code, privacy: .public)) \\(error)") }),
            ("the domain logged raw", Self.mutate(app, log) {
                $0.replacingOccurrences(of: "domain \\(domain.rawValue, privacy: .public)",
                                        with: "domain \\((error as NSError).domain, privacy: .public)") }),
            ("the code logged private", Self.mutate(app, log) {
                $0.replacingOccurrences(of: "code \\(code, privacy: .public)", with: "code \\(code, privacy: .private)") }),
            ("any domain passed through", Self.mutate(app, log) {
                $0.replacingOccurrences(of: "        default: return (.other, nsError.code)\n",
                                        with: "        default: return (Domain(rawValue: nsError.domain) ?? .other, nsError.code)\n") }),
            ("a second line", Self.mutate(app, log) {
                $0.replacingOccurrences(of: "        let (domain, code) = Self.reading(error)\n",
                                        with: "        let (domain, code) = Self.reading(error)\n        logger.debug(\"\\(error.localizedDescription)\")\n") }),
            ("a print in the enclave", Self.mutate(app, Self.enclaveFile) {
                $0.replacingOccurrences(of: "            SigningFailureLog.record(error)\n            return Self.outcome(of: error)",
                                        with: "            print(error)\n            return Self.outcome(of: error)") }),
            ("a logger in the gate", Self.mutate(app, Self.gateFile) {
                $0 + "\nprivate let spareLog = Logger(subsystem: \"x\", category: \"y\")" }),
            ("os_log in the carrier", Self.mutate(app, Self.matchFile) { $0 + "\nfunc spare() { os_log(\"x\") }" }),
            ("the line reached from the ceremony", Self.mutate(app, "\(Self.appDir)/Model/PairingCeremony.swift") {
                $0 + "\nfunc spare(e: any Error) { SigningFailureLog.record(e) }" }),
            ("the gate's failure unlogged", Self.mutate(app, Self.gateFile) {
                $0.replacingOccurrences(of: "            SigningFailureLog.record(error)\n", with: "") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.signingLineFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a doc comment may name what the lock bans.
        #expect(Self.signingLineFailures(Self.mutate(app, Self.enclaveFile) {
            $0 + "\n/// never print(error), never a Logger here: SigningFailureLog.record(error) alone"
        }).isEmpty)
    }
}
