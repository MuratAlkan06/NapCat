import Foundation
import Testing

/// F4 slice S-PAIR-B (#161), S-PAIR amendment 2: one biometric match signs
/// ONE answer. A context that matched is honored by the Secure Enclave
/// again and again until it is invalidated, so these locks, read from the
/// sources (no test can run the live gate or the enclave), keep it from
/// ever signing twice:
///
/// 1. A context is made only at its three pinned sites, each a local: the
///    availability check and the enrollment read (asked only whether they
///    could evaluate) and the confirmation (the one that evaluates). It is
///    evaluated in one place, and what matched leaves that place only in a
///    fresh `LocalAuthenticationMatch`, built nowhere else.
/// 2. The key is restored with that match's context in one place, the
///    enclave's `sign`, whose first act ends the match on every path out:
///    after the signature, or when nothing could be signed.
/// 3. Nothing keeps a match, a context or a key: no stored property, no
///    collection, nowhere in the app; the only property naming a context
///    is the carrier's own, which `invalidate()` empties; the enclave file
///    declares no stored property at all.
///
/// AMENDED (#166, the S-PAIR-B security review, B3-B5 and B14): lock 1 bans
/// an implicit `.init(` in the app (a context or a carrier built unnamed);
/// lock 2 pins the carrier's name to its three sites (declared, built by
/// the gate, cast to once, by the enclave's `sign`) and the reading of its
/// `context` to that one cast; lock 3 reads a held type anywhere in a
/// declaration's type (`Optional<LAContext>`, a dictionary's value, a
/// tuple), and goes beyond typed declarations: every line naming the
/// match's protocol or a value called `match` is on an allow-list, so a
/// match stored as `AnyObject`, captured by a stored closure or handed to
/// a new holder is a new site.
///
/// Each lock catches planted canaries, so none can pass vacuously.
@Suite struct MatchHygieneStructureTests {
    typealias Source = CloudKitStructureTests.Source

    static let appDir = CloudKitStructureTests.appDir
    static let gateFile = "\(appDir)/Live/LocalAuthenticationGate.swift"
    static let matchFile = "\(appDir)/Live/LocalAuthenticationMatch.swift"
    static let enclaveFile = "\(appDir)/Live/SecureEnclaveSigner.swift"

    static func app() throws -> [Source] {
        try CloudKitStructureTests.swiftFiles(under: appDir)
    }

    static func mutate(_ sources: [Source], _ path: String, _ transform: (String) -> String) -> [Source] {
        sources.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
    }

    static func code(_ app: [Source], _ path: String) -> String {
        CloudKitStructureTests.codeOnly(app.first { $0.path == path }?.text ?? "")
    }

    // MARK: 1. Where a context is made, evaluated and handed on

    static let madeHere = "let context = LAContext()"
    static let evaluation = "guard try await context.evaluatePolicy(Self.policy, localizedReason: reason) else {"
    static let handOn = "return .confirmed(LocalAuthenticationMatch(context))"

    static func contextFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app where ![gateFile, matchFile].contains(path) {
            if CloudKitStructureTests.hits(#"\bLAContext\b"#, in: CloudKitStructureTests.codeOnly(text)) {
                failures.append("\(path) names a context — only the gate and the match carrier may")
            }
        }
        let gate = code(app, gateFile)
        let carrier = code(app, matchFile)
        failures += CloudKitStructureTests.siteFailures(#"\bLAContext\s*(?:\.\s*init\s*)?\("#, in: gate, file: gateFile,
                                                       allowed: [madeHere: 2], rule: "a context is made as a local, twice here")
        failures += CloudKitStructureTests.siteFailures(#"\bLAContext\s*(?:\.\s*init\s*)?\("#, in: carrier, file: matchFile,
                                                       allowed: [madeHere: 1], rule: "the enrollment read makes one local context")
        failures += CloudKitStructureTests.siteFailures(#"\bevaluatePolicy\b"#, in: gate, file: gateFile, allowed: [evaluation: 1],
                                                       rule: "a context is evaluated in one place")
        for (path, text) in app {
            let built = CloudKitStructureTests.matchCount(#"\bLocalAuthenticationMatch\s*(?:\.\s*init\s*)?\("#,
                                                          in: CloudKitStructureTests.codeOnly(text))
            if built != (path == gateFile ? 1 : 0) {
                failures.append("\(path) builds a match carrier \(built) time(s) — only the confirmation, once")
            }
            if path != gateFile, CloudKitStructureTests.hits(#"\bevaluatePolicy\b"#, in: CloudKitStructureTests.codeOnly(text)) {
                failures.append("\(path) evaluates a context — only the gate's confirmation may")
            }
        }
        // #166: `let c: LAContext = .init()` makes one unnamed.
        failures += RecordPathStructureTests.implicitInitFailures(app, rule: "a context and its carrier are made by name only")
        guard let confirm = CloudKitStructureTests.body(after: "func confirm(reason: String) async -> BiometricResult {", in: gate) else {
            return failures + ["the gate's confirm moved (the lock would be vacuous)"]
        }
        for line in [madeHere, evaluation, handOn] where !confirm.contains(line) {
            failures.append("the confirmation lost '\(line)'")
        }
        return failures
    }

    @Test func aContextIsMadeEvaluatedAndHandedOnInOnePlace() throws {
        let app = try Self.app()
        #expect(Self.contextFailures(app).isEmpty, "\(Self.contextFailures(app))")
        let gate = Self.gateFile
        let mutants: [(String, [Source])] = [
            ("one context for every answer", Self.mutate(app, gate) {
                $0.replacingOccurrences(of: "    func confirm(reason: String) async -> BiometricResult {\n        let context = LAContext()\n",
                                        with: "    let shared = LAContext()\n    func confirm(reason: String) async -> BiometricResult {\n"
                                            + "        let context = shared\n") }),
            ("a second evaluation", Self.mutate(app, gate) {
                $0 + "\nfunc spare(c: LAContext) async throws -> Bool { try await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, "
                    + "localizedReason: \"x\") }" }),
            ("a carrier built elsewhere", Self.mutate(app, "\(Self.appDir)/Model/RequestInbox.swift") {
                $0 + "\nlet spare = LocalAuthenticationMatch.init(c)" }),
            ("a context named in the inbox", Self.mutate(app, "\(Self.appDir)/Model/RequestInbox.swift") {
                $0 + "\nfunc spare(c: LAContext) {}" }),
            ("the evaluated context handed on bare", Self.mutate(app, gate) {
                $0.replacingOccurrences(of: Self.handOn, with: "return .confirmed(Spare(context))") }),
            // #166: by typed implicit init (the security review's B6 shape).
            ("a third context by typed implicit init", Self.mutate(app, gate) {
                $0 + "\nfunc spare() -> Bool { let c: LAContext = .init(); return c.biometryType == .none }" }),
            ("a second carrier by typed implicit init", Self.mutate(app, gate) {
                $0 + "\nfunc spare(c: LAContext) -> BiometricResult { let m: LocalAuthenticationMatch = .init(c); return .confirmed(m) }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.contextFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 2. Restored with that context, once; the match ends after

    static let signHead = "func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome {"
    static let signBody = "defer { match.invalidate() } "
        + "guard match.isValid, let context = (match as? LocalAuthenticationMatch)?.context else { return .notAuthorized } "
        + "do { let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: context) "
        + "return .signed(try key.signature(for: SHA256.hash(data: message)).rawRepresentation) } "
        + "catch { return Self.outcome(of: error) }"

    /// The enclave's one unwrapping of the carrier: its one cast to
    /// `LocalAuthenticationMatch`, and the one read of its context.
    static let unwrap = "guard match.isValid, let context = (match as? LocalAuthenticationMatch)?.context else { return .notAuthorized }"
    /// Every site naming the carrier (#166): its declaration, the gate's
    /// hand-on, the enclave's unwrapping.
    static let carrierSites = CloudKitStructureTests.appSites([
        "Live/LocalAuthenticationMatch.swift": ["final class LocalAuthenticationMatch: BiometricMatch {": 1],
        "Live/LocalAuthenticationGate.swift": [handOn: 1],
        "Live/SecureEnclaveSigner.swift": [unwrap: 1],
    ])
    /// Every member access named `context` (#166): the enclave's unwrapping
    /// and the carrier's own init.
    static let contextReadSites = CloudKitStructureTests.appSites([
        "Live/SecureEnclaveSigner.swift": [unwrap: 1],
        "Live/LocalAuthenticationMatch.swift": ["self.context = context": 1],
    ])

    /// AMENDED (#166, the S-PAIR-B security review's B3 and B14): the
    /// carrier is cast to, and its context read, in the enclave's `sign`
    /// only. A cast in the inbox read the matched context (B14) and stored
    /// it as `AnyObject` (B3), and no lock saw it. So the carrier's NAME is
    /// pinned to its three sites (a cast, `is`, a typealias or a parameter
    /// anywhere else is a new site), and every member access named
    /// `context` to the unwrapping (and the carrier's init), in every scan
    /// copy (a backticked member is one too).
    static func restoreFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let uses = CloudKitStructureTests.matchCount(#"\bauthenticationContext\b"#, in: CloudKitStructureTests.codeOnly(text))
            if uses != (path == enclaveFile ? 1 : 0) {
                failures.append("\(path) hands a context to a key \(uses) time(s) — only the enclave's sign, once")
            }
        }
        let stripped = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        failures += CloudKitStructureTests.appSiteFailures(#"\bLocalAuthenticationMatch\b"#, in: stripped, allowed: carrierSites,
                                                           rule: "the carrier is declared, built by the gate and cast to by the enclave's sign only")
        for copy in CloudKitStructureTests.constructorScanCopies(stripped) {
            failures += CloudKitStructureTests.appSiteFailures(#"\.\s*context\b"#, in: copy, allowed: contextReadSites,
                                                               rule: "the matched context is read by the enclave's sign only")
        }
        failures = CloudKitStructureTests.unique(failures)
        let enclave = code(app, enclaveFile)
        guard let sign = CloudKitStructureTests.body(after: signHead, in: enclave) else {
            return failures + ["the enclave's sign moved (the lock would be vacuous)"]
        }
        if SettingsReachabilityTests.flat(sign) != signBody {
            failures.append("the enclave's sign must end the match first, restore the key with its context, sign once")
        }
        return failures
    }

    @Test func theKeyIsRestoredWithThatMatchOnce() throws {
        let app = try Self.app()
        #expect(Self.restoreFailures(app).isEmpty, "\(Self.restoreFailures(app))")
        let enclave = Self.enclaveFile
        let inbox = "\(Self.appDir)/Model/RequestInbox.swift"
        let mutants: [(String, [Source])] = [
            ("the match outlives the signature", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "        defer { match.invalidate() }\n", with: "") }),
            ("restored without the match's context", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: ", authenticationContext: context)", with: ")") }),
            ("two signatures per match", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "            return .signed(try key.signature(for: SHA256.hash(data: message)).rawRepresentation)",
                                        with: "            _ = try key.signature(for: SHA256.hash(data: message))\n"
                                            + "            return .signed(try key.signature(for: SHA256.hash(data: message)).rawRepresentation)") }),
            ("a spent match used", Self.mutate(app, enclave) {
                $0.replacingOccurrences(of: "guard match.isValid, let context", with: "guard let context") }),
            ("a context handed to a key elsewhere", Self.mutate(app, "\(Self.appDir)/Model/PhoneKeyring.swift") {
                $0 + "\nlet spare = Spare(authenticationContext: nil)" }),
            // #166: the security review's B3 and B14, as planted.
            ("B3: the matched context stashed as AnyObject from the inbox", Self.mutate(app, inbox) {
                $0 + "\nenum Stash { @MainActor static var held: AnyObject? }\nextension RequestInbox { func keep(_ m: any BiometricMatch) "
                    + "{ Stash.held = (m as? LocalAuthenticationMatch)?.context } }" }),
            ("B14: the carrier's context read outside the enclave", Self.mutate(app, inbox) {
                $0 + "\nextension RequestInbox { func peek(_ m: any BiometricMatch) -> Bool { (m as? LocalAuthenticationMatch)?.context != nil } }" }),
            // … and their neighbours: a forced cast, an `is` test, the
            // carrier through a typealias, its context read in its own file,
            // a second cast in the enclave, and a backticked member read off
            // a carrier never named.
            ("a forced cast", Self.mutate(app, inbox) { $0 + "\nfunc spare(_ m: any BiometricMatch) { _ = m as! LocalAuthenticationMatch }" }),
            ("an is test", Self.mutate(app, inbox) { $0 + "\nfunc spare(_ m: any BiometricMatch) -> Bool { m is LocalAuthenticationMatch }" }),
            ("the carrier through a typealias", Self.mutate(app, inbox) {
                $0 + "\ntypealias Carrier = LocalAuthenticationMatch\nfunc spare(_ m: any BiometricMatch) -> Bool { m is Carrier }" }),
            ("the context read in the carrier's own file", Self.mutate(app, Self.matchFile) {
                $0 + "\nextension LocalAuthenticationMatch { var spare: Bool { self.context != nil } }" }),
            ("a second cast in the enclave file", Self.mutate(app, enclave) {
                $0 + "\nextension SecureEnclaveSigner { func spare(_ m: any BiometricMatch) -> Bool { m is LocalAuthenticationMatch } }" }),
            ("a backticked member", Self.mutate(app, inbox) { $0 + "\nfunc spare(_ c: Spare) -> Bool { c.`context` != nil }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.restoreFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a doc comment naming the shapes, and members
        // that only begin with "context".
        #expect(Self.restoreFailures(Self.mutate(app, inbox) {
            $0 + "\n/// never (m as? LocalAuthenticationMatch)?.context outside the enclave"
                + "\nfunc spare(v: Spare) -> Bool { v.contextMenu == v.contextual }"
        }).isEmpty)
    }

    // MARK: 3. Nothing keeps a match, a context or a key

    /// A stored or collected match, carrier, context or key handle: a
    /// declaration typed with one, or a collection of them. AMENDED (#166,
    /// the security review's B4, `var c: Optional<LAContext>`): the held
    /// type anywhere in the declaration's type (a generic argument, a
    /// dictionary's value, a tuple, a closure's result), and a collection or
    /// generic of them built untyped (`[String: LAContext]()`,
    /// `Optional<any BiometricMatch>.none`).
    static let kept: String = {
        let held = #"(?:any\s+)?(?:BiometricMatch|LocalAuthenticationMatch|LAContext)\b"#
        return #"\b(?:var|let)\s+\w+\s*:[^=;{}\n]*?\b(?:BiometricMatch|LocalAuthenticationMatch|LAContext|"#
            + #"SecureEnclave\s*\.\s*P256\s*\.\s*Signing\s*\.\s*PrivateKey)\b"#
            + #"|\[\s*"# + held + #"|\[[^\[\]\n]*:\s*"# + held + #"|<\s*"# + held + #"|<[^<>\n]*,\s*"# + held
    }()
    static let carrierProperty = "private(set) var context: LAContext?"

    /// Every site naming the match's protocol (#166): its declaration, the
    /// carrier's adoption, the confirmation's payload, and the parameter of
    /// each function a match passes through on its one path to the
    /// enclave: the inbox's and the ceremony's sends, the signer, the
    /// keyring's two signatures and the enclave seam's (declared, live,
    /// software).
    static let matchTypeSites = CloudKitStructureTests.appSites([
        "Model/SigningKey.swift": ["protocol BiometricMatch: AnyObject, Sendable {": 1, enclaveSeamSign: 1],
        "Model/BiometricGate.swift": ["case confirmed(any BiometricMatch)": 1],
        "Live/LocalAuthenticationMatch.swift": ["final class LocalAuthenticationMatch: BiometricMatch {": 1],
        "Live/SecureEnclaveSigner.swift": [signHead: 1],
        "Fixtures/SoftwareEnclave.swift": [signHead: 1],
        "Model/PhoneKeyring.swift": [keyringSign: 1, keyringSignProvisional: 1],
        "Model/DecisionSigner.swift": ["match: any BiometricMatch) -> Outcome {": 1],
        "Model/RequestInbox.swift": [inboxSend: 1],
        "Model/PairingCeremony.swift": [ceremonyResponse: 1],
    ])
    static let enclaveSeamSign = "func sign(_ message: [UInt8], with keyData: Data, match: any BiometricMatch) -> SigningOutcome"
    static let keyringSign = "func sign(_ message: [UInt8], match: any BiometricMatch) -> Signing {"
    static let keyringSignProvisional = "func signProvisional(_ message: [UInt8], match: any BiometricMatch) -> SigningOutcome {"
    static let inboxSend = "private func send(_ verdict: ApprovalWire.Verdict, for id: PromptID, match: any BiometricMatch) async {"
    static let ceremonyResponse = "static func response(nonce: [UInt8], publicKey: [UInt8], keyring: PhoneKeyring, match: any BiometricMatch) "
        + "-> PairingResponse? {"

    /// Every line naming a value called `match` (#166): where each match is
    /// taken from a confirmation, handed on, checked, spent and signed
    /// with; nowhere else. (The status line's `match` is the biometric's
    /// NAME, a string; and two lines of copy say "match": a word in a
    /// string counts, so reword it or list its line here.)
    static let matchWordSites = CloudKitStructureTests.appSites([
        "Model/SigningKey.swift": [enclaveSeamSign: 1],
        "Live/SecureEnclaveSigner.swift": [signHead: 1, "defer { match.invalidate() }": 1, unwrap: 2],
        "Fixtures/SoftwareEnclave.swift": [signHead: 1, "defer { match.invalidate() }": 1, "guard match.isValid else { return .notAuthorized }": 1],
        "Model/PhoneKeyring.swift": [keyringSign: 1, keyringSignProvisional: 1, "match.invalidate()": 2,
                                     "switch enclave.sign(message, with: key.keyData, match: match) {": 2,
                                     "return enclave.sign(message, with: key.keyData, match: match)": 2],
        "Model/DecisionSigner.swift": ["match: any BiometricMatch) -> Outcome {": 1, "match.invalidate()": 1,
                                       "switch keyring.sign(message, match: match) {": 2],
        "Model/RequestInbox.swift": ["guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason(for: verdict)) else {": 1,
                                     "await send(verdict, for: id, match: match)": 2, inboxSend: 1, "defer { match.invalidate() }": 1,
                                     "let signing = DecisionSigner.sign(verdict, for: request, at: clock(), with: keyring, match: match)": 2],
        "Model/PairingCeremony.swift": ["guard case .confirmed(let match) = await biometrics.confirm(reason: Self.reason) else {": 1,
                                        "match.invalidate()": 2, ceremonyResponse: 1,
                                        "guard let response = Self.response(nonce: nonce, publicKey: publicKey, keyring: keyring, match: match) else {": 2,
                                        "guard case .signed(let proof) = keyring.signProvisional(proofMessage, match: match) else { return nil }": 2],
        "Model/RequestStatus.swift": ["let match = biometric?.name ?? \"the biometric match\"": 2,
                                      "return PhoneLine(text: \"Confirming — \\(Self.name(verdict)), waiting for \\(match)\", severity: .nominal)": 1],
        "Screen/PairingScreen.swift": [
            "nonisolated static let compareHint = \"Your Mac shows a code too. If the two match, confirm on your Mac, then here. \"": 1,
            "return PhoneLine(text: \"Confirming — waiting for \\(biometry.kind?.name ?? \"the biometric match\")\", severity: .nominal)": 1],
    ])

    static func keptFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            let allowed: [String: Int] = path == matchFile ? [carrierProperty: 1] : [:]
            failures += CloudKitStructureTests.siteFailures(kept, in: code, file: path, allowed: allowed,
                                                           rule: "nothing keeps a match, a context or a key")
        }
        let stripped = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        failures += CloudKitStructureTests.appSiteFailures(#"\bBiometricMatch\b"#, in: stripped, allowed: matchTypeSites,
                                                           rule: "a match goes only along its one path, to no new holder")
        failures += CloudKitStructureTests.appSiteFailures(#"\bmatch\b"#, in: stripped, allowed: matchWordSites,
                                                           rule: "a match is used only where it is handed on, checked, spent or signed with")
        let carrier = code(app, matchFile)
        if !SettingsReachabilityTests.flat(carrier).contains("func invalidate() { context?.invalidate() context = nil }") {
            failures.append("the carrier must invalidate its context and let go of it")
        }
        let stored = CloudKitStructureTests.siteTally(#"(?m)^    (?:\w+ )*(?:var|let) "#, in: code(app, enclaveFile))
        if stored != ["var isAvailable: Bool { SecureEnclave.isAvailable }": 1,
                      "nonisolated static let notAuthorizedCodes: Set<Int> = [": 1] {
            failures.append("the enclave file declares a property beyond its two fixed ones: \(stored)")
        }
        return failures
    }

    @Test func nothingKeepsAMatchAContextOrAKey() throws {
        let app = try Self.app()
        #expect(app.contains { $0.path == Self.matchFile }, "vacuity: the carrier is where the lock looks")
        #expect(Self.keptFailures(app).isEmpty, "\(Self.keptFailures(app))")
        let inbox = "\(Self.appDir)/Model/RequestInbox.swift"
        let mutants: [(String, [Source])] = [
            ("the inbox keeps the last match", Self.mutate(app, inbox) { $0 + "\nextension RequestInbox { static var last: (any BiometricMatch)? }" }),
            ("a match kept by type", Self.mutate(app, inbox) { $0 + "\nfinal class Spare { var match: any BiometricMatch }" }),
            ("matches collected", Self.mutate(app, inbox) { $0 + "\nfinal class Spare { var all = [any BiometricMatch]() }" }),
            ("the gate keeps a context", Self.mutate(app, Self.gateFile) { $0 + "\nfinal class Spare { var context: LAContext? }" }),
            ("a key handle kept", Self.mutate(app, Self.enclaveFile) {
                $0.replacingOccurrences(of: "    var isAvailable: Bool { SecureEnclave.isAvailable }\n",
                                        with: "    var isAvailable: Bool { SecureEnclave.isAvailable }\n    var last: SecureEnclave.P256.Signing.PrivateKey?\n") }),
            ("the enclave keeps anything", Self.mutate(app, Self.enclaveFile) {
                $0.replacingOccurrences(of: "    var isAvailable: Bool { SecureEnclave.isAvailable }\n",
                                        with: "    var isAvailable: Bool { SecureEnclave.isAvailable }\n    let spare = Spare()\n") }),
            ("the carrier keeps its context", Self.mutate(app, Self.matchFile) {
                $0.replacingOccurrences(of: "        context?.invalidate()\n        context = nil\n", with: "        context?.invalidate()\n") }),
            // #166: the security review's B3, B4 and B5, as planted.
            ("B3: the matched context stashed as AnyObject from the inbox", Self.mutate(app, inbox) {
                $0 + "\nenum Stash { @MainActor static var held: AnyObject? }\nextension RequestInbox { func keep(_ m: any BiometricMatch) "
                    + "{ Stash.held = (m as? LocalAuthenticationMatch)?.context } }" }),
            ("B4: an Optional<LAContext> kept in the gate", Self.mutate(app, Self.gateFile) {
                $0 + "\nfinal class Spare { var c: Optional<LAContext> = nil }" }),
            ("B5: a match captured by a stored closure", Self.mutate(app, inbox) {
                $0 + "\nfinal class Later { var run: (() -> Void)? }\nextension RequestInbox { func hold(_ m: any BiometricMatch, _ l: Later) "
                    + "{ l.run = { _ = m.isValid } } }" }),
            // … and their neighbours: kept with no declaration naming it, in
            // the functions a match already passes through (the inbox's one
            // write site, the signer); and held in a dictionary, a tuple or a
            // generic, typed or not.
            ("a match captured inside the one write site", Self.mutate(app, inbox) {
                $0.replacingOccurrences(of: "        defer { match.invalidate() }\n",
                                        with: "        defer { match.invalidate() }\n        Later.run = { _ = match.isValid }\n") }),
            ("a match stored as Any by the signer", Self.mutate(app, "\(Self.appDir)/Model/DecisionSigner.swift") {
                $0.replacingOccurrences(of: "        let decidedAt = wholeSecond(now)\n",
                                        with: "        let decidedAt = wholeSecond(now)\n        Stash.any = match\n") }),
            ("contexts kept in a typed dictionary", Self.mutate(app, Self.gateFile) {
                $0 + "\nfinal class Spare { var all: [String: LAContext] = [:] }" }),
            ("contexts kept in an untyped dictionary", Self.mutate(app, Self.gateFile) { $0 + "\nfinal class Spare { var all = [String: LAContext]() }" }),
            ("a match kept in a tuple", Self.mutate(app, inbox) { $0 + "\nfinal class Spare { var pair: (Int, any BiometricMatch)? }" }),
            ("a match kept as a generic argument", Self.mutate(app, inbox) {
                $0 + "\nfinal class Spare { var box = Optional<any BiometricMatch>.none }" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keptFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls. The `kept` pattern itself never reads a match
        // as a parameter, an untyped local or a confirmation's binding, nor a
        // context made as a local. (Since #166 the lock as a whole fails a
        // NEW function taking a match, by design: a new holder is a new site
        // on the flow pins.)
        for probe in ["func spare(_ match: any BiometricMatch) { let m = match; _ = m }",
                      "guard case .confirmed(let match) = await biometrics.confirm(reason: r) else {", "let context = LAContext()",
                      "let x = a < b, y = c.count"] {
            #expect(!CloudKitStructureTests.hits(Self.kept, in: probe), "'kept' over-matches '\(probe)'")
        }
        // A doc comment may name the shapes, and words that only contain
        // "match" pass.
        #expect(Self.keptFailures(Self.mutate(app, inbox) {
            $0 + "\n/// never var m: any BiometricMatch, never Stash.held = match, never var c: Optional<LAContext>"
                + "\nlet matches = 1, matched = 2, rematch = 3, BiometricMatches = 4"
        }).isEmpty)
    }
}
