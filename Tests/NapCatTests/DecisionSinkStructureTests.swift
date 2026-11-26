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
/// f. (with them, beyond the plan's four) the doors around the sink: the intake is reached from
///    outside the host only through `withIntake`, at its one use; the host
///    names its intake at today's lines; and inside the intake every
///    `apply` and `perform` is pinned — so a forged event or transition,
///    the sink's next hop, has no way in either.
///
/// Each check is a pure function over the sources and catches planted
/// canaries — the issue's byte-copy forge among them, decided from a new
/// file and replanted into the wired sink itself — beside over-match
/// controls, so none can pass vacuously.
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
        "intake?.killSwitch()": 1, "return queue.sync { intake.map(body) }": 1, "self?.intake?.receive($0, from: key)": 1,
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
}
