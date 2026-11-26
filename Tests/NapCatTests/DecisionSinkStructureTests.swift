// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S-PAIR-C2 (#181), the plan of #163: the decision sinks are
/// pinned. Design: design/remote-approvals.md, "Slice S-PAIR".
///
/// `ApprovalRecordPathStructureTests` lock 9 pins today's unsafe-memory
/// sites and every line naming the S0 type, but a token list cannot be
/// complete: a decision value can be built from raw bytes with no pinned
/// token — bytes copied into a generic slot through a C function's
/// implicit pointer conversion (`memcpy`), or through
/// `withUnsafeMutableBytes`/`copyMemory` — and the S0 type's own file and
/// the package's target list were not shape-checked. So the sinks a forged
/// value must reach are pinned instead, wherever it came from, in every
/// scan copy of `uncutSources()`:
/// a. `decide`: named at the intake's one wired call — whose argument is
///    the verifier's result for the slot as it is now — and its own
///    declaration, whose body takes a verified result alone; and at the
///    other `decide`s of the four targets, today's (the lifecycle's own and
///    two unrelated policies'). Any other call, reference or replacement
///    names it;
/// b. `remoteDecision`: the event built once, in `decide`, besides its
///    declaration and the lifecycle's one reading of it;
/// c. `.verified`: the verifier's result built once, after its signature
///    check, and read once, in `decide` (the pairing ceremony's own
///    `.verified` sites are pinned as they are); the result type is
///    exactly its two cases, so no member inside it builds one unnamed;
/// d. the S0 type's file: the type is named on its three lines, its
///    declaration is exactly its one initializer and current
///    conformances, and its signature flag sits at its four sites, the
///    lifecycle's check among them;
/// e. the package manifest, whole: the target list (each target's kind,
///    dependencies and settings), the products and the settings it names,
///    so no target outside the four scanned roots, no path or source
///    override, no package dependency and no new flag can carry code no
///    lock reads;
/// f. (with them, beyond the plan's four) the doors around the sink: the
///    intake is reached from outside the host only through `withIntake`, at
///    its one use, and its type is named at today's sites alone in the four
///    targets; the host names its intake at today's lines and binds it
///    plainly at that door (`withIntake`, pinned whole), so no extension
///    member can stand in there, and nothing in the four targets extends
///    `Optional` (by its name, its `?` or an alias declared there); inside
///    the intake every `apply` and `perform` is pinned at its sites, both
///    bodies are pinned whole, and the frame writer (`sendFrame`) is named
///    at today's sites; and the host's connection writes are pinned at
///    today's site, the connection type is named at today's sites alone in
///    the four targets, the host names its connections and its peer reader
///    at today's lines, and the seam file its send, its write and its
///    descriptor, so no new line of either file reaches a connection's
///    writer;
/// g. the road, whole: the verifier (`enum DecisionVerifier`: every check,
///    the message, the diagnostic) and the slot's `read()` are pinned as
///    they are, flattened by scalars on the compiler's whitespace alone, so
///    a line added on the road changes the pinned text unless the stripper
///    reads it as whitespace or a `//` comment — a forged result behind a
///    trigger, an event rebound before the lifecycle reads it, a reading
///    kept per handle, a statement or a name drawn as nothing. The raw-text
///    lock `LidGuardStructureTests.noSourceHoldsAScalarALockCouldReadApart`
///    keeps out of the sources the scalars a text reading drops or matches
///    to another;
/// h. the repository root holds one manifest, `Package.swift`, so no
///    version-specific manifest declares a target that e. never reads;
/// i. every `extension` header and every operator implementation in the
///    four targets is today's, so no extension member and no operator
///    overload added elsewhere takes over a pinned line (a constrained
///    extension's subscript, a concrete `??`).
///
/// These pin the sites and bodies they name, nothing more: a value forged
/// from raw bytes that reaches none of them stays #163's accepted residual,
/// and raw-memory writes into a live object stay the pairing locks'.
///
/// Each check is a pure function over the sources and catches planted
/// canaries — the issue's byte-copy forge among them, decided from a new
/// file and replanted into the wired sink itself, and the security review's
/// plants verbatim — beside over-match controls, so none can pass
/// vacuously. Each pin added after a security review catches its own
/// canary; where another pin catches it too, its test says which.
struct DecisionSinkStructureTests {
    typealias Sources = ApprovalChannelStructureTests.Sources
    typealias RecordPath = ApprovalRecordPathStructureTests

    static let wiredCall: String = RecordPath.wiredCall
    static let verifierFile: String = RecordPath.verifierFile
    static let declaringFile: String = RecordPath.declaringFile
    static let verifiedConstruction: String = RecordPath.verifiedConstruction

    static func uncutSources() throws -> Sources { try RecordPath.uncutSources() }
    static func text(_ name: String, in sources: Sources) -> String { RecordPath.text(name, in: sources) }
    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        RecordPath.mutate(sources, name, transform)
    }
    static func adding(_ sources: Sources, _ name: String, _ text: String) -> Sources { RecordPath.adding(sources, name, text) }
    static func siteFailures(_ pattern: String, in text: String, file: String, allowed: [String: Int], rule: String) -> [String] {
        RecordPath.siteFailures(pattern, in: text, file: file, allowed: allowed, rule: rule)
    }
    static func unique(_ failures: [String]) -> [String] { RecordPath.unique(failures) }
    static func hits(_ pattern: String, in text: String) -> Bool { RecordPath.hits(pattern, in: text) }

    static let decideHead: String = "func decide(_ verification: DecisionVerification) {"
    static let decideBody: String = decideHead + " guard case .verified(let decision) = verification else { return } "
        + "apply(.remoteDecision(decision), to: decision.promptID) }"
    static let wiredBody: String = "refusals: (DecisionVerifierAudit) -> Void = DecisionVerifierLog.record) { " + wiredCall + " }"
    static let lifecycleReading: String = "case .remoteDecision(let decision): return decide(decision, now: now)"
    static let lifecycleDecide: String = "private mutating func decide(_ decision: ApprovalDecision, now: Int) -> ApprovalTransition {"
    static let decideSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: [wiredCall: 1, decideHead: 1],
        declaringFile: [lifecycleReading: 1, lifecycleDecide: 1],
        "ChargeLimiter.swift": ["let command = HysteresisEngine.decide(": 1],
        "HysteresisEngine.swift": ["static func decide(": 1],
        "LidGuardController.swift": ["let decision = LidGuardPolicy.decide(inputs)": 1],
        "LidGuardPolicy.swift": ["static func decide(_ inputs: LidGuardGateInputs) -> LidGuardGateDecision {": 1],
    ]
    static let remoteDecisionSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: ["apply(.remoteDecision(decision), to: decision.promptID)": 1],
        declaringFile: ["case remoteDecision(ApprovalDecision)": 1, lifecycleReading: 1],
    ]
    /// A member access (`.verified`, the implicit or qualified case), the
    /// case declared, or the case applied unqualified (inside its type).
    static let verifiedPattern: String = #"\.\s*verified\b|\bcase\s+verified\b|\bverified\s*\("#
    static let verifiedSites: [String: [String: Int]] = [
        verifierFile: ["case verified(ApprovalDecision)": 1, verifiedConstruction: 1],
        ApprovalChannelStructureTests.intakeFile: ["guard case .verified(let decision) = verification else { return }": 1],
        PairingStructureTests.ceremonyFile: [
            "case verified(PairingCandidate)": 1, "return .verified(PairingCandidate(response: response, fingerprint: fingerprint))": 1,
            "case verified": 1, "case .verified: return \"pairing.verified\"": 2, "case .verified(let candidate):": 1,
            "return [.audit(.verified)]": 1],
    ]
    static let verificationType: String = "enum DecisionVerification: Equatable, Sendable { case verified(ApprovalDecision) "
        + "case unverified(DecisionUnverifiedReason) }"
    /// The S0 type's declaration, whole.
    static let decisionDeclaration: String = [
        "public struct ApprovalDecision: Equatable, Sendable {",
        "public let promptID: PromptID", "public let verdict: ApprovalWire.Verdict", "public let wireVersion: Int",
        "public let signatureVerified: Bool",
        "public init(promptID: PromptID, verdict: ApprovalWire.Verdict, wireVersion: Int, signatureVerified: Bool) {",
        "self.promptID = promptID", "self.verdict = verdict", "self.wireVersion = wireVersion",
        "self.signatureVerified = signatureVerified", "} }",
    ].joined(separator: " ")
    static let declaringSites: [(pattern: String, allowed: [String: Int], rule: String)] = [
        (#"\bApprovalDecision\b"#, ["public struct ApprovalDecision: Equatable, Sendable {": 1, "case remoteDecision(ApprovalDecision)": 1,
                                    lifecycleDecide: 1],
         "the S0 type is named in its file on its declaration, the event and the lifecycle's check"),
        (#"\bsignatureVerified\b"#, ["public let signatureVerified: Bool": 1,
                                     "public init(promptID: PromptID, verdict: ApprovalWire.Verdict, wireVersion: Int, signatureVerified: Bool) {": 1,
                                     "self.signatureVerified = signatureVerified": 2,
                                     "guard decision.signatureVerified else { return Self.ignored(.unauthenticated) }": 1],
         "the signature flag is the S0 type's, set by its one initializer and read by the lifecycle's check"),
    ]
    static let withIntakeSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.hostFile: ["func withIntake<Result>(_ body: (ApprovalIntake) -> Result) -> Result? {": 1],
        ApprovalChannelStructureTests.toggleFile: [
            "let tools = host.withIntake { $0.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds) } ?? []": 1],
    ]
    static let hostIntakeSites: [String: Int] = [
        "private var intake: ApprovalIntake?": 1,
        "intake = ApprovalIntake(armed: armed, secrets: secrets, newPromptID: newPromptID, now: now, records: records,": 1,
        "intake?.killSwitch()": 1, "guard let intake else { return nil }": 1, "return body(intake)": 1,
        "self?.intake?.receive($0, from: key)": 1,
        "self?.intake?.connectionClosed(key)": 1, "intake?.tick()": 1, "if intake?.holdsOpenPrompt(from: key) == true {": 1,
    ]
    static let intakeDoorSites: [String: Int] = [
        "perform(opened.transition, for: id, classified: (classification, copy))": 1,
        "func apply(_ event: ApprovalEvent, to id: PromptID) {": 1, "let transition = item.lifecycle.apply(event, now: now())": 1,
        "perform(transition, for: id)": 1, "apply(.remoteDecision(decision), to: decision.promptID)": 1,
        "if !item.lifecycle.phase.isTerminal { apply(.sessionEnded, to: id) }": 1, "apply(.killSwitch, to: id)": 1,
        "apply(.tick, to: id)": 1, "private func perform(_ transition: ApprovalTransition, for id: PromptID,": 1,
    ]

    /// `sources`: `uncutSources()`.
    static func sinkFailures(_ sources: Sources) -> [String] {
        let intake = ApprovalChannelStructureTests.intakeFile
        guard text(intake, in: sources).contains(wiredCall), text(declaringFile, in: sources).contains("struct ApprovalDecision") else {
            return ["the wired call or the S0 type is not where the sink lock looks — it would be vacuous"]
        }
        var failures: [String] = []
        for (name, uncut) in sources {
            for copy in LidGuardStructureTests.constructorScanCopies(uncut) {
                failures += siteFailures(#"\bdecide\b"#, in: copy, file: name, allowed: decideSites[name] ?? [:],
                                         rule: "decide is named at the one wired call, its declaration and today's other decides")
                failures += siteFailures(#"\bremoteDecision\b"#, in: copy, file: name, allowed: remoteDecisionSites[name] ?? [:],
                                         rule: "the remote decision event is built in decide alone")
                failures += siteFailures(verifiedPattern, in: copy, file: name, allowed: verifiedSites[name] ?? [:],
                                         rule: "the verifier's result is built once, after its check, and read once, in decide")
                failures += siteFailures(#"\bwithIntake\b"#, in: copy, file: name, allowed: withIntakeSites[name] ?? [:],
                                         rule: "the intake is reached from outside the host at withIntake's one use")
                let flat = MenuPanelStructureTests.flat(LidGuardStructureTests.codeOnly(copy))
                switch name {
                case intake:
                    if ApprovalChannelStructureTests.count(decideBody, in: flat) != 1 || ApprovalChannelStructureTests.count(wiredBody, in: flat) != 1 {
                        failures.append("decide takes a verified result alone, and its one caller hands it the verifier's — whole")
                    }
                    failures += siteFailures(#"\bapply\b|\bperform\b"#, in: copy, file: name, allowed: intakeDoorSites,
                                             rule: "inside the intake every event and every transition goes through today's doors")
                case verifierFile:
                    if ApprovalChannelStructureTests.count(verificationType, in: flat) != 1 {
                        failures.append("the verifier's result type is exactly its two cases")
                    }
                case declaringFile:
                    if ApprovalChannelStructureTests.count(decisionDeclaration, in: flat) != 1 {
                        failures.append("the S0 type is exactly its declaration: one initializer, Equatable and Sendable")
                    }
                    for (pattern, allowed, rule) in declaringSites {
                        failures += siteFailures(pattern, in: copy, file: name, allowed: allowed, rule: rule)
                    }
                case ApprovalChannelStructureTests.hostFile:
                    failures += siteFailures(#"\bintake\b"#, in: copy, file: name, allowed: hostIntakeSites,
                                             rule: "the host names its intake at today's lines")
                default:
                    break
                }
            }
        }
        return unique(failures)
    }

    /// The package manifest, comment-stripped and flattened.
    static let packageManifest: String = [
        #"import Foundation import PackageDescription"#,
        #"let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks""#,
        #"let hasCLTFrameworks = FileManager.default.fileExists(atPath: cltFrameworksPath)"#,
        #"let testSwiftSettings: [SwiftSetting] = hasCLTFrameworks ? [.unsafeFlags(["-F", cltFrameworksPath])] : []"#,
        #"let testLinkerSettings: [LinkerSetting] = hasCLTFrameworks ? [.unsafeFlags(["-F", cltFrameworksPath, "-Xlinker", "-rpath","#,
        #""-Xlinker", cltFrameworksPath])] : []"#,
        #"let package = Package( name: "NapCat", platforms: [ .macOS(.v14), .iOS(.v18), ],"#,
        #"products: [ .library(name: "NapCatWire", targets: ["NapCatWire"]), .executable(name: "napcat-channel", targets: ["NapCatChannel"]), ],"#,
        #"targets: [ .target( name: "NapCatWire" ), .executableTarget( name: "NapCat", dependencies: ["NapCatSeam", "NapCatWire"] ),"#,
        #".target( name: "NapCatSeam", dependencies: ["NapCatWire"] ),"#,
        #".executableTarget( name: "NapCatChannel", dependencies: ["NapCatSeam", "NapCatWire"] ),"#,
        #".testTarget( name: "NapCatTests", dependencies: ["NapCat", "NapCatChannel", "NapCatSeam", "NapCatWire"],"#,
        #"swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings ), ] )"#,
    ].joined(separator: " ")

    /// `manifest`: Package.swift as written.
    static func packageFailures(_ manifest: String) -> [String] {
        let code = LidGuardStructureTests.codeOnly(manifest)
        return LidGuardStructureTests.constructorScanCopies(code).contains { MenuPanelStructureTests.flat($0) != packageManifest }
            ? ["Package.swift is exactly today's targets, products and settings — no target, override, dependency or flag "
               + "outside the four scanned roots: read '\(MenuPanelStructureTests.flat(code))'"]
            : []
    }

    /// #163's motivating shape, compiled the way the issue describes it: a
    /// value's bytes copied into a generic slot through `memcpy`'s implicit
    /// pointer conversion, and through `withUnsafeMutableBytes`/`copyMemory`
    /// — no S0 name, no construction, no flag label, no pinned unsafe cast.
    static let byteForge: String = """
        import Foundation
        import NapCatWire

        func zzForge<T>(_ parts: (PromptID, ApprovalWire.Verdict, Int, Bool)) -> T {
            let slot = UnsafeMutablePointer<T>.allocate(capacity: 1)
            var parts = parts
            memcpy(slot, &parts, MemoryLayout<T>.size)
            return slot.pointee
        }

        func zzCopied<T>(_ parts: (PromptID, ApprovalWire.Verdict, Int, Bool), into slot: inout T) {
            var parts = parts
            withUnsafeMutableBytes(of: &slot) { target in withUnsafeBytes(of: &parts) { target.copyMemory(from: $0) } }
        }

        """

    @Test func theDecisionSinksArePinned() throws {
        let sources = try Self.uncutSources()
        #expect(Self.sinkFailures(sources).isEmpty, "\(Self.sinkFailures(sources))")
        let intake = ApprovalChannelStructureTests.intakeFile
        let verifier = Self.verifierFile
        let wire = Self.declaringFile
        let indented: String = "        " + Self.wiredCall + "\n"
        let guarded: String = "guard case .verified(let decision) = verification else { return }"
        let declared: String = "public struct ApprovalDecision: Equatable, Sendable {"
        let built: String = "        self.signatureVerified = signatureVerified\n    }\n"
        for (file, anchor) in [(intake, indented), (intake, guarded), (wire, declared), (wire, built)] {
            #expect(Self.text(file, in: sources).contains(anchor), "vacuity: '\(anchor)' is the anchor in \(file)")
        }
        let forged: Sources = Self.adding(sources, "ZZByteForge.swift", Self.byteForge)
        let mutants: [(String, Sources)] = [
            // #163's shape: the byte-copy forge, decided from a new file, and
            // replanted into the wired sink itself.
            ("#163: a memcpy forge decided from a new file", Self.adding(sources, "ZZByteForge.swift", Self.byteForge
                + "extension ApprovalIntake {\n    func zzDecide(_ id: PromptID) { decide(zzForge((id, .allow, ApprovalWire.wireVersion, true))) }\n}\n")),
            ("#163: the forge replanted into the wired sink", Self.mutate(forged, intake) {
                $0.replacingOccurrences(of: indented, with: "        decide(.verified(zzForge((PromptID(hex: evidence.promptID)!, .allow, "
                                        + "ApprovalWire.wireVersion, true))))\n") }),
            ("a copyMemory forge handed to decide", Self.mutate(forged, intake) {
                $0.replacingOccurrences(of: indented, with: "        var forged = DecisionVerifier.verify(evidence, copy: copy, keys: keys, "
                                        + "audit: refusals)\n        zzCopied((PromptID(hex: evidence.promptID)!, .allow, 1, true), into: &forged)\n"
                                        + "        decide(forged)\n") }),
            // a. decide reached any other way.
            ("decide reached unapplied", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = ApprovalIntake.decide" }),
            ("a backticked decide through the host", Self.mutate(sources, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nextension RemoteApprovalsController { func zz(_ v: DecisionVerification) { _ = host?.withIntake { $0.`decide`(v) } } }" }),
            ("a dynamic replacement of decide", Self.adding(sources, "ZZReplace.swift",
                "extension ApprovalIntake {\n    @_dynamicReplacement(for: decide(_:)) func zzDecide(_ v: DecisionVerification) {}\n}\n")),
            ("decide's guard made to pass a forge", Self.mutate(sources, intake) {
                $0.replacingOccurrences(of: guarded, with: "guard case .verified(let decision) = zzForged(verification) else { return }") }),
            ("decide made to take a decision again", Self.mutate(sources, intake) {
                $0.replacingOccurrences(of: Self.decideHead, with: "func decide(_ verification: DecisionVerification, or d: ApprovalDecision? = nil) {") }),
            // b. the remote-decision event built off its site.
            ("a forged event from the intake", Self.mutate(forged, intake) {
                $0 + "\nextension ApprovalIntake {\n    func zzForce(_ id: PromptID) { apply(.remoteDecision(zzForge((id, .allow, 1, true))), to: id) }\n}" }),
            ("the event's case reached unapplied", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet zz = ApprovalEvent.remoteDecision" }),
            ("a lifecycle handed a forge directly", Self.mutate(forged, "MenuStateModel.swift") {
                $0 + "\nfunc zz(_ l: inout ApprovalLifecycle) { _ = l.apply(.remoteDecision(zzForge((l.id, .allow, 1, true))), now: 0) }" }),
            // c. the verifier's result built off its site.
            ("the verifier promotes a forge", Self.mutate(forged, verifier) {
                $0.replacingOccurrences(of: "enum DecisionVerifier {\n", with: "enum DecisionVerifier {\n    static func zzPromote(_ id: PromptID) "
                                        + "-> DecisionVerification { .verified(zzForge((id, .allow, 1, true))) }\n") }),
            ("a road inside the result type", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "    case unverified(DecisionUnverifiedReason)\n",
                                        with: "    case unverified(DecisionUnverifiedReason)\n    static func zz(_ d: ApprovalDecision) -> Self { verified(d) }\n") }),
            ("the result's case reached unapplied", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet zz = DecisionVerification . verified" }),
            ("a result built behind a block comment", Self.mutate(forged, "MenuStateModel.swift") {
                $0 + "\nlet zz: Any = DecisionVerification./* x */verified(zzForge((PromptID(high: 1, low: 1)!, .allow, 1, true)))" }),
            // d. the S0 type's own file.
            ("the S0 type given a second initializer", Self.mutate(sources, wire) {
                $0.replacingOccurrences(of: built, with: "        self.signatureVerified = signatureVerified\n    }\n\n"
                                        + "    public init(claimed promptID: PromptID) {\n        self.init(promptID: promptID, verdict: .allow, "
                                        + "wireVersion: ApprovalWire.wireVersion, signatureVerified: true)\n    }\n") }),
            ("the S0 type made Decodable", Self.mutate(sources, wire) {
                $0.replacingOccurrences(of: declared, with: "public struct ApprovalDecision: Equatable, Sendable, Decodable {") }),
            ("the S0 type extended in its own file", Self.mutate(sources, wire) {
                $0 + "\nextension ApprovalDecision {\n    static let zz = Self.init\n}" }),
            ("a conformance by a protocol extension in its file", Self.mutate(sources, wire) {
                $0 + "\nextension Decodable where Self == ApprovalDecision {}" }),
            ("the lifecycle's check made dead", Self.mutate(sources, wire) {
                $0.replacingOccurrences(of: "guard decision.signatureVerified else", with: "guard decision.signatureVerified || true else") }),
            ("a backticked alias of the S0 type in its file", Self.mutate(sources, wire) { $0 + "\npublic typealias ZZ = `ApprovalDecision`" }),
            // f. the doors around the sink.
            ("a forged event through withIntake", Self.mutate(forged, ApprovalChannelStructureTests.toggleFile) {
                $0 + "\nextension RemoteApprovalsController { func zz(_ id: PromptID) { _ = host?.withIntake { "
                    + "$0.apply(zzForge((id, .allow, 1, true)), to: id) } } }" }),
            ("the host applies an event", Self.mutate(sources, ApprovalChannelStructureTests.hostFile) {
                $0.replacingOccurrences(of: "        intake?.tick()\n", with: "        intake?.tick()\n        intake?.apply(.tick, to: zz)\n") }),
            ("a copyMemory event inside the intake", Self.mutate(forged, intake) {
                $0 + "\nextension ApprovalIntake {\n    func zzEvent(_ id: PromptID) { var event = ApprovalEvent.tick; "
                    + "zzCopied((id, .allow, 1, true), into: &event); apply(event, to: id) }\n}" }),
            ("a forged transition performed inside the intake", Self.mutate(forged, intake) {
                $0.replacingOccurrences(of: "        perform(transition, for: id)\n",
                                        with: "        perform(transition, for: id)\n        perform(zzForge((id, .allow, 1, true)), for: id)\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.sinkFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The byte-copy forge alone, on no sink, is #163's accepted residual:
        // nothing here bans it — only what it could reach.
        #expect(Self.sinkFailures(forged).isEmpty, "the forge reaching no sink is not this lock's to catch")
        // Over-match controls: words that only contain the pinned ones, a log
        // line saying "verified", and whole-line comments naming the sinks.
        #expect(Self.sinkFailures(Self.mutate(Self.mutate(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\nlet decided = true, undecided = false, remoteDecisions = 0, verifiedCount = 1, isVerified = true"
                + "\nfunc decideLater() {}\nfunc withIntakeCount() -> Int { 0 }\nlet note = \"read-back verified\""
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never decide(forged), never .remoteDecision(x), never .verified(x)")
        }, ApprovalChannelStructureTests.hostFile) { $0 + "\nlet intakeCount = 0" }, intake) { $0 + "\nlet applyCount = 0, performed = 1" }).isEmpty)
        // … and in the S0 type's own file: a whole-line comment inside its
        // declaration, a type whose name only starts like it, and a flag of
        // another name.
        #expect(Self.sinkFailures(Self.mutate(sources, wire) {
            $0.replacingOccurrences(of: declared, with: declared + LidGuardStructureTests.wholeLineCommentsRemoved(
                "\n    /// never a second init, never Decodable") + "\n")
                + "\npublic struct ApprovalDecisionLog { public let signatureVerifiedCount = 0 }"
        }).isEmpty)
        // Each pattern bites through the lock's own engine.
        for (pattern, probe) in [(#"\bdecide\b"#, "i.`decide`(v)"), (Self.verifiedPattern, "DecisionVerification . verified"),
                                 (Self.verifiedPattern, "{ verified (d) }"), (Self.verifiedPattern, "case\n    verified(X)")] {
            #expect(Self.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
    }

    /// The package manifest, read whole (#163): what it compiles is what the
    /// locks read.
    @Test func thePackageManifestIsTodaysTargetList() throws {
        let manifest = try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(Self.packageFailures(manifest).isEmpty, "\(Self.packageFailures(manifest))")
        let app: String = #"        .executableTarget(\n            name: "NapCat",\n            dependencies: ["NapCatSeam", "NapCatWire"]\n        ),"#
            .replacingOccurrences(of: "\\n", with: "\n")
        #expect(manifest.contains(app), "vacuity: the app target is the anchor")
        let mutants: [(String, String)] = [
            ("a target outside the scanned roots", manifest.replacingOccurrences(of: app, with: app
                + "\n        .target(name: \"NapCatForge\", dependencies: [\"NapCatWire\"]),")
                .replacingOccurrences(of: "dependencies: [\"NapCatSeam\", \"NapCatWire\"]\n        ),\n        .target(name",
                                      with: "dependencies: [\"NapCatSeam\", \"NapCatWire\", \"NapCatForge\"]\n        ),\n        .target(name")),
            ("the app's sources moved", manifest.replacingOccurrences(of: #"dependencies: ["NapCatSeam", "NapCatWire"]"# + "\n        ),",
                                                                  with: #"dependencies: ["NapCatSeam", "NapCatWire"], path: "Elsewhere""# + "\n        ),")),
            ("an excluded file", manifest.replacingOccurrences(of: #"name: "NapCatWire""#, with: #"name: "NapCatWire", exclude: ["ZZ.swift"]"#)),
            ("a flag on the app", manifest.replacingOccurrences(of: #"name: "NapCat","#,
                                                              with: #"name: "NapCat", swiftSettings: [.unsafeFlags(["-enable-implicit-dynamic"])],"#)),
            ("a package dependency", manifest.replacingOccurrences(of: #"name: "NapCat",\n    // The iOS"#.replacingOccurrences(of: "\\n", with: "\n"),
                                                                 with: "name: \"NapCat\",\n    dependencies: [.package(path: \"../Forge\")],\n    // The iOS")),
            ("a plugin", manifest.replacingOccurrences(of: #"name: "NapCatSeam","#, with: #"name: "NapCatSeam", plugins: ["ZZ"],"#)),
            ("a new product", manifest.replacingOccurrences(of: "    products: [\n", with: "    products: [\n        .library(name: \"ZZ\", targets: [\"NapCat\"]),\n")),
            ("a test flag widened", manifest.replacingOccurrences(of: #"? [.unsafeFlags(["-F", cltFrameworksPath])]"#,
                                                                with: #"? [.unsafeFlags(["-F", cltFrameworksPath, "-enable-testing"])]"#)),
            ("a target behind a block comment", manifest.replacingOccurrences(of: app, with: app + "\n        /* x */ .target(name: \"ZZ\"),")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != manifest, "canary '\(name)' did not apply")
            #expect(!Self.packageFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a comment line, a trailing comment and
        // reflowed whitespace.
        #expect(Self.packageFailures(manifest.replacingOccurrences(of: app, with: "        // the app\n"
            + app.replacingOccurrences(of: "\n            dependencies", with: " dependencies") + " // trailing")).isEmpty)
    }

    // MARK: - g. The road, whole

    /// One declaration pinned whole: in `file`, `declared` (a regex over the
    /// code) matches once, and `whole` (the declaration flattened, from the
    /// token before it to its own closing brace) appears exactly once.
    typealias WholePin = (file: String, declared: String, whole: String)

    /// The verifier, whole: every check in order, the claim's lines, the
    /// message, the diagnostic (from the brace before it, so no attribute or
    /// modifier joins it).
    static let verifierWhole: String = [
        "} enum DecisionVerifier {",
        "static let latestDecidedAt: TimeInterval = 9_007_199_254_740_992",
        "static func verify(_ evidence: DecisionEvidence, copy: ForwardedCopy?, keys: PairedKeyStore,",
        "audit: (DecisionVerifierAudit) -> Void = DecisionVerifierLog.record) -> DecisionVerification {",
        "let pairedKey: P256.Signing.PublicKey? = switch keys.read() {",
        "case .paired(let phone): try? P256.Signing.PublicKey(x963Representation: phone.publicKey)",
        "case .notPaired, .unreadable: nil", "}",
        "let verification = verification(of: evidence, copy: copy, pairedKey: pairedKey)",
        "if case .unverified(let reason) = verification {",
        "audit(DecisionVerifierAudit(promptID: PromptID(hex: evidence.promptID), reason: reason))", "}",
        "return verification", "}",
        "static func verification(of evidence: DecisionEvidence, copy: ForwardedCopy?,",
        "pairedKey: P256.Signing.PublicKey?) -> DecisionVerification {",
        "guard let pairedKey else { return .unverified(.noPairedKey) }",
        "guard let verdict = ApprovalWire.Verdict(rawValue: evidence.verdict) else { return .unverified(.unknownVerdict) }",
        "let seconds = evidence.decidedAt.timeIntervalSince1970",
        "guard seconds.isFinite, seconds >= 0, seconds <= latestDecidedAt else { return .unverified(.decidedAtOutOfRange) }",
        "guard seconds == seconds.rounded(.towardZero) else { return .unverified(.fractionalDecidedAt) }",
        "guard evidence.signature.count == ApprovalSigning.signatureByteCount else { return .unverified(.signatureLength) }",
        "guard evidence.wireVersion == ApprovalWire.wireVersion else { return .unverified(.wrongWireVersion) }",
        "guard let promptID = PromptID(hex: evidence.promptID) else { return .unverified(.malformedPromptID) }",
        "guard let copy, copy.promptID == promptID else { return .unverified(.noForwardedCopy) }",
        "let claimed = Claimed(wireVersion: evidence.wireVersion, promptID: promptID, verdict: verdict, decidedAt: Int(seconds))",
        "guard let message = message(claimed, shown: copy),",
        "let signature = try? P256.Signing.ECDSASignature(rawRepresentation: evidence.signature) else {",
        "return .unverified(.signatureInvalid)", "}",
        "guard pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) else {",
        "return .unverified(signedAnotherForm(claimed, of: copy, signature, pairedKey) ? .shownDigestMismatch : .signatureInvalid)", "}",
        "return .verified(ApprovalDecision(promptID: promptID, verdict: verdict, wireVersion: evidence.wireVersion, signatureVerified: true))",
        "}",
        "struct Claimed {", "let wireVersion: Int", "let promptID: PromptID", "let verdict: ApprovalWire.Verdict", "let decidedAt: Int", "}",
        "static func message(_ claimed: Claimed, shown copy: ForwardedCopy) -> [UInt8]? {",
        "let shown = SHA256.hash(data: ApprovalSigning.shownDigestInput(toolName: copy.toolName, inputPreview: copy.inputPreview,",
        "projectLabel: copy.projectLabel))",
        "return ApprovalSigning.decisionMessage(wireVersion: claimed.wireVersion, promptID: claimed.promptID, verdict: claimed.verdict,",
        "decidedAt: claimed.decidedAt, shownDigest: Array(shown))", "}",
        "static func signedAnotherForm(_ claimed: Claimed, of copy: ForwardedCopy, _ signature: P256.Signing.ECDSASignature,",
        "_ pairedKey: P256.Signing.PublicKey) -> Bool {",
        "let forms: [(String) -> String] = [{ $0.precomposedStringWithCanonicalMapping }, { $0.decomposedStringWithCanonicalMapping }]",
        "let stored = ApprovalSigning.shownDigestInput(toolName: copy.toolName, inputPreview: copy.inputPreview,",
        "projectLabel: copy.projectLabel)",
        "for form in forms {",
        "let other = ForwardedCopy(promptID: copy.promptID, toolName: form(copy.toolName), inputPreview: form(copy.inputPreview),",
        "projectLabel: form(copy.projectLabel))",
        "guard ApprovalSigning.shownDigestInput(toolName: other.toolName, inputPreview: other.inputPreview,",
        "projectLabel: other.projectLabel) != stored,",
        "let message = message(claimed, shown: other) else { continue }",
        "if pairedKey.isValidSignature(signature, for: SHA256.hash(data: message)) { return true }", "}",
        "return false", "}", "}",
    ].joined(separator: " ")
    /// The intake's `apply` and `perform`, whole.
    static let applyWhole: String = [
        "} func apply(_ event: ApprovalEvent, to id: PromptID) {",
        "guard var item = prompts[id] else { return audit(.unknownPrompt) }",
        "let transition = item.lifecycle.apply(event, now: now())", "prompts[id] = item", "perform(transition, for: id)", "}",
    ].joined(separator: " ")
    static let performWhole: String = [
        "} private func perform(_ transition: ApprovalTransition, for id: PromptID,",
        "classified: (ApprovalClassification, String?)? = nil) {",
        "for entry in transition.audit { audit(.lifecycle(id, entry)) }", "guard let item = prompts[id] else { return }",
        "for effect in transition.effects {", "switch effect {", "case .saveRecord:",
        "guard case .forward(let tool)? = classified?.0, let preview = classified?.1 else { continue }",
        "records.save(id, tool: tool, inputPreview: preview, expiresAt: item.lifecycle.expiresAt)",
        "case .supersedeWaitingAlert:", "records.supersedeWaitingAlert(id)", "case .deliverVerdict(let verdict):",
        "sendFrame(item.connection, ApprovalChannel.verdictFrame(item.request, verdict))", "case .retractRecord:",
        "records.retract(id)", "}", "}", "}",
    ].joined(separator: " ")
    /// The host's door, whole: the intake bound plainly, then handed to
    /// `body` (no member call on the optional for an extension to take).
    static let doorWhole: String = [
        "} func withIntake<Result>(_ body: (ApprovalIntake) -> Result) -> Result? {",
        "dispatchPrecondition(condition: .notOnQueue(queue))", "return queue.sync {", "guard let intake else { return nil }",
        "return body(intake)", "}", "}",
    ].joined(separator: " ")
    /// The slot's read, whole: the keychain's answer, read now and kept nowhere.
    static let slotReadWhole: String = [
        #"static let header = "napcat-paired-v1" func read() -> PairedPhoneRead {"#, "switch items.read() {",
        "case .found(let text): return Self.phone(from: text).map(PairedPhoneRead.paired) ?? .unreadable",
        "case .notFound: return .notPaired", "case .failed: return .unreadable", "}", "}",
    ].joined(separator: " ")
    static let roadPins: [WholePin] = [
        (verifierFile, #"\benum\s+DecisionVerifier\b"#, verifierWhole),
        (ApprovalChannelStructureTests.intakeFile, #"\bfunc\s+apply\b"#, applyWhole),
        (ApprovalChannelStructureTests.intakeFile, #"\bfunc\s+perform\b"#, performWhole),
    ]
    static let doorPin: WholePin = (ApprovalChannelStructureTests.hostFile, #"\bfunc\s+withIntake\b"#, doorWhole)
    static let slotReadPin: WholePin = (PairingStructureTests.slotFile, #"\bfunc\s+read\b"#, slotReadWhole)

    /// `sources`: `uncutSources()`. In every scan copy of each pin's file,
    /// comment-stripped: the declaration is declared once, and is exactly
    /// its pinned text, whole. Whitespace and `//` comments are free; a
    /// block comment or a backtick inside a pinned body reads as a change
    /// (the raw copy is read too). A copy kept elsewhere — in a literal, a
    /// comment or an inactive `#if` — beside a changed one fails: the name
    /// is then declared twice, or the text is in no copy's code.
    static func wholeFailures(_ sources: Sources, _ pins: [WholePin]) -> [String] {
        var failures: [String] = []
        for pin in pins {
            for copy in LidGuardStructureTests.constructorScanCopies(text(pin.file, in: sources)) {
                let code = LidGuardStructureTests.codeOnly(copy)
                let found = ApprovalChannelStructureTests.count(pin.whole, in: MenuPanelStructureTests.flat(code))
                let declared = RecordPath.matches(pin.declared, in: code).count
                if found != 1 || declared != 1 {
                    failures.append("'\(pin.declared)' in \(pin.file) is declared once, exactly as pinned, whole — "
                                    + "found the pinned text \(found)×, the declaration \(declared)×")
                }
            }
        }
        return unique(failures)
    }

    /// The security review's plants, verbatim (never committed anywhere;
    /// each passed every lock before the pin that now catches it). The pour:
    /// literal bytes into a generic slot through NSData's getBytes.
    static let pour: String = """
        import Foundation
        import NapCatWire

        // Security review replant (never committed): a value poured from literal
        // bytes into a generic slot through NSData's getBytes.
        func zzPoured<T>(_ bytes: [UInt8]) -> T {
            let slot = UnsafeMutablePointer<T>.allocate(capacity: 1)
            defer { slot.deallocate() }
            NSData(bytes: bytes, length: bytes.count).getBytes(slot, length: min(bytes.count, MemoryLayout<T>.size))
            return slot.move()
        }

        func zzPour<T>(_ bytes: [UInt8], into slot: inout T) {
            NSData(bytes: bytes, length: bytes.count).getBytes(&slot, length: min(bytes.count, MemoryLayout<T>.size))
        }

        /// The ID's two halves, the answer's case index, the wire version, the flag.
        func zzBytes(_ hex: String, answer: UInt8 = 0) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 48)
            let digits = Array(hex.utf8)
            guard digits.count == 32 else { return out }
            func nibble(_ c: UInt8) -> UInt8 { c >= 97 ? c &- 87 : c &- 48 }
            for i in 0..<16 {
                out[i < 8 ? 7 - i : 23 - i] = nibble(digits[2 * i]) << 4 | nibble(digits[2 * i + 1])
            }
            out[16] = answer
            out[24] = 1
            out[32] = 1
            return out
        }

        """
    /// W4's anchor (the verifier's first check) and its trigger above it;
    /// W4U's trigger, for every 64-byte signature.
    static let firstGuard: String = "        guard let pairedKey else { return .unverified(.noPairedKey) }\n"
    static let w4Trigger: String = """
                if evidence.decidedAt.timeIntervalSince1970 == 1_999_999_999 { return zzPoured(zzBytes(evidence.promptID)) }

        """
    static let w4uTrigger: String = """
                if evidence.signature.count == 64 { return zzPoured(zzBytes(evidence.promptID)) }

        """
    /// W7's anchor (the head of the intake's `apply`) and its rewrite: the
    /// event rebound on a line above the pinned one.
    static let applyAnchor: String = """
                guard var item = prompts[id] else { return audit(.unknownPrompt) }
                let transition = item.lifecycle.apply(event, now: now())

        """
    static let w7Apply: String = """
                guard var item = prompts[id] else { return audit(.unknownPrompt) }
                var event = event
                if id.high == 0x5EC0_DE00_0000_0001, item.lifecycle.phase == .forwarded { zzPour(zzBytes(id.hex), into: &event) }
                let transition = item.lifecycle.apply(event, now: now())

        """

    @Test func theDecisionRoadIsPinnedWhole() throws {
        let sources = try Self.uncutSources()
        let pins: [WholePin] = Self.roadPins
        #expect(Self.wholeFailures(sources, pins).isEmpty, "\(Self.wholeFailures(sources, pins))")
        let verifier: String = Self.verifierFile
        let intake: String = ApprovalChannelStructureTests.intakeFile
        let verifierPin: [WholePin] = [pins[0]]
        let applyPin: [WholePin] = [pins[1]]
        let otherPins: [WholePin] = [pins[1], pins[2]]
        #expect(Self.text(verifier, in: sources).contains(Self.firstGuard) && Self.text(intake, in: sources).contains(Self.applyAnchor),
                "vacuity: the review's anchors are where its plants go")
        let poured: Sources = Self.adding(sources, "ZZPour.swift", Self.pour)
        let w4: Sources = Self.mutate(poured, verifier) {
            $0.replacingOccurrences(of: Self.firstGuard, with: Self.w4Trigger + Self.firstGuard) }
        let w4u: Sources = Self.mutate(poured, verifier) {
            $0.replacingOccurrences(of: Self.firstGuard, with: Self.w4uTrigger + Self.firstGuard) }
        let w7: Sources = Self.mutate(poured, intake) { $0.replacingOccurrences(of: Self.applyAnchor, with: Self.w7Apply) }
        // W4 and W7, verbatim: each is caught by its own body pin alone, and
        // the sink pins and the other bodies read it exactly as they read the
        // tree.
        let reviewed: [(String, Sources, [WholePin], [WholePin])] = [
            ("W4: a poured result inside the verifier's checks, behind a trigger", w4, verifierPin, otherPins),
            ("W4U: the same pour for every 64-byte signature", w4u, verifierPin, otherPins),
            ("W7: the event rebound by a pour inside the intake's apply", w7, applyPin, [pins[0], pins[2]]),
        ]
        for (name, mutant, own, others) in reviewed {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.wholeFailures(mutant, own).isEmpty, "canary '\(name)' was NOT caught by its body pin alone")
            #expect(Self.wholeFailures(mutant, others) == Self.wholeFailures(sources, others)
                        && Self.sinkFailures(mutant) == Self.sinkFailures(sources), "canary '\(name)' is its own body pin's to catch")
        }
        // A pinned copy kept beside a changed original: in an inactive block
        // (the parser reads it, the compiler builds nothing of it) and in a
        // literal.
        let logHead: String = "enum DecisionVerifierLog {\n"
        let decoyBlock: String = logHead + "#if false\nstruct ZZ {\n" + Self.verifierWhole + "\n#endif\n"
        let constant: String = "    static let waitingContextSeconds = 30\n"
        let decoyLiteral: String = constant + "    static let zz = \"" + Self.applyWhole + "\"\n"
        let applyHead: String = "    func apply(_ event: ApprovalEvent, to id: PromptID) {\n"
        let dynamicApply: String = "    dynamic func apply(_ event: ApprovalEvent, to id: PromptID) {\n"
        let mutants: [(String, Sources)] = [
            ("a member added to the verifier", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "enum DecisionVerifier {\n", with: "enum DecisionVerifier {\n    static let zz = 1\n") }),
            ("a check dropped", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "        guard seconds == seconds.rounded(.towardZero) else { return .unverified(.fractionalDecidedAt) }\n",
                                        with: "") }),
            ("the message rebuilt otherwise", Self.mutate(sources, verifier) {
                $0.replacingOccurrences(of: "shownDigest: Array(shown))", with: "shownDigest: Array(shown.prefix(1)))") }),
            ("the pinned verifier kept in an inactive block, the real one changed", Self.mutate(w4, verifier) {
                $0.replacingOccurrences(of: logHead, with: decoyBlock) }),
            ("the pinned apply kept in a literal, the real one changed", Self.mutate(w7, intake) {
                $0.replacingOccurrences(of: constant, with: decoyLiteral) }),
            ("apply made dynamic", Self.mutate(sources, intake) { $0.replacingOccurrences(of: applyHead, with: dynamicApply) }),
            ("a second effect performed", Self.mutate(sources, intake) {
                $0.replacingOccurrences(of: "                records.supersedeWaitingAlert(id)\n",
                                        with: "                records.supersedeWaitingAlert(id)\n                zzTap(id)\n") }),
            ("a statement after perform's loop", Self.mutate(sources, intake) {
                $0.replacingOccurrences(of: "                records.retract(id)\n            }\n        }\n",
                                        with: "                records.retract(id)\n            }\n        }\n        zzTap(id)\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.wholeFailures(mutant, pins).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: whitespace only (lines joined and split,
        // spaces doubled, a tab) and comments only (whole-line and trailing,
        // inside the pinned bodies).
        let reflowed: Sources = Self.mutate(Self.mutate(sources, verifier) {
            $0.replacingOccurrences(of: "copy: ForwardedCopy?,\n                             pairedKey:", with: "copy: ForwardedCopy?, pairedKey:")
                .replacingOccurrences(of: "        let seconds = evidence.decidedAt.timeIntervalSince1970\n",
                                      with: "\n        let seconds  =\n            evidence.decidedAt.timeIntervalSince1970\n\n")
        }, intake) {
            $0.replacingOccurrences(of: "        prompts[id] = item\n", with: "\n\t\tprompts[id]  =  item\n\n")
                .replacingOccurrences(of: "            case .retractRecord:\n", with: "\t\t\tcase .retractRecord:\n")
        }
        let commented: Sources = Self.mutate(Self.mutate(sources, verifier) {
            $0.replacingOccurrences(of: Self.firstGuard, with: "        /// the paired key first\n" + Self.firstGuard)
                .replacingOccurrences(of: "        return verification\n", with: "        return verification // the result, as checked\n")
        }, intake) {
            $0.replacingOccurrences(of: "        prompts[id] = item\n", with: "        // the lifecycle, back\n        prompts[id] = item // stored\n")
                .replacingOccurrences(of: "            case .retractRecord:\n", with: "            // withdrawn\n            case .retractRecord: // gone\n")
        }
        for (name, control) in [("whitespace only", reflowed), ("comments only", commented)] {
            #expect(control.map { $0.text } != sources.map { $0.text }, "control '\(name)' did not apply")
            #expect(Self.wholeFailures(control, pins).isEmpty, "control '\(name)': \(Self.wholeFailures(control, pins))")
        }
    }

    // MARK: - g, continued. The road, read scalar by scalar

    /// One planted line: in `file`, `anchor` (there once) becomes `planted`.
    typealias PlantedLine = (file: String, anchor: String, planted: String)

    /// A line holding one zero-width scalar and nothing else.
    static let invisibleStatement: String = "        \u{200D}\n"
    /// The verifier's canonical-bytes call, the anchor ZW4B rewrites.
    static let messageCall: String =
        "        return ApprovalSigning.decisionMessage(wireVersion: claimed.wireVersion, promptID: claimed.promptID, verdict: claimed.verdict,\n"
    /// ZW4B, verbatim: that call's enum name behind one zero-width scalar …
    static let zeroWidthCall: [PlantedLine] = [
        (verifierFile, messageCall, messageCall.replacingOccurrences(of: "return ApprovalSigning", with: "return \u{200D}ApprovalSigning")),
    ]
    /// … and a new file declaring that name.
    static let zeroWidthSigning: String = """
        import NapCatWire

        // Security delta re-check replant (never committed): a global whose name is
        // the canonical-bytes enum's behind one zero-width scalar. The verifier's
        // pinned line reads `return ApprovalSigning.decisionMessage(` to every lock;
        // the compiler resolves it here.
        final class ZZKeptMessage: @unchecked Sendable {
            var bytes: [UInt8]?
        }

        let zzKeptMessage = ZZKeptMessage()

        struct ZZMessage {
            func callAsFunction(wireVersion: Int, promptID: PromptID, verdict: ApprovalWire.Verdict, decidedAt: Int,
                                shownDigest: [UInt8]) -> [UInt8]? {
                if decidedAt == 1_999_999_999, let kept = zzKeptMessage.bytes { return kept }
                let honest = ApprovalSigning.decisionMessage(wireVersion: wireVersion, promptID: promptID, verdict: verdict,
                                                             decidedAt: decidedAt, shownDigest: shownDigest)
                zzKeptMessage.bytes = honest
                return honest
            }
        }

        @dynamicMemberLookup
        struct ZZSigning {
            subscript(dynamicMember name: String) -> ZZMessage { ZZMessage() }
        }

        let \u{200D}ApprovalSigning = ZZSigning()

        """
    /// ZWALL2, verbatim: an invisible statement in each body pinned whole
    /// (the verifier twice, apply, perform, the door) and in the sink's
    /// decide and wired call …
    static let invisibleStatements: [PlantedLine] = {
        let intake: String = ApprovalChannelStructureTests.intakeFile
        let after: [(file: String, anchor: String)] = [
            (verifierFile, "        let verification = verification(of: evidence, copy: copy, pairedKey: pairedKey)\n"),
            (verifierFile, "        let seconds = evidence.decidedAt.timeIntervalSince1970\n"),
            (intake, "        prompts[id] = item\n"),
            (intake, "        guard let item = prompts[id] else { return }\n"),
            (intake, "        guard case .verified(let decision) = verification else { return }\n"),
        ]
        let wired: String = "        " + wiredCall + "\n"
        let door: String = "        return queue.sync {\n            guard let intake else { return nil }\n"
        let before: [(file: String, anchor: String)] = [(intake, wired), (ApprovalChannelStructureTests.hostFile, door)]
        var lines: [PlantedLine] = []
        for line in after { lines.append((line.file, line.anchor, line.anchor + invisibleStatement)) }
        for line in before { lines.append((line.file, line.anchor, invisibleStatement + line.anchor)) }
        return lines
    }()
    /// … and a new file declaring the name those statements evaluate.
    static let zeroWidthTap: String = """
        // Security delta re-check replant (never committed): a global whose whole
        // name is one zero-width scalar. A line holding nothing else evaluates it.
        final class ZZTaps: @unchecked Sendable {
            var count = 0
        }

        let zzTaps = ZZTaps()

        var \u{200D}: Void { zzTaps.count += 1 }

        """

    /// `raw` with each line planted, still raw (`uncut` reads it as the
    /// locks do).
    static func planting(_ raw: Sources, _ lines: [PlantedLine]) -> Sources {
        lines.reduce(raw) { sources, line in mutate(sources, line.file) { $0.replacingOccurrences(of: line.anchor, with: line.planted) } }
    }

    /// Each source as `uncutSources()` reads it.
    static func uncut(_ raw: Sources) -> Sources { raw.map { ($0.name, LidGuardStructureTests.wholeLineCommentsRemoved($0.text)) } }

    /// A scalar the compiler reads as part of a name does not vanish from
    /// the road's flattened text. The re-check's plants, verbatim, as the
    /// disk would hold them: ZW4B (a name on the verifier's road behind one
    /// zero-width scalar) and ZWALL2 (an invisible statement in every pinned
    /// body).
    /// Each is caught by the raw-text lock alone, on exactly its planted
    /// lines, and, now that the flattening reads scalars, by the pins of the
    /// bodies it touches as well; a flattening by characters read each of
    /// those bodies as the tree.
    @Test func theRoadIsReadScalarByScalar() throws {
        let flat: (String) -> String = { MenuPanelStructureTests.flat($0) }
        #expect(flat(" a \t\n\r\u{B}\u{C}\u{0}b ") == "a b", "the compiler's whitespace flattens to one space")
        let hidden: [Unicode.Scalar] = ["\u{200D}", "\u{301}", "\u{FF9E}", "\u{A0}"]
        for scalar in hidden {
            #expect(flat("return " + String(scalar) + "zz") != "return zz", "the flattening dropped U+\(String(scalar.value, radix: 16))")
        }
        let raw: Sources = try ApprovalChannelStructureTests.sources { $0 }
        var lines: [PlantedLine] = Self.zeroWidthCall
        lines.append(contentsOf: Self.invisibleStatements)
        for line in lines {
            #expect(ApprovalChannelStructureTests.count(line.anchor, in: Self.text(line.file, in: raw)) == 1,
                    "vacuity: '\(line.anchor.prefix(60))' is in \(line.file) once")
        }
        var zw4b: Sources = Self.planting(raw, Self.zeroWidthCall)
        zw4b.append(("ZZSigning.swift", Self.zeroWidthSigning))
        var zwall2: Sources = Self.planting(raw, Self.invisibleStatements)
        zwall2.append(("ZZTap.swift", Self.zeroWidthTap))
        // The raw-text lock alone: the planted lines, and nothing else.
        let tree: [String] = LidGuardStructureTests.hiddenScalarFailures(raw)
        let zw4bFlagged: [String] = LidGuardStructureTests.hiddenScalarFailures(zw4b)
        let zwall2Flagged: [String] = LidGuardStructureTests.hiddenScalarFailures(zwall2)
        #expect(tree.isEmpty, "\(tree)")
        #expect(zw4bFlagged.count == 2, "ZW4B was NOT caught by the raw-text lock alone: \(zw4bFlagged)")
        #expect(zwall2Flagged.count == 8, "ZWALL2 was NOT caught by the raw-text lock alone: \(zwall2Flagged)")
        // The road's own pins, reading scalars.
        let sources: Sources = Self.uncut(raw)
        let zw4bRead: Sources = Self.uncut(zw4b)
        let zwall2Read: Sources = Self.uncut(zwall2)
        let verifier: [WholePin] = [Self.roadPins[0]]
        #expect(!Self.wholeFailures(zw4bRead, verifier).isEmpty, "ZW4B was NOT caught by the verifier's pin")
        var touched: [WholePin] = Self.roadPins
        touched.append(Self.doorPin)
        for pin in touched {
            #expect(!Self.wholeFailures(zwall2Read, [pin]).isEmpty, "ZWALL2 was NOT caught by \(pin.declared)'s pin")
        }
        #expect(Self.sinkFailures(zwall2Read) != Self.sinkFailures(sources), "ZWALL2 was NOT caught by decide's flat pins")
        // A flattening by characters read the planted bodies as the tree.
        let byCharacters: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let blind: [(file: String, whole: String, planted: Sources)] = [
            (Self.verifierFile, Self.verifierWhole, zw4bRead), (Self.verifierFile, Self.verifierWhole, zwall2Read),
            (ApprovalChannelStructureTests.intakeFile, Self.performWhole, zwall2Read),
            (ApprovalChannelStructureTests.hostFile, Self.doorWhole, zwall2Read),
        ]
        for (file, whole, planted) in blind {
            let code: String = LidGuardStructureTests.codeOnly(Self.text(file, in: planted))
            #expect(ApprovalChannelStructureTests.count(whole, in: byCharacters(code)) == 1, "vacuity: the plant in \(file) is one the old reading missed")
        }
    }

    // MARK: - f, continued. The door, plain; the intake's type, its frame writer, the host's writes and the connection's type, at their sites

    /// Every line naming the intake's type in the four targets: its own
    /// declaration, the toggle's one constant, and the host's lines.
    static let intakeTypeSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: ["final class ApprovalIntake {": 1],
        ApprovalChannelStructureTests.toggleFile: [
            "let tools = host.withIntake { $0.recentForwardableTools(within: ApprovalIntake.waitingContextSeconds) } ?? []": 1],
        ApprovalChannelStructureTests.hostFile: [
            "private var connections: [ApprovalIntake.ConnectionKey: SeamConnection] = [:]": 1,
            "private var idleTimers: [ApprovalIntake.ConnectionKey: DispatchSourceTimer] = [:]": 1,
            "private var intake: ApprovalIntake?": 1,
            "intake = ApprovalIntake(armed: armed, secrets: secrets, newPromptID: newPromptID, now: now, records: records,": 1,
            "func withIntake<Result>(_ body: (ApprovalIntake) -> Result) -> Result? {": 1,
            "private func armIdleTimer(_ key: ApprovalIntake.ConnectionKey) {": 1,
            "private func idleTimerFired(_ key: ApprovalIntake.ConnectionKey) {": 1],
    ]
    /// An alias spelled with `?` on its right-hand side (also when that side
    /// starts on the next line).
    static let optionalAliasPattern: String = #"\btypealias\b[^=\n{}]*="# + RecordPath.gap + #"*[^\n]*\?"#
    /// `Optional` named at all (so extended, qualified or aliased by name),
    /// an extension whose header spells `?` (`extension T? {`), and an alias
    /// spelled with `?`: today's two, both function types. (A compiled probe:
    /// `typealias Maybe<T> = T?` and an unconstrained `extension Maybe` with
    /// a `map` takes every optional's `.map` in the module.) Imported aliases
    /// are not read: one of a concrete optional (Foundation's
    /// `NSErrorPointer`) can still be extended, for that one wrapped type.
    static let optionalSites: [(pattern: String, allowed: [String: [String: Int]], rule: String)] = [
        (#"\bOptional\b"#, [:], "Optional is named nowhere in the four targets"),
        (#"\bextension\b[^{]*\?"#, [:], "no extension's header spells an optional"),
        (optionalAliasPattern, [
            "LidGuardController.swift": ["typealias ClaudeBusyProvider = @Sendable () -> LidGuardBusySample?": 1],
            "ChannelRelay.swift": [
                "typealias Connector = (_ onFrame: @escaping ([UInt8]) -> Void, _ onClose: @escaping () -> Void) -> ChannelLink?": 1]],
         "an alias spelled with ? is one of today's two function types, so no alias of an optional is extended"),
    ]
    /// The intake's frame writer: stored, taken at its initializer, and
    /// called once, for the lifecycle's `.deliverVerdict`.
    static let frameWriterSites: [String: Int] = [
        "private let sendFrame: (ConnectionKey, String) -> Void": 1,
        "now: @escaping () -> Int, records: ApprovalRecordSink, sendFrame: @escaping (ConnectionKey, String) -> Void,": 1,
        "self.sendFrame = sendFrame": 2, "sendFrame(item.connection, ApprovalChannel.verdictFrame(item.request, verdict))": 1,
    ]

    /// The files a site pin's allow-list names that `sources` lacks (the pin
    /// would read nothing there).
    static func absent(_ files: some Sequence<String>, in sources: Sources) -> [String] {
        files.filter { file in !sources.contains { $0.name == file } }.map { "\($0) is not where the pin looks — it would be vacuous" }
    }

    /// `sources`: `uncutSources()`.
    static func intakeTypeFailures(_ sources: Sources) -> [String] {
        absent(intakeTypeSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(#"\bApprovalIntake\b"#, in: sources, allowed: intakeTypeSites,
                                                    rule: "the intake's type is named at today's sites alone — nothing new extends, wraps or takes it by name")
    }

    /// `sources`: `uncutSources()`.
    static func optionalFailures(_ sources: Sources) -> [String] {
        unique(absent(["LidGuardController.swift", "ChannelRelay.swift"], in: sources) + optionalSites.flatMap {
            PairingStructureTests.appSiteFailures($0.pattern, in: sources, allowed: $0.allowed, rule: $0.rule)
        })
    }

    /// `sources`: `uncutSources()`.
    static func frameWriterFailures(_ sources: Sources) -> [String] {
        let intake = ApprovalChannelStructureTests.intakeFile
        return absent([intake], in: sources)
            + PairingStructureTests.appSiteFailures(#"\bsendFrame\b"#, in: sources.filter { $0.name == intake }, allowed: [intake: frameWriterSites],
                                                    rule: "the intake names its frame writer at today's sites — it writes the lifecycle's verdict alone")
    }

    /// The door as it is, the anchor its canaries replace.
    static let doorBinding: String = """
                return queue.sync {
                    guard let intake else { return nil }
                    return body(intake)
                }

        """
    /// D1, verbatim: a constrained `Optional.map` in a new file, which the
    /// host's old door line (`intake.map(body)`) resolved to.
    static let doorPlant: String = """
        import Foundation
        import NapCatWire

        // Security review replant (never committed): a member of a constrained
        // extension, in a new file, that the host's own pinned line resolves to.
        extension Optional where Wrapped == ApprovalIntake {
            func map<R>(_ body: (ApprovalIntake) -> R) -> R? {
                guard let intake = self else { return nil }
                for id in Array(intake.prompts.keys) where id.high == 0x5EC0_DE00_0000_0001 {
                    intake.apply(zzPoured(zzBytes(id.hex)), to: id)
                }
                return body(intake)
            }
        }

        """
    /// The generic-alias road (compiled in a scratch probe: its `map` took a
    /// `.map` on another optional).
    static let aliasMap: String = """
        typealias Maybe<T> = T?
        extension Maybe {
            func map<U>(_ transform: (Wrapped) -> U) -> U? { nil }
        }

        """

    @Test func theIntakesDoorIsAPlainBindingAndItsTypeIsNamedAtTodaysSites() throws {
        let sources = try Self.uncutSources()
        let door: [WholePin] = [Self.doorPin]
        #expect(Self.wholeFailures(sources, door).isEmpty, "\(Self.wholeFailures(sources, door))")
        #expect(Self.intakeTypeFailures(sources).isEmpty, "\(Self.intakeTypeFailures(sources))")
        #expect(Self.optionalFailures(sources).isEmpty, "\(Self.optionalFailures(sources))")
        let host: String = ApprovalChannelStructureTests.hostFile
        #expect(Self.text(host, in: sources).contains(Self.doorBinding), "vacuity: the door is where its canaries plant")
        // D1, verbatim, caught by the type pin alone and by the Optional ban
        // alone (and by no pin before them; the extension pin, added since,
        // catches it too).
        let d1: Sources = Self.adding(Self.adding(sources, "ZZPour.swift", Self.pour), "ZZDoor.swift", Self.doorPlant)
        #expect(!Self.intakeTypeFailures(d1).isEmpty, "D1 was NOT caught by the intake's type pin alone")
        #expect(!Self.optionalFailures(d1).isEmpty, "D1 was NOT caught by the Optional ban alone")
        #expect(Self.sinkFailures(d1) == Self.sinkFailures(sources) && Self.wholeFailures(d1, door) == Self.wholeFailures(sources, door),
                "D1 is the type pin's and the ban's to catch")
        // The old door line, back: the door's whole pin and the host's intake
        // sites both see it.
        let mapped: Sources = Self.mutate(sources, host) {
            $0.replacingOccurrences(of: Self.doorBinding, with: "        return queue.sync { intake.map(body) }\n") }
        #expect(!Self.wholeFailures(mapped, door).isEmpty && !Self.sinkFailures(mapped).isEmpty, "the old door line was NOT caught")
        // Each pin's own canaries, caught by that pin alone of the three here.
        let tapped: Sources = Self.mutate(sources, host) {
            $0.replacingOccurrences(of: "            return body(intake)\n", with: "            zzTap()\n            return body(intake)\n") }
        let byPin: [(String, Sources, (Sources) -> [String])] = [
            ("a statement in the door naming no intake", tapped, { Self.wholeFailures($0, door) }),
            ("the intake extended in a new file", Self.adding(sources, "ZZCount.swift",
                "extension ApprovalIntake {\n    var zzCount: Int { prompts.count }\n}\n"), Self.intakeTypeFailures),
            ("the intake taken by the toggle", Self.mutate(sources, ApprovalChannelStructureTests.toggleFile) {
                $0.appending("\nfunc zz(_ intake: ApprovalIntake) {}") }, Self.intakeTypeFailures),
            ("the intake aliased, backticked", Self.mutate(sources, "NapCatApp.swift") {
                $0.appending("\ntypealias ZZ = `ApprovalIntake`") }, Self.intakeTypeFailures),
            ("the intake extended behind a block comment", Self.mutate(sources, "NapCatApp.swift") {
                $0.appending("\nextension /* x */ NapCat.ApprovalIntake {}") }, Self.intakeTypeFailures),
            ("an unconstrained Optional extension", Self.adding(sources, "ZZMaybe.swift",
                "extension Optional {\n    func zzMap<R>(_ body: (Wrapped) -> R) -> R? { nil }\n}\n"), Self.optionalFailures),
            ("a qualified Optional, backticked", Self.mutate(sources, "NapCatApp.swift") {
                $0.appending("\nextension Swift.`Optional` where Wrapped: Sendable {}") }, Self.optionalFailures),
            ("an extension of an optional's sugar", Self.mutate(sources, "NapCatApp.swift") {
                $0.appending("\nextension Int? {\n    func zz() {}\n}") }, Self.optionalFailures),
            ("a generic alias of an optional, then a map every optional's resolves to", Self.adding(sources, "ZZAlias.swift", Self.aliasMap),
             Self.optionalFailures),
            ("an alias of a concrete optional, extended", Self.mutate(sources, "ApprovalWire.swift") {
                $0.appending("\ntypealias ZZ = PromptID?\nextension ZZ {}") }, Self.optionalFailures),
            ("an alias whose optional starts on the next line", Self.mutate(sources, "NapCatApp.swift") {
                $0.appending("\ntypealias ZZ = // x\n    Int?") }, Self.optionalFailures),
        ]
        let pinsHere: [(Sources) -> [String]] = [{ Self.wholeFailures($0, door) }, Self.intakeTypeFailures, Self.optionalFailures]
        for (name, mutant, own) in byPin {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!own(mutant).isEmpty, "canary '\(name)' was NOT caught by its pin")
            let caughtBy: Int = pinsHere.filter { $0(mutant) != $0(sources) }.count
            #expect(caughtBy == 1 && Self.sinkFailures(mutant) == Self.sinkFailures(sources),
                    "canary '\(name)' is one pin's alone: \(caughtBy) caught it")
        }
        // Over-match controls: names that only contain the pinned words, an
        // optional value, an extension of another type, the door reflowed and
        // commented, and whole-line comments naming them.
        let controls: Sources = Self.mutate(Self.mutate(sources, "NapCatApp.swift") {
            $0.appending("\nlet isOptionalCount = 0, extensionCount = 1\nstruct ApprovalIntakeLog {}\nlet zzMaybe: Int? = nil"
                + "\nextension PromptID {}" + LidGuardStructureTests.wholeLineCommentsRemoved(
                    "\n/// never extension Optional, never extension Int?, never typealias M<T> = T?, never ApprovalIntake"))
        }, host) {
            $0.replacingOccurrences(of: Self.doorBinding, with: "        return queue.sync { // the seam's queue\n"
                + "            guard  let  intake  else  {  return  nil  }\n\n            return body(intake)\n        }\n")
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        for pin in pinsHere {
            #expect(pin(controls).isEmpty, "over-match: \(pin(controls))")
        }
        // Each ban's pattern bites through the lock's own engine.
        let probes: [(String, String)] = [
            (Self.optionalSites[1].pattern, "extension\n    ApprovalIntake?\n{"),
            (Self.optionalAliasPattern, "typealias M<T> = /* x */\n    T?"),
        ]
        for (pattern, probe) in probes {
            #expect(Self.hits(pattern, in: probe), "'\(pattern)' does not match '\(probe)'")
        }
    }

    /// D5b's anchor (the head of the intake's `receive` checks) and its plant,
    /// verbatim: a second, hand-built verdict frame, keyed on the request ID
    /// alone — no decision at all.
    static let receiveAnchor: String = "        prune()\n        guard !prompts.values.contains(where:"
    static let d5bFrame: String = #"""
                if request.requestID.text == "zzzzz" {
                    sendFrame(connection, "{\"frame\":\"verdict\",\"v\":1,\"request\":\"zzzzz\",\"verdict\":\"allow\"}")
                }

        """#

    @Test func theIntakesFrameWriterIsNamedAtTodaysSites() throws {
        let sources = try Self.uncutSources()
        #expect(Self.frameWriterFailures(sources).isEmpty, "\(Self.frameWriterFailures(sources))")
        let intake: String = ApprovalChannelStructureTests.intakeFile
        #expect(Self.text(intake, in: sources).contains(Self.receiveAnchor), "vacuity: D5b's anchor is in the intake")
        let d5b: Sources = Self.mutate(sources, intake) {
            $0.replacingOccurrences(of: Self.receiveAnchor, with: Self.d5bFrame + Self.receiveAnchor) }
        #expect(!Self.frameWriterFailures(d5b).isEmpty, "D5b was NOT caught by the frame writer's pin alone")
        #expect(Self.sinkFailures(d5b) == Self.sinkFailures(sources)
                    && Self.wholeFailures(d5b, Self.roadPins) == Self.wholeFailures(sources, Self.roadPins), "D5b is the frame writer's pin to catch")
        let planted: (String) -> Sources = { line in
            Self.mutate(sources, intake) { $0.replacingOccurrences(of: Self.receiveAnchor, with: line + Self.receiveAnchor) }
        }
        let mutants: [(String, Sources)] = [
            ("a frame on the request's size alone", planted("        if request.inputPreview.utf8.count == 4_242 { sendFrame(connection, \"{}\") }\n")),
            ("the writer handed on", Self.mutate(sources, intake) {
                $0.appending("\nextension ApprovalIntake {\n    func zzWriter() -> (ConnectionKey, String) -> Void { sendFrame }\n}") }),
            ("the writer called, backticked", planted("        `sendFrame`(connection, \"{}\")\n")),
            ("the writer behind a block comment", planted("        self./* x */sendFrame(connection, \"{}\")\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.frameWriterFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: a name that only contains the writer's, and a
        // whole-line comment naming it.
        #expect(Self.frameWriterFailures(Self.mutate(sources, intake) {
            $0.appending("\nlet sendFrameCount = 0, frames = 1" + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never sendFrame(c, x)"))
        }).isEmpty)
    }

    /// The host's connection writes: a connection's one write, `send`, named
    /// on one line, the frame writer the host hands its intake.
    static let hostWriteSites: [String: Int] = [
        "sendFrame: { [weak self] key, line in self?.connections[key]?.send(line) },": 1,
    ]

    /// `sources`: `uncutSources()`.
    static func hostWriteFailures(_ sources: Sources) -> [String] {
        let host = ApprovalChannelStructureTests.hostFile
        return absent([host], in: sources)
            + PairingStructureTests.appSiteFailures(#"\bsend\b"#, in: sources.filter { $0.name == host }, allowed: [host: hostWriteSites],
                                                    rule: "the host writes to a connection at today's site alone — the frame writer it hands its intake")
    }

    /// The anchor in the host's line handler, and a second, hand-built
    /// verdict frame written beside it through the host's connection send,
    /// keyed on the request ID alone: no decision, no frame writer.
    static let lineHandlerAnchor: String = "                             self?.armIdleTimer(key)\n"
    static let hostFrame: String = #"""
                                     if String(decoding: $0, as: UTF8.self).contains("\"request\":\"zzzzz\"") {
                                         self?.connections[key]?.send("{\"frame\":\"verdict\",\"v\":1,\"request\":\"zzzzz\",\"verdict\":\"allow\"}")
                                     }

        """#

    @Test func theHostsConnectionWritesAreNamedAtTodaysSites() throws {
        let sources = try Self.uncutSources()
        #expect(Self.hostWriteFailures(sources).isEmpty, "\(Self.hostWriteFailures(sources))")
        let host: String = ApprovalChannelStructureTests.hostFile
        #expect(Self.text(host, in: sources).contains(Self.lineHandlerAnchor), "vacuity: the canary's anchor is in the host")
        // The hand-built frame, caught by this pin, and by the host's
        // connection words (it names a connection); every other pin reads it
        // exactly as it reads the tree.
        let written: Sources = Self.mutate(sources, host) {
            $0.replacingOccurrences(of: Self.lineHandlerAnchor, with: Self.hostFrame + Self.lineHandlerAnchor) }
        #expect(written.map { $0.text } != sources.map { $0.text }, "the hand-built frame did not apply")
        #expect(!Self.hostWriteFailures(written).isEmpty, "the hand-built frame was NOT caught by the host's write pin")
        let others: [String] = Self.othersCatching(written, besides: "host writes", baseline: Self.pinBaseline(sources))
        let expected: [String] = ["connection words"]
        #expect(others == expected, "the hand-built frame is the host's write pin's and the connection words': \(others)")
        let planted: (String) -> Sources = { line in
            Self.mutate(sources, host) { $0.replacingOccurrences(of: Self.lineHandlerAnchor, with: line + Self.lineHandlerAnchor) }
        }
        let mutants: [(String, Sources)] = [
            ("a frame written as a connection is accepted", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: "        connections[key] = connection\n",
                                        with: "        connections[key] = connection\n        connection.send(\"{}\")\n") }),
            ("a frame written as the idle timer fires", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: "        intake?.tick()\n", with: "        connection.send(\"{}\")\n        intake?.tick()\n") }),
            ("the writer's own line handed another frame", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: "self?.connections[key]?.send(line)", with: "self?.connections[key]?.send(line.isEmpty ? line : \"{}\")") }),
            ("the send called, backticked", planted("                             self?.connections[key]?.`send`(\"{}\")\n")),
            ("the send behind a block comment", planted("                             self?.connections[key]?./* x */send(\"{}\")\n")),
            ("the send taken unapplied", Self.mutate(sources, host) { $0.appending("\nlet zzWrite = SeamConnection.send") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.hostWriteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned word, and a
        // whole-line comment naming it.
        let controls: Sources = Self.mutate(sources, host) {
            $0.appending("\nlet sendCount = 0, resend = 1, sends = 2, isSendable = true"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never connection.send(frame)"))
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.hostWriteFailures(controls).isEmpty, "over-match: \(Self.hostWriteFailures(controls))")
    }

    /// Every line naming the connection's type in the four targets: its
    /// declaration and the listener's and the client's lines in its own
    /// file, the server's conformance, and the host's two lines.
    static let connectionTypeSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.seamFile: [
            "public final class SeamConnection: @unchecked Sendable {": 1,
            "public func start(onConnection: @escaping (SeamConnection) -> Void, onRefused: @escaping () -> Void = {}) -> Bool {": 1,
            "onConnection(SeamConnection(descriptor: client, peer: peer, queue: queue, stallTimeout: stallTimeout))": 1,
            "ownUID: uid_t = geteuid()) -> SeamConnection? {": 1,
            "return SeamConnection(descriptor: descriptor, peer: peer, queue: queue)": 1],
        ApprovalChannelStructureTests.serverFile: ["extension SeamConnection: ChannelLink {}": 1],
        ApprovalChannelStructureTests.hostFile: [
            "private var connections: [ApprovalIntake.ConnectionKey: SeamConnection] = [:]": 1,
            "private func accept(_ connection: SeamConnection) {": 1],
    ]

    /// `sources`: `uncutSources()`.
    static func connectionTypeFailures(_ sources: Sources) -> [String] {
        absent(connectionTypeSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(#"\bSeamConnection\b"#, in: sources, allowed: connectionTypeSites,
                                                    rule: "the connection type is named at today's sites alone — nothing new extends it or wraps its writer by name")
    }

    /// The host's write pin, one hop out: a member of the connection's type,
    /// declared in another file, that writes a hand-built verdict frame, and
    /// the host's line handler calling it, keyed on the request ID alone. No
    /// line of the host spells `send`.
    static let connectionWrapper: String = #"""
        import NapCatSeam

        extension SeamConnection {
            func zzAllow(_ request: String) {
                send("{\"frame\":\"verdict\",\"v\":1,\"request\":\"" + request + "\",\"verdict\":\"allow\"}")
            }
        }

        """#
    static let wrapperCall: String = #"""
                                     if String(decoding: $0, as: UTF8.self).contains("\"request\":\"zzzzz\"") {
                                         self?.connections[key]?.zzAllow("zzzzz")
                                     }

        """#

    @Test func theConnectionTypeIsNamedAtTodaysSites() throws {
        let sources = try Self.uncutSources()
        #expect(Self.connectionTypeFailures(sources).isEmpty, "\(Self.connectionTypeFailures(sources))")
        let host: String = ApprovalChannelStructureTests.hostFile
        #expect(Self.text(host, in: sources).contains(Self.lineHandlerAnchor), "vacuity: the wrapper's call has its anchor in the host")
        // The wrapper, caught by this pin, by the host's connection words (its
        // call names a connection) and by the extension pin (it is one); every
        // other pin, the host's write pin among them, reads it exactly as it
        // reads the tree.
        let wrapped: Sources = Self.mutate(Self.adding(sources, "ZZLink.swift", Self.connectionWrapper), host) {
            $0.replacingOccurrences(of: Self.lineHandlerAnchor, with: Self.wrapperCall + Self.lineHandlerAnchor) }
        #expect(Self.text(host, in: wrapped) != Self.text(host, in: sources), "the wrapper's call did not apply")
        #expect(!Self.connectionTypeFailures(wrapped).isEmpty, "the wrapper was NOT caught by the connection type's pin")
        let others: [String] = Self.othersCatching(wrapped, besides: "connection type", baseline: Self.pinBaseline(sources))
        let expected: [String] = ["connection words", "extensions"]
        #expect(others == expected, "the wrapper is these three pins' to catch: \(others)")
        let app: String = "NapCatApp.swift"
        let mutants: [(String, Sources)] = [
            ("the connection's send taken unapplied in another file", Self.mutate(sources, app) {
                $0.appending("\nlet zzWrite = SeamConnection.send") }),
            ("the connection aliased, then extended", Self.mutate(sources, app) {
                $0.appending("\ntypealias ZZLink = SeamConnection\nextension ZZLink {\n    func zzWrite() { send(\"{}\") }\n}") }),
            ("the connection aliased, qualified and backticked", Self.mutate(sources, app) {
                $0.appending("\ntypealias ZZLink = NapCatSeam.`SeamConnection`") }),
            ("the server's conformance given a member", Self.mutate(sources, ApprovalChannelStructureTests.serverFile) {
                $0.replacingOccurrences(of: "extension SeamConnection: ChannelLink {}",
                                        with: "extension SeamConnection: ChannelLink { func zz() {} }") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.connectionTypeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the type's, and a
        // whole-line comment naming it.
        let controls: Sources = Self.mutate(Self.mutate(sources, app) {
            $0.appending("\nstruct SeamConnectionLog {}\nlet zzSeamConnection = 0, SeamConnections = 1"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never extension SeamConnection { func zz() { send(frame) } }"))
        }, host) { $0.appending("\nlet isSeamConnectionOpen = false") }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.connectionTypeFailures(controls).isEmpty, "over-match: \(Self.connectionTypeFailures(controls))")
    }

    /// The host's words for its connections, at today's lines.
    static let hostConnectionSites: [String: Int] = [
        "closeConnection: { [weak self] key in self?.connections[key]?.close() },": 1,
        "connection.close()": 2,
        "connection.start(onLine: { [weak self] in": 1,
        "connections.removeAll()": 1,
        "connections[key] = connection": 2,
        "for connection in open { connection.close() }": 2,
        "guard connections.count < limits.maxConnections else {": 1,
        "guard connections[key] != nil else { return }": 1,
        "guard let connection = connections[key] else { return }": 2,
        "let open = Array(connections.values)": 1,
        "private func accept(_ connection: SeamConnection) {": 1,
        "private var connections: [ApprovalIntake.ConnectionKey: SeamConnection] = [:]": 1,
        "self?.connections[key] = nil": 1,
        "sendFrame: { [weak self] key, line in self?.connections[key]?.send(line) },": 1,
    ]
    /// The host's peer reader: taken at its initializer, handed to its listener.
    static let hostPeerReaderSites: [String: Int] = [
        "listener = SeamListener(socketPath: socketPath, queue: queue, peerReader: peerReader,": 2,
        "peerReader: @escaping (Int32) -> SeamPeer? = SeamSocket.peer(of:), limits: Limits = .standard) {": 1,
    ]
    /// The seam file's one `send` (the connection's write) and one `write`.
    static let seamSendSites: [String: Int] = ["public func send(_ line: String) -> Bool {": 1]
    static let seamWriteSites: [String: Int] = [
        "let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }": 1,
    ]
    /// Every line of the seam file naming a descriptor.
    static let seamDescriptorSites: [String: Int] = [
        "&& flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0": 1,
        "&& setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0": 1,
        "Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0": 1,
        "Darwin.close(descriptor)": 5,
        "Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0": 1,
        "Darwin.listen(descriptor, SeamSocket.listenBacklog) == 0 else {": 1,
        "SeamSocket.bind(descriptor, to: address), chmod(path, 0o600) == 0,": 1,
        "guard SeamSocket.configureConnected(descriptor), SeamPeerPolicy.accepts(peer, ownUID: ownUID), let peer else {": 1,
        "guard descriptor >= 0 else { return nil }": 1,
        "guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {": 1,
        "guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,": 1,
        "guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0,": 1,
        "guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,": 1,
        "init(descriptor: Int32, peer: SeamPeer, queue: DispatchQueue, stallTimeout: Double = SeamSocket.stallTimeoutSeconds,": 1,
        "let client = Darwin.accept(descriptor, nil, nil)": 1,
        "let count = read(descriptor, &buffer, buffer.count)": 1,
        "let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)": 1,
        "let descriptor = SeamSocket.makeSocket() else { return false }": 1,
        "let descriptor = SeamSocket.makeSocket() else { return nil }": 1,
        "let descriptor = self.descriptor": 2,
        "let flags = fcntl(descriptor, F_GETFL)": 2,
        "let peer = SeamSocket.connect(descriptor, to: address) ? peerReader(descriptor) : nil": 2,
        "let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)": 2,
        "let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }": 1,
        "onConnection(SeamConnection(descriptor: client, peer: peer, queue: queue, stallTimeout: stallTimeout))": 1,
        "private let descriptor: Int32": 1,
        "public static func peer(of descriptor: Int32) -> SeamPeer? {": 1,
        "return SeamConnection(descriptor: descriptor, peer: peer, queue: queue)": 2,
        "return descriptor": 1,
        "return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0": 1,
        "self.descriptor = descriptor": 2,
        "source.setCancelHandler { Darwin.close(descriptor) }": 2,
        "static func bind(_ descriptor: Int32, to address: sockaddr_un) -> Bool {": 1,
        "static func configureConnected(_ descriptor: Int32) -> Bool {": 1,
        "static func connect(_ descriptor: Int32, to address: sockaddr_un) -> Bool {": 1,
        "var room = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)": 1,
    ]
    /// Each word pin: its file, its pattern, today's lines.
    static let connectionWordPins: [(file: String, pattern: String, allowed: [String: Int])] = [
        (ApprovalChannelStructureTests.hostFile, #"\bconnections?\b"#, hostConnectionSites),
        (ApprovalChannelStructureTests.hostFile, #"\bpeerReader\b"#, hostPeerReaderSites),
        (ApprovalChannelStructureTests.seamFile, #"\bsend\b"#, seamSendSites),
        (ApprovalChannelStructureTests.seamFile, #"\bwrite\b"#, seamWriteSites),
        (ApprovalChannelStructureTests.seamFile, #"\bdescriptor\b"#, seamDescriptorSites),
    ]

    /// `sources`: `uncutSources()`.
    static func connectionWordFailures(_ sources: Sources) -> [String] {
        var failures: [String] = absent([ApprovalChannelStructureTests.hostFile, ApprovalChannelStructureTests.seamFile], in: sources)
        for pin in connectionWordPins {
            failures += PairingStructureTests.appSiteFailures(pin.pattern, in: sources.filter { $0.name == pin.file },
                                                              allowed: [pin.file: pin.allowed],
                                                              rule: "a connection, its peer reader and its writes are named at today's lines alone")
        }
        return unique(failures)
    }

    /// The re-check's three residual plants, verbatim. RES1's member, inside
    /// the connection type's own body, before its `close()`.
    static let seamCloseAnchor: String = "    /// Closes the connection (idempotent).\n    public func close() {\n"
    static let seamMember: String = #"""
            public func zzAllow(_ request: String) {
                send("{\"frame\":\"verdict\",\"v\":1,\"request\":\"" + request + "\",\"verdict\":\"allow\"}")
            }


        """#
    /// RES2's file, verbatim.
    static let rawDescriptorWrite: String = #"""
        import Foundation

        // Security delta re-check replant (never committed): the engineer's "raw
        // descriptor road". The accepted client's descriptor is seen by the host's
        // peer reader; a hand-built verdict frame is written to it with write(2).
        final class ZZSeen: @unchecked Sendable {
            var last: Int32 = -1
        }

        let zzSeenBox = ZZSeen()

        func zzSeen(_ descriptor: Int32) { zzSeenBox.last = descriptor }

        func zzRaw(_ line: [UInt8]) {
            guard String(decoding: line, as: UTF8.self).contains("\"request\":\"zzzzz\"") else { return }
            let frame = "{\"frame\":\"verdict\",\"v\":1,\"request\":\"zzzzz\",\"verdict\":\"allow\"}\n"
            _ = write(zzSeenBox.last, frame, frame.utf8.count)
        }

        """#
    static let listenerLine: String = "        listener = SeamListener(socketPath: socketPath, queue: queue, peerReader: peerReader,\n"
    /// RES3's file, verbatim.
    static let inferredWrite: String = #"""
        import Foundation
        import NapCatSeam

        // Security delta re-check replant (never committed): the engineer's
        // "inferred-type use". The connection's type is never spelled: it is
        // inferred from the client's return value, and the host hands its own
        // connection in as a generic value. No line of the host spells the writer.
        func zzCast<C>(_ like: C?, _ value: Any) -> C? { value as? C }

        func zzNote<C>(_ connection: C?, _ line: [UInt8]) {
            guard String(decoding: line, as: UTF8.self).contains("\"request\":\"zzzzz\"") else { return }
            let like = line.isEmpty ? SeamClient.connect(socketPath: "", queue: .main) : nil
            _ = zzCast(like, connection as Any)?.send("{\"frame\":\"verdict\",\"v\":1,\"request\":\"zzzzz\",\"verdict\":\"allow\"}")
        }

        """#
    /// The host's line handler, where RES2 and RES3 call their files.
    static let handlerIndent: String = String(repeating: " ", count: 29)

    /// A connection's writer is reached from no new line of the host or the
    /// seam file: the host names its connections and its peer reader at
    /// today's lines, and the seam file its send, its write and its
    /// descriptor. The re-check's residual plants, verbatim, as the disk
    /// would hold them: a writer reached through the connection type's own
    /// body (RES1), through a descriptor (RES2) and through an inferred type
    /// (RES3). Each is caught by these pins alone: every other pin of this
    /// suite reads it as the tree.
    @Test func aConnectionsWriterIsNamedAtTodaysSites() throws {
        let raw: Sources = try ApprovalChannelStructureTests.sources { $0 }
        let sources: Sources = Self.uncut(raw)
        #expect(Self.connectionWordFailures(sources).isEmpty, "\(Self.connectionWordFailures(sources))")
        let host: String = ApprovalChannelStructureTests.hostFile
        let seam: String = ApprovalChannelStructureTests.seamFile
        let handlerCall: (String) -> PlantedLine = { call in
            (host, Self.lineHandlerAnchor, Self.handlerIndent + call + "\n" + Self.lineHandlerAnchor)
        }
        let member: String = Self.seamMember + Self.seamCloseAnchor
        let call: String = Self.wrapperCall + Self.lineHandlerAnchor
        let res1: [PlantedLine] = [(seam, Self.seamCloseAnchor, member), (host, Self.lineHandlerAnchor, call)]
        let res2: [PlantedLine] = [(host, Self.listenerLine, Self.listenerLine.replacingOccurrences(
                                        of: "peerReader: peerReader,", with: "peerReader: { zzSeen($0); return peerReader($0) },")),
                                   handlerCall("zzRaw($0)")]
        let res3: [PlantedLine] = [handlerCall("zzNote(self?.connections[key], $0)")]
        var anchors: [PlantedLine] = res1
        anchors.append(contentsOf: res2)
        for line in anchors {
            #expect(ApprovalChannelStructureTests.count(line.anchor, in: Self.text(line.file, in: raw)) == 1,
                    "vacuity: '\(line.anchor.prefix(60))' is in \(line.file) once")
        }
        var withRaw: Sources = Self.planting(raw, res2)
        withRaw.append(("ZZRaw.swift", Self.rawDescriptorWrite))
        var withInferred: Sources = Self.planting(raw, res3)
        withInferred.append(("ZZInferred.swift", Self.inferredWrite))
        let reviewed: [(name: String, planted: Sources)] = [
            ("RES1: a member writing a hand-built frame, inside the connection type's body", Self.uncut(Self.planting(raw, res1))),
            ("RES2: the descriptor kept from the host's peer reader, written from a new file", Self.uncut(withRaw)),
            ("RES3: the host's connection handed to a new file as a generic value", Self.uncut(withInferred)),
        ]
        let baseline: [String: [String]] = Self.pinBaseline(sources)
        for (name, planted) in reviewed {
            #expect(planted.map { $0.text } != sources.map { $0.text }, "\(name) did not apply")
            #expect(!Self.connectionWordFailures(planted).isEmpty, "\(name) was NOT caught by the connection words' pins")
            let others: [String] = Self.othersCatching(planted, besides: "connection words", baseline: baseline)
            #expect(others.isEmpty, "\(name) is the connection words' to catch, but \(others) caught it too")
        }
        // More canaries, one per pin.
        let mutants: [(String, Sources)] = [
            ("the host's connection handed on as it is accepted", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: "        connections[key] = connection\n", with: "        connections[key] = connection\n        zzKeep(connection)\n") }),
            ("the host's connections read behind a block comment", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: Self.lineHandlerAnchor, with: "                             zzKeep(self?./* x */connections)\n" + Self.lineHandlerAnchor) }),
            ("the host's peer reader handed to a new call", Self.mutate(sources, host) {
                $0.replacingOccurrences(of: "        self.audit = audit\n", with: "        self.audit = audit\n        zzKeep(peerReader)\n") }),
            ("a second send in the seam file", Self.mutate(sources, seam) { $0.appending("\nfunc zz(_ c: SeamConnection) { _ = c.send(\"{}\") }") }),
            ("a write by number in the seam file", Self.mutate(sources, seam) {
                $0.replacingOccurrences(of: "    private let descriptor: Int32\n", with: "    private let descriptor: Int32\n    func zz() { _ = Darwin.write(3, \"{}\", 2) }\n") }),
            ("the descriptor handed out", Self.mutate(sources, seam) {
                $0.replacingOccurrences(of: "    private let descriptor: Int32\n", with: "    private let descriptor: Int32\n    public var zzHandle: Int32 { `descriptor` }\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.connectionWordFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: names that only contain the pinned words, and
        // whole-line comments naming them.
        let controls: Sources = Self.mutate(Self.mutate(sources, host) {
            $0.appending("\nlet connectionCount = 0, reconnection = 1, peerReaderCount = 2, isConnectionOpen = false"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never zzNote(self?.connections[key]), never peerReader: { $0 }"))
        }, seam) {
            $0.appending("\nlet sendCount = 0, rewrite = 1, writes = 2, descriptors = 3, fileDescriptor = 4"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never write(descriptor, frame), never send(frame)"))
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.connectionWordFailures(controls).isEmpty, "over-match: \(Self.connectionWordFailures(controls))")
    }

    /// D2's anchors (the slot's read, commit and unpair) and its plant,
    /// verbatim: a reading kept per handle, forgotten on the handle's own
    /// commit or unpair alone.
    static let slotRead: String = """
            func read() -> PairedPhoneRead {
                switch items.read() {
                case .found(let text): return Self.phone(from: text).map(PairedPhoneRead.paired) ?? .unreadable
                case .notFound: return .notPaired
                case .failed: return .unreadable
                }
            }

        """
    static let slotReadKept: String = """
            private let zzKept = ZZKept()

            func read() -> PairedPhoneRead {
                if let kept = zzKept.value { return kept }
                let now: PairedPhoneRead
                switch items.read() {
                case .found(let text): now = Self.phone(from: text).map(PairedPhoneRead.paired) ?? .unreadable
                case .notFound: now = .notPaired
                case .failed: now = .unreadable
                }
                zzKept.value = now
                return now
            }

        """
    static let slotCommit: String = """
            func commit(_ phone: PairedPhone) -> Bool {
                items.write(Self.text(of: phone))
            }

        """
    static let slotCommitForgetting: String = """
            func commit(_ phone: PairedPhone) -> Bool {
                zzKept.value = nil
                return zzWrite(phone)
            }

            private func zzWrite(_ phone: PairedPhone) -> Bool {
                items.write(Self.text(of: phone))
            }

        """
    static let slotUnpair: String = """
            func unpair() -> Bool {
                items.delete()
            }

        """
    static let slotUnpairForgetting: String = """
            func unpair() -> Bool {
                zzKept.value = nil
                return zzDelete()
            }

            private func zzDelete() -> Bool {
                items.delete()
            }

        """
    static let slotKeptTail: String = "\nfinal class ZZKept: @unchecked Sendable { var value: PairedPhoneRead? }\n"

    @Test func theSlotsReadIsPinnedWhole() throws {
        let sources = try Self.uncutSources()
        let pin: [WholePin] = [Self.slotReadPin]
        #expect(Self.wholeFailures(sources, pin).isEmpty, "\(Self.wholeFailures(sources, pin))")
        let slot: String = PairingStructureTests.slotFile
        for anchor in [Self.slotRead, Self.slotCommit, Self.slotUnpair] {
            #expect(Self.text(slot, in: sources).contains(anchor), "vacuity: D2's anchor '\(anchor.prefix(40))' is in the slot")
        }
        let d2: Sources = Self.mutate(sources, slot) {
            $0.replacingOccurrences(of: Self.slotRead, with: Self.slotReadKept)
                .replacingOccurrences(of: Self.slotCommit, with: Self.slotCommitForgetting)
                .replacingOccurrences(of: Self.slotUnpair, with: Self.slotUnpairForgetting) + Self.slotKeptTail
        }
        #expect(d2.map { $0.text } != sources.map { $0.text }, "D2 did not apply")
        #expect(!Self.wholeFailures(d2, pin).isEmpty, "D2 was NOT caught by the read's pin alone")
        #expect(Self.sinkFailures(d2) == Self.sinkFailures(sources), "D2 is the read's pin to catch")
        let secondRead: String = "    func read(_ zz: Int) -> PairedPhoneRead { .notPaired }\n\n" + Self.slotCommit
        let mutants: [(String, Sources)] = [
            ("a reading answered from elsewhere", Self.mutate(sources, slot) {
                $0.replacingOccurrences(of: "        case .notFound: return .notPaired\n", with: "        case .notFound: return zzFallback()\n") }),
            ("read made dynamic", Self.mutate(sources, slot) {
                $0.replacingOccurrences(of: "    func read() -> PairedPhoneRead {\n", with: "    dynamic func read() -> PairedPhoneRead {\n") }),
            ("a second read beside it", Self.mutate(sources, slot) { $0.replacingOccurrences(of: Self.slotCommit, with: secondRead) }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.wholeFailures(mutant, pin).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: reflowed, and commented inside.
        #expect(Self.wholeFailures(Self.mutate(sources, slot) {
            $0.replacingOccurrences(of: "        case .notFound: return .notPaired\n",
                                    with: "        // nothing stored\n        case .notFound:\n            return .notPaired // fail-dark\n")
        }, pin).isEmpty)
    }

    // MARK: - h. One manifest at the root

    /// The repository root's `Package*.swift` files are exactly
    /// `Package.swift` (read case-insensitively): SwiftPM prefers a
    /// version-specific manifest (`Package@swift-6.swift`) over it, and that
    /// one's targets are nothing e. reads.
    static func rootManifestFailures(_ names: [String]) -> [String] {
        let manifests: [String] = names.filter { $0.lowercased().hasPrefix("package") && $0.lowercased().hasSuffix(".swift") }.sorted()
        return manifests == ["Package.swift"] ? [] : ["the repository root holds one manifest, Package.swift — found \(manifests)"]
    }

    @Test func theRootHoldsOneManifest() throws {
        let names: [String] = try FileManager.default.contentsOfDirectory(atPath: LidGuardStructureTests.repoRoot().path)
        #expect(Self.rootManifestFailures(names).isEmpty, "\(Self.rootManifestFailures(names))")
        #expect(names.contains("Package.swift") && names.contains("Sources"), "vacuity: the root is the repository's")
        let plus: (String) -> [String] = { name in
            var all: [String] = names
            all.append(name)
            return all
        }
        let mutants: [(String, [String])] = [
            ("P6V: a version-specific manifest, Package.swift untouched", plus("Package@swift-6.swift")),
            ("a minor version's manifest", plus("Package@swift-6.4.swift")),
            ("a patch version's manifest", plus("Package@swift-5.10.1.swift")),
            ("a manifest of another case", plus("package@swift-6.swift")),
            ("the manifest gone", names.filter { $0 != "Package.swift" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.rootManifestFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: the resolved pins, a folder and notes that only
        // start like a manifest.
        let controls: [String] = ["Package.resolved", "Packages", "PackageNotes.md", "Package.swift.orig", ".swiftpm"]
        var withControls: [String] = names.filter { !controls.contains($0) }
        withControls.append(contentsOf: controls)
        #expect(Self.rootManifestFailures(withControls).isEmpty, "\(Self.rootManifestFailures(withControls))")
    }

    // MARK: - i. No new extension, no new operator implementation

    /// Every line of the four targets holding the word `extension`: today's
    /// twelve headers.
    static let extensionSites: [String: [String: Int]] = [
        ApprovalChannelStructureTests.intakeFile: ["extension ApprovalClassification {": 1],
        "FinishAlertController.swift": ["extension LidGuardController: FinishAlertConfigSource {": 1],
        "KeychainTopicStore.swift": [
            "extension KeychainTopicStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1],
        PairingStructureTests.slotFile: [
            "extension PairedKeyStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1],
        PairingStructureTests.ceremonyFile: [
            "extension PairingCeremonyState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1,
            "extension PairingEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1],
        PairingStructureTests.sheetFile: [
            "extension PairingSheetContent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1,
            "extension QRCodeView: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {": 1],
        ApprovalChannelStructureTests.toggleFile: ["extension WaitingPromptCounts {": 1],
        "SettingsContent.swift": ["extension MenuStateModel {": 1],
        ApprovalChannelStructureTests.serverFile: ["extension SeamConnection: ChannelLink {}": 1],
        "ApprovalChannel.swift": ["extension ApprovalChannel {": 1],
    ]
    /// A `func` named by anything but an ASCII identifier: an operator's
    /// implementation (custom operators are banned outright, by
    /// `LidGuardStructureTests.noSourceDeclaresAnOperator`). A comment or a
    /// line break between the word and the name is a site too.
    static let operatorImplementationPattern: String = #"\bfunc\s*[^\sA-Za-z0-9_`(]"#
    /// Today's two: each type's own `<`, for its own values.
    static let operatorImplementationSites: [String: [String: Int]] = [
        "MenuStateModel.swift": ["static func < (lhs: PanelSeverity, rhs: PanelSeverity) -> Bool { lhs.rawValue < rhs.rawValue }": 1],
        "UpdateVersion.swift": ["static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {": 1],
    ]

    /// `sources`: `uncutSources()`.
    static func extensionFailures(_ sources: Sources) -> [String] {
        absent(extensionSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(#"\bextension\b"#, in: sources, allowed: extensionSites,
                                                    rule: "every extension in the four targets is today's — a new one could add a member a pinned line resolves to")
    }

    /// `sources`: `uncutSources()`.
    static func operatorImplementationFailures(_ sources: Sources) -> [String] {
        absent(operatorImplementationSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(operatorImplementationPattern, in: sources, allowed: operatorImplementationSites,
                                                    rule: "every operator implementation is today's — a new overload could take a pinned line's operator")
    }

    /// Every whole-body pin.
    static let allWholePins: [WholePin] = {
        var pins: [WholePin] = roadPins
        pins.append(doorPin)
        pins.append(slotReadPin)
        return pins
    }()
    /// Every pin of this suite that reads the four targets' sources, by
    /// name (the raw-text scalar lock among them: it reads any text).
    static var sourcePins: [(name: String, failures: (Sources) -> [String])] {
        [
            ("sinks", { Self.sinkFailures($0) }), ("whole bodies", { Self.wholeFailures($0, Self.allWholePins) }),
            ("intake type", { Self.intakeTypeFailures($0) }), ("Optional", { Self.optionalFailures($0) }),
            ("frame writer", { Self.frameWriterFailures($0) }), ("host writes", { Self.hostWriteFailures($0) }),
            ("connection type", { Self.connectionTypeFailures($0) }), ("connection words", { Self.connectionWordFailures($0) }),
            ("extensions", { Self.extensionFailures($0) }), ("operator implementations", { Self.operatorImplementationFailures($0) }),
            ("hidden scalars", { LidGuardStructureTests.hiddenScalarFailures($0) }),
        ]
    }
    /// Each pin's failures on `sources`, by name: what the "alone" checks
    /// compare a plant's reading to.
    static func pinBaseline(_ sources: Sources) -> [String: [String]] {
        var baseline: [String: [String]] = [:]
        for pin in sourcePins { baseline[pin.name] = pin.failures(sources) }
        return baseline
    }

    /// The pins, other than `own`, that read `planted` otherwise than their
    /// `baseline`, by name.
    static func othersCatching(_ planted: Sources, besides own: String, baseline: [String: [String]]) -> [String] {
        sourcePins.filter { $0.name != own && $0.failures(planted) != baseline[$0.name] }.map(\.name)
    }

    /// DICT1, verbatim: a subscript in a constrained extension of Dictionary,
    /// in a new file, that the intake's `prompts[id]` resolves to.
    static let dictionarySubscript: String = #"""
        import NapCatWire

        // Security delta re-check replant (never committed): a subscript in a
        // constrained extension of Dictionary, in a new file. The intake's pinned
        // `prompts[id]` lines are untouched and resolve here (a more constrained
        // member outranks the unconstrained one, as the door's Optional.map did).
        final class ZZSwap: @unchecked Sendable {
            var from: PromptID?
            var to: PromptID?
            var reads = 0
        }

        let zzSwap = ZZSwap()

        extension Dictionary where Key == PromptID {
            subscript(key: PromptID) -> Value? {
                get {
                    var wanted = key
                    if key == zzSwap.from, let other = zzSwap.to, "\(Value.self)" == "Entry" {
                        zzSwap.reads += 1
                        if zzSwap.reads == 2 { wanted = other }
                    }
                    return index(forKey: wanted).map { self[$0].value }
                }
                set {
                    if let newValue {
                        updateValue(newValue, forKey: key)
                    } else {
                        removeValue(forKey: key)
                    }
                }
            }
        }

        """#
    /// OP1b, verbatim: a concrete overload of the nil-coalescing operator,
    /// in a new file, that the slot's `read()` line resolves to.
    static let coalescingOverload: String = #"""
        import Foundation

        // Security delta re-check replant (never committed): a concrete overload of
        // the standard library's nil-coalescing in a new file. The slot's pinned line
        // (`... .map(PairedPhoneRead.paired) ?? .unreadable`) is untouched and
        // resolves here, since a concrete overload outranks the generic one.
        final class ZZReadSwap: @unchecked Sendable {
            /// When the slot holds `whenPaired`, its reading is `phone` instead.
            var whenPaired: PairedPhone?
            var phone: PairedPhone?
        }

        let zzReadSwap = ZZReadSwap()

        func ?? (reading: PairedPhoneRead?, fallback: @autoclosure () -> PairedPhoneRead) -> PairedPhoneRead {
            guard let reading else { return fallback() }
            if case .paired(let stored) = reading, let other = zzReadSwap.phone, zzReadSwap.whenPaired == stored { return .paired(other) }
            return reading
        }

        """#

    /// No new file or line adds an extension of any type, or an
    /// implementation of an operator: a member the compiler prefers at a
    /// pinned line (a constrained extension's subscript, a concrete
    /// overload) would take that line over with the line untouched. The
    /// re-check's plants, verbatim: DICT1 (the intake's `prompts[id]`) and
    /// OP1b (the slot's `??`), each caught by its own pin alone: every other
    /// pin of this suite reads it as the tree.
    @Test func everyExtensionAndOperatorImplementationIsTodays() throws {
        let sources = try Self.uncutSources()
        #expect(Self.extensionFailures(sources).isEmpty, "\(Self.extensionFailures(sources))")
        #expect(Self.operatorImplementationFailures(sources).isEmpty, "\(Self.operatorImplementationFailures(sources))")
        let reviewed: [(name: String, pin: String, planted: Sources)] = [
            ("DICT1: a constrained Dictionary subscript taking the intake's prompts[id]", "extensions",
             Self.adding(sources, "ZZSwapEntries.swift", Self.dictionarySubscript)),
            ("OP1b: a concrete ?? taking the slot's read() line", "operator implementations",
             Self.adding(sources, "ZZCoalesce.swift", Self.coalescingOverload)),
        ]
        let baseline: [String: [String]] = Self.pinBaseline(sources)
        for (name, pin, planted) in reviewed {
            let own: [(name: String, failures: (Sources) -> [String])] = Self.sourcePins.filter { $0.name == pin }
            #expect(own.count == 1 && own.allSatisfy { !$0.failures(planted).isEmpty }, "\(name) was NOT caught by its pin")
            let others: [String] = Self.othersCatching(planted, besides: pin, baseline: baseline)
            #expect(others.isEmpty, "\(name) is its own pin's to catch, but \(others) caught it too")
        }
        // More canaries: an extension in each target and spelled apart, and
        // an operator implemented in a type, at the top level, behind a
        // comment or a line break.
        let appended: (String, String) -> Sources = { file, text in Self.mutate(sources, file) { $0.appending(text) } }
        let extensions: [(String, Sources)] = [
            ("an extension in the seam", appended(ApprovalChannelStructureTests.seamFile, "\nextension SeamListener {}")),
            ("an extension in the wire", appended("ApprovalWire.swift", "\nextension PromptID {\n    var zz: Int { 0 }\n}")),
            ("an extension in the channel", appended(ApprovalChannelStructureTests.serverFile, "\nextension Array where Element == UInt8 {}")),
            ("a protocol extension in the app", appended("NapCatApp.swift", "\nextension Collection where Element == PromptID {}")),
            ("a header split over lines", appended("NapCatApp.swift", "\nextension\n    Dictionary where Key == PromptID {}")),
            ("a header behind a block comment", appended("NapCatApp.swift", "\nextension/* x */Dictionary {}")),
        ]
        let operators: [(String, Sources)] = [
            ("an equality in a new type", appended("NapCatApp.swift", "\nstruct ZZ { static func == (l: ZZ, r: ZZ) -> Bool { true } }")),
            ("a pattern match at the top level", appended("NapCatApp.swift", "\nfunc ~= (p: PromptID, v: PromptID) -> Bool { true }")),
            ("a prefix operator", appended("ApprovalWire.swift", "\nprefix func ! (b: Bool) -> Bool { b }")),
            ("behind a block comment", appended("NapCatApp.swift", "\nfunc/* x */?? (a: Int?, b: Int) -> Int { b }")),
            ("its name on the next line", appended("NapCatApp.swift", "\nfunc\n?? (a: Int?, b: Int) -> Int { b }")),
        ]
        for (name, mutant) in extensions {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.extensionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        for (name, mutant) in operators {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.operatorImplementationFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: words that only contain the pinned ones, plain
        // functions, operators used and not implemented, and whole-line
        // comments naming them.
        let controls: Sources = appended("NapCatApp.swift", [
            "\nlet extensionCount = 0, extensions = 1, isExtension = false, funcs = 2, myfunc = 3",
            "\nfunc reduce(_ x: Int) -> Int { x }\nfunc `default`() {}\nfunc _zz() {}\nfunc zz(_ a: Int?) -> Bool { (a ?? 0) == 1 && !true }",
            LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never extension Dictionary {}, never func ?? (a, b)"),
        ].joined())
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.extensionFailures(controls).isEmpty, "over-match: \(Self.extensionFailures(controls))")
        #expect(Self.operatorImplementationFailures(controls).isEmpty, "over-match: \(Self.operatorImplementationFailures(controls))")
        // The operator pattern bites through the lock's own engine.
        for probe in ["static func ==(l: A, r: A)", "func\t<", "func /* c */ ??"] {
            #expect(Self.hits(Self.operatorImplementationPattern, in: probe), "the pattern does not match '\(probe)'")
        }
    }
}
