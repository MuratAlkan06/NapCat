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

    static func restoreFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let uses = CloudKitStructureTests.matchCount(#"\bauthenticationContext\b"#, in: CloudKitStructureTests.codeOnly(text))
            if uses != (path == enclaveFile ? 1 : 0) {
                failures.append("\(path) hands a context to a key \(uses) time(s) — only the enclave's sign, once")
            }
        }
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
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.restoreFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: 3. Nothing keeps a match, a context or a key

    /// A stored or collected match, carrier, context or key handle: a
    /// declaration typed with one, or a collection of them.
    static let kept = #"\b(?:var|let)\s+\w+\s*:\s*[\[(]?\s*(?:any\s+)?(?:BiometricMatch|LocalAuthenticationMatch|LAContext|"#
        + #"SecureEnclave\s*\.\s*P256\s*\.\s*Signing\s*\.\s*PrivateKey)\b|\[\s*(?:any\s+)?(?:BiometricMatch|LocalAuthenticationMatch|"#
        + #"LAContext)\b"#
    static let carrierProperty = "private(set) var context: LAContext?"

    static func keptFailures(_ app: [Source]) -> [String] {
        var failures: [String] = []
        for (path, text) in app {
            let code = CloudKitStructureTests.codeOnly(text)
            let allowed: [String: Int] = path == matchFile ? [carrierProperty: 1] : [:]
            failures += CloudKitStructureTests.siteFailures(kept, in: code, file: path, allowed: allowed,
                                                           rule: "nothing keeps a match, a context or a key")
        }
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
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.keptFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a match as a parameter or a local passes.
        #expect(Self.keptFailures(Self.mutate(app, inbox) {
            $0 + "\nfunc spare(_ match: any BiometricMatch) { let m = match; _ = m }"
        }).isEmpty)
    }
}
