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
    /// Slice S2: the Mac toggle, the only place the host is built and the
    /// probe run.
    static let toggleFile = "RemoteApprovalsController.swift"
    /// The I/O files S1 added.
    static let s1Files = [seamFile, relayFile, serverFile, intakeFile, hostFile, probeFile]

    /// Every Swift source of the four targets, comment-stripped (`strip`).
    /// (File names are unique across them.) The top level only — which is
    /// the whole target because `everyFolderALockListsIsFlat` holds.
    static func sources(_ strip: (String) -> String = LidGuardStructureTests.codeOnly) throws -> Sources {
        let root = LidGuardStructureTests.repoRoot()
        return try directories.flatMap { directory -> Sources in
            let url = root.appendingPathComponent(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }.sorted()
            return try names.map { ($0, strip(try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8))) }
        }
    }

    static func text(_ name: String, in sources: Sources) -> String { sources.first { $0.name == name }?.text ?? "" }

    static func mutate(_ sources: Sources, _ name: String, _ transform: (String) -> String) -> Sources {
        sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
    }

    static func count(_ token: String, in text: String) -> Int { text.components(separatedBy: token).count - 1 }

    // MARK: - Every folder a lock lists is flat (R6)

    /// SwiftPM compiles every Swift file BELOW a target's folder too, but
    /// `sources()` — like every lock that lists a folder — reads its top
    /// level only, so a file in a subfolder would compile in with no lock
    /// ever reading it. The flat layout is itself the lock: each folder a
    /// lock lists (the four targets, and the test folder the keychain lock
    /// lists) holds plain files only — no folder, no link (which could stand
    /// for one), so no nested Swift file — and Swift files at its top.
    static let flatRoots = directories + ["Tests/NapCatTests"]

    static func nestingFailures(under root: URL) -> [String] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue,
              let walker = FileManager.default.enumerator(atPath: root.path) else {
            return ["\(root.path) is not a folder (the lock would be vacuous)"]
        }
        var failures: [String] = []
        var topLevelSources = 0
        // Paths relative to the root; links are reported, never followed.
        // One entry at a time, so `fileAttributes` describes this one.
        while let entry = walker.nextObject() as? String {
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            let isSwift = entry.hasSuffix(".swift")
            if type == .typeDirectory {
                failures.append("\(entry)/ is a folder in \(root.path) — its files would compile unread")
            } else if type != .typeRegular {
                failures.append("\(entry) in \(root.path) is not a plain file — a link could stand for a folder")
            }
            if entry.contains("/") {
                if isSwift { failures.append("\(entry) is nested in \(root.path) — no structure lock reads it") }
            } else if isSwift && type == .typeRegular {
                topLevelSources += 1
            }
        }
        if topLevelSources == 0 { failures.append("no Swift file at the top of \(root.path) (the lock would be vacuous)") }
        return failures
    }

    @Test func everyFolderALockListsIsFlat() throws {
        let repo = LidGuardStructureTests.repoRoot()
        for directory in Self.flatRoots {
            let failures = Self.nestingFailures(under: repo.appendingPathComponent(directory))
            #expect(failures.isEmpty, "\(directory): \(failures)")
        }
        // Canaries in a scratch folder — never in the repo tree.
        let manager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ncf-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }
        /// A folder holding `entries` (a trailing `/` makes an empty folder).
        func layout(_ name: String, _ entries: [String]) throws -> URL {
            let folder = scratch.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            for entry in entries {
                let url = folder.appendingPathComponent(entry)
                if entry.hasSuffix("/") {
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("// canary\n".utf8).write(to: url)
                }
            }
            return folder
        }
        let flat = try layout("flat", ["A.swift", "B.swift"])
        #expect(Self.nestingFailures(under: flat).isEmpty, "a flat folder must pass: \(Self.nestingFailures(under: flat))")
        // The reviewer's shape (R6), and its variants.
        let nested = try layout("nested", ["A.swift", "ZZHidden/ZZPlantShadow.swift"])
        let nestedFailures = Self.nestingFailures(under: nested)
        #expect(nestedFailures.contains { $0.hasPrefix("ZZHidden/ZZPlantShadow.swift is nested") },
                "canary: the nested Swift file was NOT named: \(nestedFailures)")
        #expect(nestedFailures.contains { $0.hasPrefix("ZZHidden/ is a folder") }, "canary: the subfolder was NOT named: \(nestedFailures)")
        let mutants: [(name: String, entries: [String])] = [
            ("a deep file", ["A.swift", "B/C/D.swift"]),
            ("a hidden folder", ["A.swift", ".hidden/E.swift"]),
            ("an empty folder", ["A.swift", "Empty/"]),
            ("a folder of non-Swift files", ["A.swift", "Data/notes.txt"]),
        ]
        for (name, entries) in mutants {
            let folder = try layout(name, entries)
            #expect(!Self.nestingFailures(under: folder).isEmpty, "canary '\(name)' was NOT caught")
        }
        // A link to a folder outside the root: never followed, so caught as a link.
        let elsewhere = try layout("elsewhere", ["F.swift"])
        let linked = try layout("linked", ["A.swift"])
        try manager.createSymbolicLink(at: linked.appendingPathComponent("Link"), withDestinationURL: elsewhere)
        #expect(!Self.nestingFailures(under: linked).isEmpty, "canary 'a link to a folder' was NOT caught")
        // Vacuity: a missing root, and a root with no Swift file at its top.
        #expect(!Self.nestingFailures(under: scratch.appendingPathComponent("missing")).isEmpty, "a missing root must fail")
        let noSwift = try layout("no-swift", ["notes.txt"])
        #expect(!Self.nestingFailures(under: noSwift).isEmpty, "a root with no Swift file at its top must fail")
    }

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

    /// The intake's strict read of a frame, its server and client bound.
    static let frameRead: String = "guard case .prompt(let request, let server, let client)? = ApprovalChannel.frame(line) else {"
    /// #150: the frame's server version and its client, checked again by the
    /// intake, each refusal closing the connection.
    static let serverRecheck: String = "guard server == ApprovalChannel.serverVersion else {\n            audit(.serverVersionRefused)\n"
        + "            closeConnection(connection)\n            return\n        }\n"
    static let clientRecheck: String = "guard ApprovalChannel.confirms(client) else {\n            audit(.clientRefused)\n"
        + "            closeConnection(connection)\n            return\n        }\n"
    /// The first thing `receive` holds after the checks: the prune, then the
    /// duplicate, capacity and prompt-ID checks.
    static let heldChecks: String = "        prune()\n        guard !prompts.values.contains(where:"

    /// The lifecycle's open, however it is spelled (#198), read on the
    /// flattened code of every scan copy, so a line break or a comment
    /// between its parts reads as at most one space and a backtick as
    /// nothing: in the intake, any member named `open`, qualified, implicit
    /// or unapplied; in every other file, the lifecycle's, applied or not.
    static let intakeOpenPattern: String = #"\. ?open\b"#
    static let lifecycleOpenPattern: String = #"\bApprovalLifecycle ?\. ?open\b"#

    /// `pattern`'s count in each scan copy of `text`, flattened.
    static func flatCounts(_ pattern: String, in text: String) -> [Int] {
        LidGuardStructureTests.constructorScanCopies(text).map {
            ApprovalRecordPathStructureTests.matches(pattern, in: MenuPanelStructureTests.flat($0)).count
        }
    }

    /// The intake reads each frame strictly, checks its server's version and
    /// its client again (#150) before anything is held, classifies it, and
    /// only then opens its lifecycle with the gate's answer: the gate is
    /// called once, and the lifecycle opened once, there alone (the open
    /// counted on the flattened code, #198).
    static func gateOrderFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let classify = "ApprovalGate.classify("
        for (name, text) in sources where !["ApprovalClassification.swift", "ApprovalStateMachine.swift"].contains(name) {
            let found: Int = count(classify, in: text)
            if name == intakeFile ? found != 1 : found != 0 { failures.append("\(found) '\(classify)' in \(name)") }
            let wanted: Int = name == intakeFile ? 1 : 0
            let pattern: String = name == intakeFile ? intakeOpenPattern : lifecycleOpenPattern
            for opens in flatCounts(pattern, in: text) where opens != wanted {
                failures.append("\(opens) lifecycle open(s) in \(name), read on the flattened code")
            }
        }
        let intake = text(intakeFile, in: sources)
        let classified = "let classification = ApprovalGate.classify(toolName: request.toolName, inputPreview: request.inputPreview,"
        let opened = "ApprovalLifecycle.open(id: id, classification: classification, armed: armed(), now: now())"
        guard let read = intake.range(of: frameRead),
              let gate = intake.range(of: classified), let lifecycle = intake.range(of: opened),
              read.upperBound < gate.lowerBound, gate.upperBound < lifecycle.lowerBound else {
            return failures + ["the intake must read the frame strictly, classify it, then open the lifecycle with that answer"]
        }
        let recheckRule: String = "the intake must check the server's version and the client again right after the strict read, "
            + "each refusal closing the connection, before anything is held and before the gate (#150)"
        guard count(serverRecheck, in: intake) == 1, count(clientRecheck, in: intake) == 1,
              let server = intake.range(of: serverRecheck), let client = intake.range(of: clientRecheck),
              let held = intake.range(of: heldChecks),
              read.upperBound < server.lowerBound, server.upperBound <= client.lowerBound,
              client.upperBound <= held.lowerBound, held.upperBound < gate.lowerBound else {
            return failures + [recheckRule]
        }
        return failures
    }

    @Test func theGateClassifiesEveryPromptBeforeItsLifecycleOpens() throws {
        let sources = try Self.sources()
        #expect(Self.gateOrderFailures(sources).isEmpty, "\(Self.gateOrderFailures(sources))")
        let intake: String = Self.text(Self.intakeFile, in: sources)
        let indent: String = "        "
        let serverOnly: String = indent + Self.serverRecheck
        let clientOnly: String = indent + Self.clientRecheck
        let rechecks: String = serverOnly + clientOnly
        let clientFirst: String = clientOnly + serverOnly
        let beforeOpen: String = "        let opened = ApprovalLifecycle.open("
        let afterCapacity: String = "        guard prompts.count < Self.maxPrompts else { return audit(.capacityReached) }\n"
        let afterGate: String = rechecks + beforeOpen
        let afterHeld: String = afterCapacity + rechecks
        let closing: String = "            audit(.clientRefused)\n            closeConnection(connection)\n"
        let keeping: String = "            audit(.clientRefused)\n"
        let confirmed: String = "guard ApprovalChannel.confirms(client) else {"
        let anything: String = "guard ApprovalChannel.confirms(client) || true else {"
        let anchors: [String] = [rechecks, beforeOpen, afterCapacity, Self.heldChecks, closing, confirmed]
        for anchor in anchors {
            #expect(Self.count(anchor, in: intake) == 1, "vacuity: '\(anchor.prefix(50))' is in the intake once")
        }
        let without: (String) -> Sources = { kept in Self.mutate(sources, Self.intakeFile) { $0.replacingOccurrences(of: rechecks, with: kept) } }
        let openLine: String = "        let opened = ApprovalLifecycle.open(id: id, classification: classification, armed: armed(), now: now())\n"
        #expect(Self.count(openLine, in: intake) == 1, "vacuity: the lifecycle's one open is in the intake once")
        let opening: (String) -> Sources = { line in
            Self.mutate(sources, Self.intakeFile) { $0.replacingOccurrences(of: openLine, with: openLine + line) }
        }
        let overLines: String = "        let zz = ApprovalLifecycle\n            .open(id: id, classification: classification, armed: armed(), now: now(), timeToLive: 3_600)\n"
        let behindComment: String = "        let zz = ApprovalLifecycle./* x */open(id: id, classification: classification, armed: true, now: 0)\n"
        let dropped: Sources = without("")
        let mutants: [(String, Sources)] = [
            ("the gate bypassed", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: "classification: classification, armed", with: "classification: .forward(.bash), armed") }),
            ("a second classification", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet c = ApprovalGate.classify(toolName: t, inputPreview: p)" }),
            ("a lifecycle opened elsewhere", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet l = ApprovalLifecycle.open(id: i, classification: c, armed: true, now: 0)" }),
            // #150: the re-check dropped, halved, moved past the gate or past
            // the held checks, or made to keep the connection.
            ("the re-check dropped", dropped),
            ("the server's version unchecked", without(clientOnly)),
            ("the client unchecked", without(serverOnly)),
            ("the re-check moved after the gate", Self.mutate(dropped, Self.intakeFile) { $0.replacingOccurrences(of: beforeOpen, with: afterGate) }),
            ("the re-check moved after the held checks", Self.mutate(dropped, Self.intakeFile) {
                $0.replacingOccurrences(of: afterCapacity, with: afterHeld) }),
            ("the client checked first", without(clientFirst)),
            ("a refusal that keeps the connection", Self.mutate(sources, Self.intakeFile) { $0.replacingOccurrences(of: closing, with: keeping) }),
            ("a client confirmed by anything", Self.mutate(sources, Self.intakeFile) { $0.replacingOccurrences(of: confirmed, with: anything) }),
            // #198: a second open, however it is spelled — over a line break
            // (the second re-check's shape), behind a block comment,
            // backticked, unapplied, as an implicit member — in the intake,
            // and the lifecycle's open over a line break or unapplied
            // elsewhere.
            ("a second open over a line break", opening(overLines)),
            ("a second open behind a block comment", opening(behindComment)),
            ("a second open, backticked", opening("        let zz = ApprovalLifecycle.`open`(id: id, classification: classification, armed: true, now: 0)\n")),
            ("the open taken unapplied", opening("        let zz = ApprovalLifecycle.open\n")),
            ("an implicit open", opening("        let zz: ApprovalLifecycle = .open(id: id, classification: classification, armed: true, now: 0).lifecycle\n")),
            ("a lifecycle opened over a line break elsewhere", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet l = ApprovalLifecycle\n    .open(id: i, classification: c, armed: true, now: 0)" }),
            ("a lifecycle's open taken unapplied elsewhere", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet zz = ApprovalLifecycle . open" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.gateOrderFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The line break is what the raw count missed.
        let broken: String = "ApprovalLifecycle\n            .open(id: id"
        #expect(Self.count("ApprovalLifecycle.open(", in: broken) == 0 && Self.flatCounts(Self.intakeOpenPattern, in: broken) == [1],
                "vacuity: the line break hides the call from a raw count and not from the flattened one")
        // Over-match controls: a blank line and a line the stripper empties
        // (a comment, read as spaces) between the two checks; and words that
        // only contain the open's, a member of another name, and another
        // type's open outside the intake.
        let gap: String = "\n" + String(repeating: " ", count: 20) + "\n"
        let spaced: Sources = without(serverOnly + gap + clientOnly)
        let words: Sources = Self.mutate(opening("        let zzReopened = opened.lifecycle.isTerminalOpen, zzOpenCount = opened.transition\n"),
                                         Self.hostFile) { $0 + "\nfunc zz(_ u: URL) { _ = NSWorkspace.shared.open(u); _ = ZZLifecycle.open }" }
        for (name, control) in [("the checks spaced", spaced), ("words like open", words)] {
            #expect(control.map { $0.text } != sources.map { $0.text }, "the control '\(name)' applied")
            #expect(Self.gateOrderFailures(control).isEmpty, "over-match '\(name)': \(Self.gateOrderFailures(control))")
        }
    }

    // MARK: - Only the gate's copy of a preview is ever saved

    /// The relayed preview is read exactly twice — by the gate and by the
    /// gate's copy — and what reaches `records.save(` is the copy (which has
    /// no description); a forward without a copy stays local.
    static func savedCopyFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let intake = text(intakeFile, in: sources)
        let copy = "let copy = ApprovalGate.forwardedPreview(toolName: request.toolName, inputPreview: request.inputPreview)"
        if count(copy, in: intake) != 1 { failures.append("the intake must take the gate's copy of the preview, once") }
        if count("request.inputPreview", in: intake) != 2 {
            failures.append("the relayed preview may be read only by the gate and by its copy")
        }
        if count(".requiringCopy(copy)", in: intake) != 1 { failures.append("a forward without a copy must stay local") }
        if count("classified: (", in: intake) != 2
            || !intake.contains("perform(opened.transition, for: id, classified: (classification, copy))") {
            failures.append("the lifecycle's save effect must be handed the copy, nothing else")
        }
        if count("records.save(", in: intake) != 1
            || !intake.contains("let preview = classified?.1 else { continue }\n"
                                + "                records.save(id, tool: tool, inputPreview: preview, expiresAt: ") {
            failures.append("the one save must write the copy it was handed")
        }
        for (name, text) in sources where name != intakeFile && name != "ApprovalClassification.swift"
            && text.contains("forwardedPreview(") {
            failures.append("\(name) takes a copy of a preview — only the intake may")
        }
        return failures
    }

    @Test func onlyTheGatesCopyOfAPreviewIsEverSaved() throws {
        let sources = try Self.sources()
        #expect(Self.savedCopyFailures(sources).isEmpty, "\(Self.savedCopyFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the relayed text handed to the save", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: "classified: (classification, copy))", with: "classified: (classification, request.inputPreview))") }),
            ("the fold dropped", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: ".requiringCopy(copy)", with: "") }),
            ("the save writes something else", Self.mutate(sources, Self.intakeFile) {
                $0.replacingOccurrences(of: "records.save(id, tool: tool, inputPreview: preview,",
                                        with: "records.save(id, tool: tool, inputPreview: preview + suffix,") }),
            ("a second save", Self.mutate(sources, Self.intakeFile) {
                $0 + "\nfunc f(p: String) { records.save(id, tool: .bash, inputPreview: p, expiresAt: 0) }" }),
            ("a copy taken elsewhere", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet c = ApprovalGate.forwardedPreview(toolName: t, inputPreview: p)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.savedCopyFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
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
        // The real socket path is resolved by the server's entry point and
        // (slice S2) by the Mac toggle's one factory — once each, nowhere
        // else.
        for (name, text) in sources {
            let resolutions = count("SeamPaths.homeDirectory(", in: text)
            let allowed = name == serverFile || name == toggleFile ? 1 : 0
            if resolutions != allowed {
                failures.append("\(resolutions) real socket path resolution(s) in \(name) — only the server's entry point "
                    + "and the toggle's factory may, once each")
            }
        }
        let toggle = text(toggleFile, in: sources)
        if let factory = toggle.range(of: "static func makeIfEnabled("), let resolve = toggle.range(of: "SeamPaths.homeDirectory("),
           let builder = toggle.range(of: "static func failDarkHost(") {
            if !(factory.upperBound < resolve.lowerBound && resolve.upperBound < builder.lowerBound) {
                failures.append("the toggle resolves the real socket path outside its production factory")
            }
        } else {
            failures.append("the toggle's factory moved (lint would be vacuous)")
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
            ("the model resolves the real path", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet h = SeamPaths.homeDirectory()" }),
            ("the toggle resolves it twice", Self.mutate(sources, Self.toggleFile) { $0 + "\nlet h = SeamPaths.homeDirectory()" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.serverFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Behind the toggle only (slice S2; replaces S1's dark-by-default lock)

    /// S1 kept the seam host and the probe unwired. Slice S2 wires them —
    /// behind the Mac toggle, and fail-dark — and this lock replaces the dark
    /// one without giving up any of it: still nothing but the toggle builds
    /// the host or runs the probe (S1's two canaries are kept), and now also:
    ///
    /// - the host is built in exactly ONE place, `failDarkHost`, never armed
    ///   (`armed: { false }`) and with the record sink that writes nothing;
    ///   that sink has empty bodies, and no CloudKit or network token is in
    ///   any approvals file;
    /// - the stored factory is invoked in exactly one place, `listen()`, and
    ///   only after its switched-on guard, and the production factory is the
    ///   fail-dark one;
    /// - the probe is named once (the production factory's closure) and run
    ///   once, as the state machine's `.probe` effect — which it returns only
    ///   while on (RemoteApprovalsPolicyTests);
    /// - the controller is built only by its gated factory, and the app calls
    ///   that factory once;
    /// - (security pass, N-20) nothing outside the toggle names the fail-dark
    ///   factory; the toggle's host is private and started only in
    ///   `listen()`; the seam's listener and intake are built only inside the
    ///   host, once each; and a construction counts however it is spelled
    ///   (`T.init(`, a space before the parenthesis — `constructionSpelling`).
    static func armedGateFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let spelled: Sources = sources.map { ($0.name, constructionSpelling($0.text)) }
        for (name, text) in spelled where name != toggleFile && text.contains("ApprovalSeamHost(") {
            failures.append("\(name) constructs the seam host — only the toggle's fail-dark factory may")
        }
        for (name, text) in sources where name != probeFile && name != toggleFile && text.contains("ChannelPolicyProbe.") {
            failures.append("\(name) runs the probe — only the toggle may, while on")
        }
        for (name, text) in spelled where name != toggleFile && text.contains("RemoteApprovalsController(") {
            failures.append("\(name) builds the toggle around its gated factory")
        }
        // The fail-dark factory is the toggle's own: called, or merely
        // referenced, anywhere else it builds a host the switch never sees.
        for (name, text) in sources where name != toggleFile && text.contains("failDarkHost") {
            failures.append("\(name) names the fail-dark factory — only the toggle's production factory may call it")
        }
        // The listener and the intake exist only inside the host (built
        // there once each), so nothing can listen on the seam around it.
        let hostSpelled = text(hostFile, in: spelled)
        for token in ["SeamListener(", "ApprovalIntake("] {
            for (name, text) in spelled where name != hostFile && text.contains(token) {
                failures.append("'\(token)' in \(name) — only the seam host builds its listener and intake")
            }
            if count(token, in: hostSpelled) != 1 { failures.append("the host must build exactly one '\(token)'") }
        }
        let app = text("NapCatApp.swift", in: sources)
        if count("RemoteApprovalsController.makeIfEnabled(", in: app) != 1 {
            failures.append("the app must build the toggle exactly once, through its gated factory")
        }
        let toggle = text(toggleFile, in: sources)
        let toggleSpelled = text(toggleFile, in: spelled)
        let flat = toggle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if count("ApprovalSeamHost(", in: toggleSpelled) != 1 { failures.append("the host must be built in exactly one place") }
        // The toggle's host is private and handed out by nothing (no other
        // stored, computed or returned host), and it is started in one place:
        // listen(), after the switched-on guard.
        if count("var host", in: toggle) != 1 || !flat.contains(" private var host: ApprovalSeamHost? ")
            || count(": ApprovalSeamHost", in: toggle) != 1 || count("-> ApprovalSeamHost", in: toggle) != 2 {
            failures.append("the toggle's host must stay private — handed out, it could be started behind the switch")
        }
        if count(".start(", in: toggleSpelled) != 1
            || !flat.contains("private func listen() { guard state.enabled else { return } "
                              + "let host = self.host ?? makeHost(socketPath) self.host = host let started = host.start() ") {
            failures.append("the host must be started only in listen(), after its switched-on guard")
        }
        if !flat.contains("-> ApprovalSeamHost { ApprovalSeamHost(socketPath: socketPath, armed: { false }, secrets: secrets, "
                          + "records: FailDarkApprovalRecords(), audit: audit, peerReader: peerReader) }") {
            failures.append("the one host must be built never armed, with the sink that writes nothing")
        }
        if !flat.contains("final class FailDarkApprovalRecords: ApprovalRecordSink { "
                          + "func save(_ id: PromptID, tool: ApprovalTool, inputPreview: String, expiresAt: Int) {} "
                          + "func retract(_ id: PromptID) {} func supersedeWaitingAlert(_ id: PromptID) {} }") {
            failures.append("the fail-dark sink must write nothing")
        }
        for name in [toggleFile, hostFile, intakeFile, "RemoteApprovalsPolicy.swift"] {
            for token in ["CloudKit", "CKContainer", "CKDatabase", "CKRecord", "URLSession", "MessageSender"]
            where text(name, in: sources).contains(token) {
                failures.append("'\(token)' in \(name) — nothing in this slice can send a prompt anywhere")
            }
        }
        if count("failDarkHost(", in: toggleSpelled) != 2 || count("failDarkHost", in: toggle) != 2
            || !flat.contains("makeHost: { Self.failDarkHost(socketPath: $0, ") {
            failures.append("the production factory must be the fail-dark one, and nothing else may call it")
        }
        if count("makeHost(", in: toggle) != 1 { failures.append("the host factory must be invoked in exactly one place") }
        if let listen = toggle.range(of: "private func listen() {"), let guarded = toggle.range(of: "guard state.enabled else { return }"),
           let build = toggle.range(of: "makeHost(socketPath)") {
            if !(listen.upperBound < guarded.lowerBound && guarded.upperBound < build.lowerBound
                 && toggle[listen.upperBound..<guarded.lowerBound].allSatisfy(\.isWhitespace)) {
                failures.append("listen() must open with its switched-on guard, before it builds the host")
            }
        } else {
            failures.append("listen(), its guard or its build moved (lint would be vacuous)")
        }
        if count("listen()", in: toggle) != 2 || !flat.contains("case .startListening: listen()") {
            failures.append("listen() must run only as the state machine's .startListening effect")
        }
        if count("ChannelPolicyProbe.", in: toggle) != 1 || !flat.contains("probe: { ChannelPolicyProbe.probe() })") {
            failures.append("the probe must be named once, as the production factory's closure")
        }
        if count("probe()", in: toggle) != 2 || !flat.contains("case .probe: run(.probed(probe()))") {
            failures.append("the probe must run only as the state machine's .probe effect")
        }
        return failures
    }

    /// A construction token however it is spelled: `T.init(` and `T (`
    /// (whitespace before the parenthesis, or around `.init`) read as `T(`.
    /// For the construction checks only — the shape checks match the source
    /// as written.
    static func constructionSpelling(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\.\s*init\s*\("#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z0-9_])\s+\("#, with: "$1(", options: .regularExpression)
    }

    @Test func theSeamAndTheProbeRunOnlyBehindTheToggle() throws {
        let sources = try Self.sources()
        #expect(Self.armedGateFailures(sources).isEmpty, "\(Self.armedGateFailures(sources))")
        let mutants: [(String, Sources)] = [
            // S1's canaries, kept.
            ("the app builds the host", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet h = ApprovalSeamHost(socketPath: p, armed: { true }, secrets: { [] }, records: r)" }),
            ("the model probes", Self.mutate(sources, "MenuStateModel.swift") { $0 + "\nlet f = ChannelPolicyProbe.probe()" }),
            // S2's.
            ("armed", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "armed: { false }", with: "armed: { true }") }),
            ("a sink that saves", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "records: FailDarkApprovalRecords()", with: "records: CloudKitApprovalRecords()") }),
            ("the fail-dark sink writes", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "    func retract(_ id: PromptID) {}",
                                        with: "    func retract(_ id: PromptID) { store.delete(id) }") }),
            ("a second host", Self.mutate(sources, Self.toggleFile) {
                $0 + "\nlet h = ApprovalSeamHost(socketPath: p, armed: { false }, secrets: { [] }, records: r)" }),
            ("CloudKit in the toggle", Self.mutate(sources, Self.toggleFile) { $0 + "\nlet c = CKContainer.default()" }),
            ("a sender in the intake", Self.mutate(sources, Self.intakeFile) { $0 + "\nlet s: MessageSender? = nil" }),
            ("the guard dropped", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "guard state.enabled else { return }", with: "") }),
            ("built before the guard", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "    private func listen() {\n        guard state.enabled else { return }",
                                        with: "    private func listen() {\n        _ = makeHost(socketPath)\n        guard state.enabled else { return }") }),
            ("listened at launch", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "    func reconcile() {\n", with: "    func reconcile() {\n        listen()\n") }),
            ("probed at launch", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "    func reconcile() {\n", with: "    func reconcile() {\n        _ = probe()\n") }),
            ("an armed production factory", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "makeHost: { Self.failDarkHost(socketPath: $0, ",
                                        with: "makeHost: { Self.armedHost(socketPath: $0, ") }),
            ("the toggle built twice", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet t = RemoteApprovalsController.makeIfEnabled(debugBattery: false, lidGuard: nil)" }),
            ("the toggle built around its factory", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet t = RemoteApprovalsController(socketPath: p, readStored: r, writeStored: w, makeHost: m, probe: q)" }),
            // N-20 (security pass): the four gaps, each closed.
            // (1) The fail-dark factory outside the toggle.
            ("the fail-dark factory called elsewhere", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet h = RemoteApprovalsController.failDarkHost(socketPath: p, secrets: { nil })" }),
            ("the fail-dark factory referenced elsewhere", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet f = RemoteApprovalsController.failDarkHost" }),
            // (2) The toggle's host handed out, or started again.
            ("the host readable", Self.mutate(sources, Self.toggleFile) {
                $0.replacingOccurrences(of: "    private var host: ApprovalSeamHost?",
                                        with: "    private(set) var host: ApprovalSeamHost?") }),
            ("the host handed out", Self.mutate(sources, Self.toggleFile) {
                $0 + "\nextension RemoteApprovalsController { var seamHost: ApprovalSeamHost? { host } }" }),
            ("the host started again", Self.mutate(sources, Self.toggleFile) {
                $0 + "\nextension RemoteApprovalsController { func relisten() { _ = host?.start() } }" }),
            // (3) A listener or an intake outside the host, or a second one in it.
            ("a listener outside the host", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet l = SeamListener(socketPath: p, queue: q)" }),
            ("an intake outside the host", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet i = ApprovalIntake(armed: { true }, secrets: { [] }, newPromptID: n, now: c, records: r, "
                    + "sendFrame: s, closeConnection: k, audit: a)" }),
            ("a second listener in the host", Self.mutate(sources, Self.hostFile) {
                $0 + "\nlet l = SeamListener(socketPath: p, queue: q)" }),
            // (4) Any spelling of a construction.
            ("the init spelling", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet h = ApprovalSeamHost.init(socketPath: p, armed: { true }, secrets: { [] }, records: r)" }),
            ("a spaced call", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet h = ApprovalSeamHost (socketPath: p, armed: { true }, secrets: { [] }, records: r)" }),
            ("a second host by init in the toggle", Self.mutate(sources, Self.toggleFile) {
                $0 + "\nlet h = ApprovalSeamHost\n    .init(socketPath: p, armed: { false }, secrets: { [] }, records: r)" }),
            ("a listener by init in the toggle", Self.mutate(sources, Self.toggleFile) {
                $0 + "\nlet l = SeamListener.init(socketPath: p, queue: q)" }),
            ("the toggle by init", Self.mutate(sources, "MenuContentView.swift") {
                $0 + "\nlet t = RemoteApprovalsController.init(socketPath: p, readStored: r, writeStored: w, makeHost: m, "
                    + "probe: q)" }),
        ]
        for (name, mutant) in mutants {
            #expect(!Self.armedGateFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
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
