// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// F4 slice S1: structure locks over the channel server, the seam and the
/// intake — the rules the behaviour tests cannot prove by example. Each lock
/// is a pure function over the comment-stripped sources, and each catches a
/// planted mutant.
struct ApprovalChannelStructureTests {
    typealias Sources = [(name: String, text: String)]

    /// The S1 source directories (NapCatWire's own locks live in
    /// WireContractTests).
    static let directories = ["Sources/NapCat", "Sources/NapCatSeam", "Sources/NapCatChannel", "Sources/NapCatWire"]

    static let seamFile = "SeamSocket.swift"
    static let relayFile = "ChannelRelay.swift"
    static let serverFile = "ChannelServer.swift"
    static let intakeFile = "ApprovalIntake.swift"
    static let hostFile = "ApprovalSeamHost.swift"
    static let probeFile = "ChannelPolicyProbe.swift"
    /// The I/O files S1 added.
    static let s1Files = [seamFile, relayFile, serverFile, intakeFile, hostFile, probeFile]

    /// Every Swift source of the four targets, comment-stripped. (File names
    /// are unique across them.)
    static func sources() throws -> Sources {
        let root = LidGuardStructureTests.repoRoot()
        return try directories.flatMap { directory -> Sources in
            let url = root.appendingPathComponent(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }.sorted()
            return try names.map { ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8))) }
        }
    }

    static func text(_ name: String, in sources: Sources) -> String { sources.first { $0.name == name }?.text ?? "" }

    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
    }

    static func count(_ token: String, in text: String) -> Int { text.components(separatedBy: token).count - 1 }

    // MARK: - The seam's socket calls live in one file

    static let socketTokens = ["Darwin.socket(", "Darwin.bind(", "Darwin.listen(", "Darwin.accept(", "Darwin.connect(",
                               "getsockopt(", "setsockopt(", "LOCAL_PEERCRED", "LOCAL_PEERTOKEN", "socketpair("]

    static func socketConfinementFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != seamFile {
            for token in socketTokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — the seam's socket calls stay in \(seamFile)")
            }
        }
        let seam = text(seamFile, in: sources)
        for token in socketTokens.dropLast() where !seam.contains(token) {
            failures.append("'\(token)' not found in \(seamFile) — the lint would be vacuous")
        }
        return failures
    }

    @Test func theSeamsSocketCallsLiveInOneFile() throws {
        let sources = try Self.sources()
        #expect(Self.socketConfinementFailures(sources).isEmpty, "\(Self.socketConfinementFailures(sources))")
        for (file, planted) in [(Self.hostFile, "let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)"),
                                (Self.relayFile, "_ = getsockopt(0, 0, 0, nil, nil)"),
                                (Self.intakeFile, "let c = LOCAL_PEERCRED")] {
            #expect(!Self.socketConfinementFailures(Self.mutate(sources, file) { $0 + "\n" + planted }).isEmpty,
                    "canary in \(file) was NOT caught")
        }
    }

    // MARK: - Every connection passes the peer check

    /// The peer check runs on both ends — once in the listener's accept path,
    /// once in the client's connect path — and nothing else can make a
    /// connection: its initializer is internal to the seam.
    static func peerCheckFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let seam = text(seamFile, in: sources)
        let check = "SeamPeerPolicy.accepts(peer, ownUID: ownUID)"
        if count(check, in: seam) != 2 { failures.append("the peer check must guard exactly the accept and the connect paths") }
        if count("SeamConnection(descriptor:", in: seam) != 2 { failures.append("a connection is made only by the listener and the client") }
        for (fence, label) in [("Darwin.accept(descriptor, nil, nil)", "accept"), ("SeamSocket.connect(descriptor, to: address)", "connect")] {
            guard let start = seam.range(of: fence) else {
                failures.append("the \(label) path moved (lint would be vacuous)")
                continue
            }
            let after = seam[start.upperBound...]
            guard let checked = after.range(of: check), let made = after.range(of: "SeamConnection(descriptor:"),
                  checked.lowerBound < made.lowerBound else {
                failures.append("the \(label) path makes a connection before the peer check")
                continue
            }
        }
        if seam.contains("public init(descriptor") { failures.append("a connection must not be constructible outside the seam") }
        for (name, text) in sources where name != seamFile && text.contains("SeamConnection(descriptor:") {
            failures.append("\(name) builds a connection around the peer check")
        }
        return failures
    }

    @Test func everyConnectionPassesThePeerCheck() throws {
        let sources = try Self.sources()
        #expect(Self.peerCheckFailures(sources).isEmpty, "\(Self.peerCheckFailures(sources))")
        let check = "SeamPeerPolicy.accepts(peer, ownUID: ownUID)"
        let mutants: [(String, Sources)] = [
            ("the listener's check dropped", Self.mutate(sources, Self.seamFile) {
                $0.replacingOccurrences(of: "SeamSocket.configureConnected(client), " + check, with: "SeamSocket.configureConnected(client)") }),
            ("the client's check dropped", Self.mutate(sources, Self.seamFile) {
                $0.replacingOccurrences(of: "SeamSocket.configureConnected(descriptor), " + check, with: "SeamSocket.configureConnected(descriptor)") }),
            ("a public initializer", Self.mutate(sources, Self.seamFile) {
                $0.replacingOccurrences(of: "    init(descriptor: Int32", with: "    public init(descriptor: Int32") }),
            ("the host builds a connection", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet c = SeamConnection(descriptor: 3, peer: p, queue: q)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.peerCheckFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - One verdict site on each side of the seam

    /// The server emits a verdict in one place, right after taking the
    /// request out of its open set; NapCat writes a verdict frame in one
    /// place, the lifecycle's `.deliverVerdict`.
    static func verdictSiteFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let emitSite = "ApprovalChannel.verdictNotification("
        let frameSite = "ApprovalChannel.verdictFrame("
        for (name, text) in sources {
            let emits = count(emitSite, in: text)
            if name == relayFile ? emits != 1 : emits != 0 { failures.append("\(emits) verdict notification site(s) in \(name)") }
            let frames = count(frameSite, in: text)
            if name == intakeFile ? frames != 1 : frames != 0 { failures.append("\(frames) verdict frame site(s) in \(name)") }
        }
        let relay = text(relayFile, in: sources)
        if !relay.contains("guard open.remove(requestID) != nil else {\n            note(.verdictIgnored)\n            return\n        }\n        emit("
            + emitSite) {
            failures.append("the server's verdict must follow the open-request check directly")
        }
        let intake = text(intakeFile, in: sources)
        if !intake.contains("case .deliverVerdict(let verdict):\n                sendFrame(item.connection, " + frameSite) {
            failures.append("NapCat's verdict frame must be the lifecycle's .deliverVerdict")
        }
        return failures
    }

    @Test func eachSideHasOneVerdictSite() throws {
        let sources = try Self.sources()
        #expect(Self.verdictSiteFailures(sources).isEmpty, "\(Self.verdictSiteFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the open check dropped", Self.mutate(sources, Self.relayFile) {
                $0.replacingOccurrences(of: "guard open.remove(requestID) != nil else {", with: "guard true else {") }),
            ("the relay answers a prompt itself", Self.mutate(sources, Self.relayFile) {
                $0 + "\nfunc f(r: ChannelRequestID) { emit(ApprovalChannel.verdictNotification(requestID: r, verdict: .allow)) }" }),
            ("the host writes a verdict", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet v = ApprovalChannel.verdictFrame(id, .allow)" }),
            ("the intake answers on save", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: "case .supersedeWaitingAlert:\n", with: "case .supersedeWaitingAlert:\n                sendFrame(item.connection, ApprovalChannel.verdictFrame(item.request, .allow))\n") }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.verdictSiteFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - The gate classifies every prompt before its lifecycle opens

    static func gateOrderFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let classify = "ApprovalGate.classify("
        let open = "ApprovalLifecycle.open("
        for (name, text) in sources where !["ApprovalClassification.swift", "ApprovalStateMachine.swift"].contains(name) {
            for token in [classify, open] {
                let found = count(token, in: text)
                if name == intakeFile ? found != 1 : found != 0 { failures.append("\(found) '\(token)' in \(name)") }
            }
        }
        let intake = text(intakeFile, in: sources)
        let classified = "let classification = ApprovalGate.classify(toolName: request.toolName, inputPreview: request.inputPreview,"
        let opened = "ApprovalLifecycle.open(id: id, classification: classification, armed: armed(), now: now())"
        guard let read = intake.range(of: "guard case .prompt(let request)? = ApprovalChannel.frame(line) else {"),
              let gate = intake.range(of: classified), let lifecycle = intake.range(of: opened),
              read.upperBound < gate.lowerBound, gate.upperBound < lifecycle.lowerBound else {
            return failures + ["the intake must read the frame strictly, classify it, then open the lifecycle with that answer"]
        }
        return failures
    }

    @Test func theGateClassifiesEveryPromptBeforeItsLifecycleOpens() throws {
        let sources = try Self.sources()
        #expect(Self.gateOrderFailures(sources).isEmpty, "\(Self.gateOrderFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the gate bypassed", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: "classification: classification, armed", with: "classification: .forward(.bash), armed") }),
            ("a second classification", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet c = ApprovalGate.classify(toolName: t, inputPreview: p)" }),
            ("a lifecycle opened elsewhere", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet l = ApprovalLifecycle.open(id: i, classification: c, armed: true, now: 0)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.gateOrderFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - One reader, no second parser

    static let parserTokens = ["JSONSerialization", "JSONDecoder", "PropertyListSerialization", "PropertyListDecoder",
                               "NSRegularExpression", "Scanner(", "XMLParser"]

    static func readerFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where s1Files.contains(name) || name.hasPrefix("ApprovalChannel") {
            for token in parserTokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — every inbound line is read by the S0 strict reader only")
            }
        }
        let reads = [(relayFile, "ApprovalChannel.message(line)"), (relayFile, "ApprovalChannel.frame(line)"),
                     (intakeFile, "ApprovalChannel.frame(line)"), (probeFile, "ChannelPolicy.finding(documents:")]
        for (name, token) in reads where !text(name, in: sources).contains(token) {
            failures.append("\(name) no longer reads through '\(token)' (lint would be vacuous)")
        }
        return failures
    }

    @Test func everyInboundLineIsReadByTheStrictReaderOnly() throws {
        let sources = try Self.sources()
        #expect(Self.readerFailures(sources).isEmpty, "\(Self.readerFailures(sources))")
        for (file, planted) in [(Self.relayFile, "let o = try JSONSerialization.jsonObject(with: d)"),
                                (Self.probeFile, "let p = try PropertyListSerialization.propertyList(from: d, format: nil)"),
                                (Self.intakeFile, "let v = try JSONDecoder().decode(V.self, from: d)")] {
            #expect(!Self.readerFailures(Self.mutate(sources, file) { $0 + "\n" + planted }).isEmpty, "canary in \(file) was NOT caught")
        }
    }

    // MARK: - The server reads no configuration and never talks to the session

    static let serverBannedTokens = ["FileManager", "getenv", "ProcessInfo", "environment", ".claude", "UserDefaults",
                                     "URLSession", "Process(", "posix_spawn", "print(", "FileHandle"]

    static func serverFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for name in [seamFile, relayFile, serverFile] {
            let code = text(name, in: sources)
            for token in serverBannedTokens where code.contains(token) {
                failures.append("'\(token)' in \(name) — the server reads no configuration and writes stdout only through write(2)")
            }
        }
        // The plain channel method would put text in front of Claude (F4.1).
        for (name, text) in sources where text.contains("\"notifications/claude/channel\"") {
            failures.append("\(name) names the channel message method — the server never sends one")
        }
        let wire = text("ApprovalChannel.swift", in: sources)
        if wire.contains("\"tools\"") || wire.contains("\\\"tools\\\"") || wire.contains("instructions") {
            failures.append("the handshake must declare the two channel capabilities only")
        }
        for (name, text) in sources where name != serverFile && text.contains("SeamPaths.homeDirectory(") {
            failures.append("\(name) resolves the real socket path — only the server's entry point may")
        }
        return failures
    }

    @Test func theServerReadsNoConfigurationAndNeverTalksToTheSession() throws {
        let sources = try Self.sources()
        #expect(Self.serverFailures(sources).isEmpty, "\(Self.serverFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the server reads the environment", Self.mutate(sources, Self.serverFile) { $0 + "\nlet h = getenv(\"HOME\")" }),
            ("the relay prints", Self.mutate(sources, Self.relayFile) { $0 + "\nfunc p() { print(\"x\") }" }),
            ("the seam reads a file", Self.mutate(sources, Self.seamFile) { $0 + "\nlet f = FileManager.default" }),
            ("a channel message", Self.mutate(sources, "ApprovalChannel.swift") {
                $0 + "\nstatic let m = \"notifications/claude/channel\"" }),
            ("a tools capability", Self.mutate(sources, "ApprovalChannel.swift") { $0 + "\nlet t = \"\\\"tools\\\":{}\"" }),
            ("the host resolves the real path", Self.mutate(sources, Self.hostFile) { $0 + "\nlet h = SeamPaths.homeDirectory()" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.serverFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Dark by default

    /// Nothing in the app starts the seam or runs the probe yet: the toggle
    /// and settings slices amend this lock deliberately when they wire them.
    static func darkFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != hostFile && text.contains("ApprovalSeamHost(") {
            failures.append("\(name) constructs the seam host — it stays unwired until the toggle slice")
        }
        for (name, text) in sources where name != probeFile && text.contains("ChannelPolicyProbe.") {
            failures.append("\(name) runs the probe — it stays unwired until the settings slice")
        }
        return failures
    }

    @Test func nothingWiresTheSeamOrTheProbeYet() throws {
        let sources = try Self.sources()
        #expect(Self.darkFailures(sources).isEmpty, "\(Self.darkFailures(sources))")
        #expect(!Self.darkFailures(Self.mutate(sources, "NapCatApp.swift") {
            $0 + "\nlet h = ApprovalSeamHost(socketPath: p, armed: { true }, secrets: { [] }, records: r)" }).isEmpty)
        #expect(!Self.darkFailures(Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet f = ChannelPolicyProbe.probe()" }).isEmpty)
    }

    // MARK: - The S1 tests touch nothing live

    /// The S1 test files that run anything (this file only reads sources, and
    /// names the tokens below as data).
    static let s1TestFiles = ["ApprovalChannelTests.swift", "ApprovalIntakeTests.swift", "ApprovalSeamEndToEndTests.swift",
                              "ApprovalSeamTests.swift", "ChannelPolicyProbeTests.swift", "ChannelRelayTests.swift"]

    /// No S1 test spawns anything (so no Claude Code session), resolves a
    /// real home or socket path, reads defaults, or runs the probe against
    /// the real system directory.
    static let liveTokens = ["Process(", "posix_spawn", "NSTask", "NSHomeDirectory", "homeDirectoryForCurrentUser",
                             "SeamPaths.homeDirectory(", "SeamPaths.socketPath(", "UserDefaults", "ChannelPolicyProbe.probe()",
                             "directory: ChannelPolicyProbe.systemDirectory", "\"~/", "--channels", "dangerously-load"]

    static func liveFailures(_ tests: Sources) -> [String] {
        tests.flatMap { name, text in
            liveTokens.filter { text.contains($0) }.map { "'\($0)' in \(name) — S1 tests touch nothing live" }
        }
    }

    @Test func theS1TestsTouchNothingLive() throws {
        let directory = LidGuardStructureTests.repoRoot().appendingPathComponent("Tests/NapCatTests")
        let tests: Sources = try Self.s1TestFiles.map {
            ($0, LidGuardStructureTests.codeOnly(try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)))
        }
        #expect(Self.liveFailures(tests).isEmpty, "\(Self.liveFailures(tests))")
        for planted in ["let p = Process()", "let h = NSHomeDirectory()", "let f = ChannelPolicyProbe.probe()",
                        "let s = SeamPaths.socketPath(home: h)", "let d = UserDefaults.standard"] {
            let mutant = tests.map { $0.name == "ApprovalSeamTests.swift" ? ($0.name, $0.text + "\n" + planted) : $0 }
            #expect(!Self.liveFailures(mutant).isEmpty, "canary '\(planted)' was NOT caught")
        }
    }
}
