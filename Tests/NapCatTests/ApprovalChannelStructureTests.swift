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
    /// #247: the outstanding-Unpair record, whose real file sits in the
    /// approvals folder beside the socket.
    static let unpairRecordFile = "UnpairRecord.swift"
    /// The I/O files S1 added.
    static let s1Files = [seamFile, relayFile, serverFile, intakeFile, hostFile, probeFile]

    /// Every Swift source of the four targets, comment-stripped (`strip`).
    /// (File names are unique across them today; a lock that must not lean
    /// on that reads `pathSources`, #244.) The top level only — which is the
    /// whole target because `everyFolderALockListsIsFlat` holds.
    static func sources(_ strip: (String) -> String = LidGuardStructureTests.codeOnly) throws -> Sources {
        let root = LidGuardStructureTests.repoRoot()
        return try directories.flatMap { directory -> Sources in
            let url = root.appendingPathComponent(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }.sorted()
            return try names.map { ($0, strip(try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8))) }
        }
    }

    /// The files and the text of `sources(strip)`, named as the URL-loading
    /// lock (#236) and the CloudKit import lock (#241) name them:
    /// Sources/NapCat by file name, the other three targets by path from the
    /// repository root (`LidGuardStructureTests.otherTargetSources`). A lock
    /// that reads this form (#244: the socket-call lock, the server's
    /// banned-word check, the gate-order lock, the keychain-call lock and the
    /// check-name lock) names each pinned file outside Sources/NapCat by its
    /// path, so a file of the same name in another target is not it.
    static func pathSources(_ strip: (String) -> String = LidGuardStructureTests.codeOnly) throws -> Sources {
        try LidGuardStructureTests.swiftSources(strip) + LidGuardStructureTests.otherTargetSources(strip)
    }

    /// The pinned files outside Sources/NapCat, by path, as `pathSources`
    /// names them (#244).
    static let seamPath = "Sources/NapCatSeam/" + seamFile
    static let relayPath = "Sources/NapCatChannel/" + relayFile
    static let serverPath = "Sources/NapCatChannel/" + serverFile
    static let wirePath = "Sources/NapCatWire/ApprovalChannel.swift"
    static let stateMachinePath = "Sources/NapCatWire/ApprovalStateMachine.swift"
    static let classificationPath = "Sources/NapCatWire/ApprovalClassification.swift"
    static let pinnedPaths = [seamPath, relayPath, serverPath, wirePath, stateMachinePath, classificationPath]

    /// A file of `pinned`'s name in each of the four targets but its own,
    /// named as `pathSources` names it (#244): the namesakes a lock that
    /// matched by file name alone would take for the pinned file.
    static func namesakes(of pinned: String) -> [String] {
        let file = String(pinned.split(separator: "/").last ?? "")
        return directories.map { $0 == "Sources/NapCat" ? file : $0 + "/" + file }.filter { $0 != pinned }
    }

    /// `sources` with a new file `name` holding `text`, where `pathSources`
    /// reads it: after the files of its own target, before the next
    /// target's (#244). So a namesake in Sources/NapCat comes before the
    /// pinned file, as it would be read.
    static func inserting(_ sources: Sources, _ name: String, _ text: String) -> Sources {
        func target(_ name: String) -> Int {
            let folder = name.contains("/") ? name.split(separator: "/").dropLast().joined(separator: "/") : "Sources/NapCat"
            return directories.firstIndex(of: folder) ?? directories.count
        }
        var inserted = sources
        inserted.insert((name: name, text: text), at: sources.firstIndex { target($0.name) > target(name) } ?? sources.endIndex)
        return inserted
    }

    /// Whether a failure names `file` as these locks name the file a
    /// failure is about: after " in ", before " —" or a comma, or at the end
    /// (#244).
    static func names(_ failures: [String], _ file: String) -> Bool {
        let subject: String = " in " + file
        let dashed: String = subject + " —"
        let comma: String = subject + ","
        return failures.contains { $0.contains(dashed) || $0.contains(comma) || $0.hasSuffix(subject) }
    }

    /// `pathSources` reads what `sources` reads, file for file, for both
    /// forms the locks read, and names every file of the other three targets
    /// by its path; each pinned path is one of them (vacuity of #244).
    @Test func thePathSourcesReadWhatTheSourcesRead() throws {
        for strip in [LidGuardStructureTests.codeOnly, LidGuardStructureTests.wholeLineCommentsRemoved] {
            let byPath = try Self.pathSources(strip)
            let byName = try Self.sources(strip)
            #expect(byPath.map { $0.text } == byName.map { $0.text }
                    && byPath.map { String($0.name.split(separator: "/").last ?? "") } == byName.map { $0.name },
                    "vacuity: pathSources reads every file of the four targets, as sources() reads it")
            let others = LidGuardStructureTests.networkingOtherTargets
            #expect(Self.directories.count == 4 && others.count == 3, "the four Mac targets")
            #expect(Set(byPath.filter { $0.name.contains("/") }.map { $0.name.split(separator: "/").dropLast().joined(separator: "/") })
                    == Set(others), "vacuity: every other Mac target is read, each file named by its path")
            for path in Self.pinnedPaths {
                #expect(byPath.filter { $0.name == path }.count == 1 && !Self.text(path, in: byPath).isEmpty, "vacuity: \(path) is read, by path")
            }
        }
        // The helpers: three namesakes for a pinned file in any target, and
        // a new file read in its target's place.
        #expect(Self.namesakes(of: Self.seamPath) == ["SeamSocket.swift", "Sources/NapCatChannel/SeamSocket.swift",
                                                      "Sources/NapCatWire/SeamSocket.swift"])
        #expect(Self.namesakes(of: "KeychainTopicStore.swift") == ["Sources/NapCatSeam/KeychainTopicStore.swift",
                                                                   "Sources/NapCatChannel/KeychainTopicStore.swift",
                                                                   "Sources/NapCatWire/KeychainTopicStore.swift"])
        let small: Sources = [("A.swift", ""), ("Sources/NapCatSeam/B.swift", ""), ("Sources/NapCatWire/C.swift", "")]
        #expect(Self.inserting(small, "Z.swift", "").map { $0.name }
                == ["A.swift", "Z.swift", "Sources/NapCatSeam/B.swift", "Sources/NapCatWire/C.swift"])
        #expect(Self.inserting(small, "Sources/NapCatChannel/Z.swift", "").map { $0.name }
                == ["A.swift", "Sources/NapCatSeam/B.swift", "Sources/NapCatChannel/Z.swift", "Sources/NapCatWire/C.swift"])
        #expect(Self.inserting(small, "Sources/NapCatWire/Z.swift", "").map { $0.name }
                == ["A.swift", "Sources/NapCatSeam/B.swift", "Sources/NapCatWire/C.swift", "Sources/NapCatWire/Z.swift"])
        #expect(Self.names(["'x' in Sources/NapCatSeam/SeamSocket.swift — y"], Self.seamPath)
                && !Self.names(["'x' in Sources/NapCatSeam/SeamSocket.swift — y"], Self.seamFile)
                && Self.names(["2 lifecycle open(s) in A.swift, read"], "A.swift") && Self.names(["1 'f(' in A.swift"], "A.swift"))
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

    /// `sources`: `pathSources()` (#244: `sources()`, read before, names
    /// every file by its file name alone, so a file called SeamSocket.swift
    /// in another target was let off the ban, and one in Sources/NapCat was
    /// read as the seam's file).
    static func socketConfinementFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != seamPath {
            for token in socketTokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — the seam's socket calls stay in \(seamPath)")
            }
        }
        let seam = text(seamPath, in: sources)
        for token in socketTokens.dropLast() where !seam.contains(token) {
            failures.append("'\(token)' not found in \(seamPath) — the lint would be vacuous")
        }
        return failures
    }

    @Test func theSeamsSocketCallsLiveInOneFile() throws {
        let sources = try Self.pathSources()
        #expect(Self.socketConfinementFailures(sources).isEmpty, "\(Self.socketConfinementFailures(sources))")
        for (file, planted) in [(Self.hostFile, "let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)"),
                                (Self.relayPath, "_ = getsockopt(0, 0, 0, nil, nil)"),
                                (Self.intakeFile, "let c = LOCAL_PEERCRED")] {
            let mutant = Self.mutate(sources, file) { $0 + "\n" + planted }
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary in \(file) did not apply")
            #expect(!Self.socketConfinementFailures(mutant).isEmpty, "canary in \(file) was NOT caught")
        }
        // #244: a file under the seam's name in each other target, holding a
        // socket call, is not the seam's file: the ban names it, by its path.
        // One holding the seam's own text is named alone: the seam's file
        // stays the one exempt.
        let seam = Self.text(Self.seamPath, in: sources)
        let namesakes = Self.namesakes(of: Self.seamPath)
        #expect(namesakes.count == 3, "vacuity: a namesake in each other target")
        for path in namesakes {
            let mutant = Self.inserting(sources, path, "let zz = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)\n")
            #expect(Self.names(Self.socketConfinementFailures(mutant), path), "canary at \(path) was NOT caught by the socket ban")
            let twin = Self.socketConfinementFailures(Self.inserting(sources, path, seam))
            #expect(!twin.isEmpty && twin.allSatisfy { $0.hasPrefix("'") && $0.contains(" in \(path) —") },
                    "the seam's twin at \(path) was NOT named alone: \(twin)")
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

    // MARK: - No answer goes back until the listener is identified (#221)

    /// The relay's strict read of a verdict frame (a refused one closes the
    /// link), the guard that withholds every verdict, and the open check.
    static let seamRead: String = "        guard case .verdict(let requestID, let verdict)? = ApprovalChannel.frame(line) else {\n"
        + "            note(.frameRefused)\n            link?.close()\n            return\n        }\n"
    static let answerGuard: String = "        guard ApprovalChannel.passesAnswersBack else {\n            note(.verdictWithheld)\n"
        + "            return\n        }\n"
    static let openCheck: String = "        guard open.remove(requestID) != nil else {\n"
    /// The wire's switch, as declared: a constant, false.
    static let answerSwitch: String = "public static let passesAnswersBack = false"
    /// The relay's one read of it.
    static let answerRead: String = "guard ApprovalChannel.passesAnswersBack else {"

    /// The seam's peer check reads the listener's user, not which program it
    /// is, so the server passes no answer back: the relay withholds every
    /// verdict right after its strict read, ahead of the open check (which
    /// the one verdict notification follows directly, `verdictSiteFailures`),
    /// so no path from a seam frame to that write passes it; the switch is
    /// declared once, a false constant, and named in the four targets there
    /// and in that guard alone, so it is not flipped, shadowed or read
    /// another way; and the relay reaches Claude Code only through the
    /// writer it is handed (it names none of the server's own streams).
    static func answerGuardFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let relay = text(relayFile, in: sources)
        if count(answerGuard, in: relay) != 1 || count(seamRead + answerGuard + openCheck, in: relay) != 1 {
            failures.append("the relay must withhold every verdict right after its strict read, before the open check (#221)")
        }
        failures += PairingStructureTests.appSiteFailures(#"\bpassesAnswersBack\b"#, in: sources,
                                                          allowed: ["ApprovalChannel.swift": [answerSwitch: 1], relayFile: [answerRead: 1]],
                                                          rule: "the answer switch is declared false once and read by the relay's guard alone (#221)")
        for token in ["StandardStreams", "writeLine", "STDOUT_FILENO", "STDERR_FILENO"] where relay.contains(token) {
            failures.append("'\(token)' in \(relayFile) — the relay writes to Claude Code only through the writer it is handed")
        }
        return failures
    }

    @Test func theServerPassesNoAnswerBackUntilTheListenerIsIdentified() throws {
        let sources = try Self.sources()
        #expect(Self.answerGuardFailures(sources).isEmpty, "\(Self.answerGuardFailures(sources))")
        let relay: String = Self.text(Self.relayFile, in: sources)
        let wire: String = Self.text("ApprovalChannel.swift", in: sources)
        let emitted: String = "        emit(ApprovalChannel.verdictNotification("
        let relayed: String = "        open.insert(request.requestID)\n        note(.relayed)\n"
        for anchor in [Self.seamRead, Self.answerGuard, Self.openCheck, emitted, relayed] {
            #expect(Self.count(anchor, in: relay) == 1, "vacuity: '\(anchor.prefix(50))' is in the relay once")
        }
        #expect(Self.count(Self.answerSwitch, in: wire) == 1, "vacuity: the switch is declared in the wire")
        let relayMutant: (String, String) -> Sources = { old, new in
            Self.mutate(sources, Self.relayFile) { $0.replacingOccurrences(of: old, with: new) }
        }
        let wireMutant: (String) -> Sources = { new in
            Self.mutate(sources, "ApprovalChannel.swift") { $0.replacingOccurrences(of: Self.answerSwitch, with: new) }
        }
        let mutants: [(String, Sources)] = [
            ("the guard dropped", relayMutant(Self.answerGuard, "")),
            ("the guard inverted", relayMutant(Self.answerRead, "guard !ApprovalChannel.passesAnswersBack else {")),
            ("the guard passed by anything", relayMutant(Self.answerRead, "guard ApprovalChannel.passesAnswersBack || true else {")),
            ("the guard moved past the open check", Self.mutate(relayMutant(Self.answerGuard + Self.openCheck, Self.openCheck), Self.relayFile) {
                $0.replacingOccurrences(of: emitted, with: Self.answerGuard + emitted) }),
            ("the guard ahead of the strict read", Self.mutate(relayMutant(Self.seamRead + Self.answerGuard, Self.seamRead), Self.relayFile) {
                $0.replacingOccurrences(of: Self.seamRead, with: Self.answerGuard + Self.seamRead) }),
            ("the switch flipped to true", wireMutant("public static let passesAnswersBack = true")),
            ("the switch made a variable", wireMutant("public static var passesAnswersBack = false")),
            ("the switch made computed", wireMutant("public static var passesAnswersBack: Bool { true }")),
            ("the switch's value hidden behind an expression", wireMutant("public static let passesAnswersBack = false || true")),
            ("the switch declared twice behind #if", wireMutant("#if DEBUG\n    public static let passesAnswersBack = true\n    #else\n    "
                + Self.answerSwitch + "\n    #endif")),
            ("the switch shadowed in the relay's module", Self.mutate(sources, Self.serverFile) {
                $0 + "\nextension ApprovalChannel { static var passesAnswersBack: Bool { true } }" }),
            ("the switch read somewhere else", Self.mutate(sources, Self.intakeFile) {
                $0 + "\nlet zzAnswers = ApprovalChannel.passesAnswersBack || true" }),
            ("a second write to Claude Code through the server's stream", relayMutant(relayed, relayed + "        StandardStreams.writeLine(frame)\n")),
            ("the server's stream handed to the relay", relayMutant(relayed, relayed + "        let zz: (String) -> Void = StandardStreams.writeLine\n")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.answerGuardFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match controls: blanks around the declaration's line, and
        // names that only contain the switch's.
        let controls: Sources = Self.mutate(wireMutant("\t" + Self.answerSwitch + "   "), Self.hostFile) {
            $0 + "\nlet zzPassesAnswersBackCount = 0, passesAnswersBackward = 1"
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.answerGuardFailures(controls).isEmpty, "over-match: \(Self.answerGuardFailures(controls))")
        // A type in the relay's module named like the wire's, answering any
        // member by dynamic lookup, that never spells the switch: the guard
        // and the switch's sites are as they were, so this lock reads it as
        // the tree; the borrowed-name pin, alone, catches it.
        let lookup: String = "\n@dynamicMemberLookup\nenum ApprovalChannel {\n    static subscript(dynamicMember name: String) -> Bool { true }\n}\n"
        let uncut: Sources = try DecisionSinkStructureTests.uncutSources()
        let looked: Sources = Self.mutate(uncut, Self.serverFile) { $0 + lookup }
        #expect(Self.answerGuardFailures(Self.mutate(sources, Self.serverFile) { $0 + lookup }).isEmpty, "the lookup type names no switch")
        let catching: [String] = DecisionSinkStructureTests.othersCatching(looked, besides: "",
                                                                           baseline: DecisionSinkStructureTests.pinBaseline(uncut))
        #expect(catching == ["borrowed names"], "the lookup type is the borrowed-name pin's alone to catch: \(catching) caught it")
    }

    // MARK: - The server's output stream is handed to the relay once (#221)

    /// The channel server's entry point, whole, from its attribute to its
    /// type's closing brace (so no member joins it): the server's queue, the
    /// socket path, the one relay (handed the output stream as its `emit`,
    /// and a connector that hands each seam line to it alone) and the reader
    /// of standard input. No test runs `main` (it ends in `dispatchMain`),
    /// so this pin is what reads it.
    static let serverMainWhole: String = [
        "@main enum ChannelServer {", #"private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "channel")"#,
        "static func main() {", "signal(SIGPIPE, SIG_IGN)", #"let queue = DispatchQueue(label: "com.muratalkan.napcat.channel")"#,
        "let socketPath = SeamPaths.homeDirectory().map(SeamPaths.socketPath(home:))", streamHandoff,
        "guard let socketPath, let connection = SeamClient.connect(socketPath: socketPath, queue: queue) else { return nil }",
        "connection.start(onLine: onFrame, onClose: onClose)", "return connection",
        #"}, note: { logger.info("relay: \($0.rawValue, privacy: .public)") })"#,
        "let input = StandardInput(queue: queue) { relay.receive(stdinLine: $0) }", "input.start()", "dispatchMain()", "}", "}",
    ].joined(separator: " ")
    static let serverMainPin: DecisionSinkStructureTests.WholePin = (serverFile, #"\bfunc\s+main\b"#, serverMainWhole)
    /// The one line that hands the server's output stream to the relay.
    static let streamHandoff: String = "let relay = ChannelRelay(emit: StandardStreams.writeLine, connect: { onFrame, onClose in"
    /// The output stream's type and its writer, by name, in the four
    /// targets: at the type's declaration, the writer's, and the handoff
    /// alone (which names both).
    static let streamWordPattern: String = #"\b(?:StandardStreams|writeLine)\b"#
    static let streamWordSites: [String: [String: Int]] = [
        serverFile: ["enum StandardStreams {": 1, "static func writeLine(_ line: String) {": 1, streamHandoff: 2],
    ]

    /// `sources`: `DecisionSinkStructureTests.uncutSources()`. The entry
    /// point is declared once and is exactly as pinned, in every scan copy.
    static func serverMainFailures(_ sources: Sources) -> [String] {
        DecisionSinkStructureTests.wholeFailures(sources, [serverMainPin])
    }

    /// `sources`: `DecisionSinkStructureTests.uncutSources()`. The output
    /// stream is named at today's lines alone, in every scan copy.
    static func streamWordFailures(_ sources: Sources) -> [String] {
        DecisionSinkStructureTests.absent(streamWordSites.keys, in: sources)
            + PairingStructureTests.appSiteFailures(streamWordPattern, in: sources, allowed: streamWordSites,
                                                    rule: "the server's output stream is declared once and handed to the relay once (#221)")
    }

    /// The relay withholds every verdict, but it reads only the lines the
    /// server's `main` hands it, and no test runs `main`: so `main` is
    /// pinned whole, and the output stream is named at today's lines alone.
    /// A connector that also writes each seam line to Claude Code (by name,
    /// through a local alias, or by a second relay) is caught by both pins;
    /// any other statement in `main` (a C write, a stdio stream, `print`, a
    /// standard file handle, or one that writes nothing) by the whole pin,
    /// the writers among them by the C-write or descriptor-writer lock too;
    /// the stream named outside `main`, by the word pin; a writer outside
    /// `main`, by those two locks.
    @Test func theServersOutputStreamIsHandedToTheRelayOnce() throws {
        let sources: Sources = try DecisionSinkStructureTests.uncutSources()
        #expect(Self.serverMainFailures(sources).isEmpty, "\(Self.serverMainFailures(sources))")
        #expect(Self.streamWordFailures(sources).isEmpty, "\(Self.streamWordFailures(sources))")
        let server: String = Self.text(Self.serverFile, in: sources)
        let handoff: String = "        " + Self.streamHandoff + "\n"
        let started: String = "            connection.start(onLine: onFrame, onClose: onClose)\n"
        let dispatched: String = "        dispatchMain()\n"
        let logged: String = "    private static let logger = Logger(subsystem: \"com.muratalkan.napcat\", category: \"channel\")\n"
        let queued: String = "        let queue = DispatchQueue(label: \"com.muratalkan.napcat.channel\")\n"
        let readIn: String = "        let count = read(STDIN_FILENO, &buffer, buffer.count)\n"
        for anchor in [handoff, started, dispatched, logged, queued, readIn] {
            #expect(Self.count(anchor, in: server) == 1, "vacuity: '\(anchor.prefix(50))' is in the server once")
        }
        #expect(ApprovalRecordPathStructureTests.siteTally(Self.streamWordPattern, in: server) == Self.streamWordSites[Self.serverFile],
                "vacuity: the words are read at today's three lines, the handoff naming both")
        let planted: (String, String) -> Sources = { anchor, replacement in
            Self.mutate(sources, Self.serverFile) { $0.replacingOccurrences(of: anchor, with: replacement) }
        }
        let inMain: (String) -> Sources = { line in planted(dispatched, line + dispatched) }
        let appended: (String) -> Sources = { text in Self.mutate(sources, Self.serverFile) { $0 + text } }
        let tapped: String = "            connection.start(onLine: { onFrame($0); StandardStreams.writeLine(String(decoding: $0, as: UTF8.self)) }, "
            + "onClose: onClose)\n"
        let aliased: Sources = Self.mutate(sources, Self.serverFile) {
            $0.replacingOccurrences(of: handoff, with: "        let out = StandardStreams.writeLine\n" + handoff)
                .replacingOccurrences(of: started, with: "            connection.start(onLine: { onFrame($0); out(String(decoding: $0, as: UTF8.self)) }, "
                                      + "onClose: onClose)\n")
        }
        let decoy: Sources = Self.mutate(planted(started, "            _ = write(1, \"{}\\n\", 3)\n" + started), Self.serverFile) {
            $0 + "\nlet zzDecoy = #\"" + Self.serverMainWhole + "\"#\n"
        }
        // Which of the two pins catches each, and which existing lock
        // besides ("" for none).
        let mutants: [(name: String, planted: Sources, whole: Bool, words: Bool, also: String)] = [
            ("the connector writing each seam line to the output stream", planted(started, tapped), true, true, ""),
            ("the same through a local alias", aliased, true, true, ""),
            ("a second relay handed the output stream", inMain("        let zzRelay = ChannelRelay(emit: StandardStreams.writeLine, "
                + "connect: { _, _ in nil }, note: { _ in })\n"), true, true, ""),
            ("the one handoff handed a wrapper", planted("ChannelRelay(emit: StandardStreams.writeLine,",
                                                         "ChannelRelay(emit: { StandardStreams.writeLine($0); zzTap($0) },"), true, true, ""),
            ("the writer backticked in main", inMain("        StandardStreams.`writeLine`(\"{}\")\n"), true, true, ""),
            ("the writer behind a block comment in main", inMain("        StandardStreams./* x */writeLine(\"{}\")\n"), true, true, ""),
            ("the handoff repeated in another function", appended("\nenum ZZ {\n    static func zz() {\n        " + Self.streamHandoff
                + "\n            nil\n        }, note: { _ in })\n    }\n}\n"), false, true, ""),
            ("the output stream aliased beside the entry point", appended("\ntypealias ZZOut = StandardStreams\n"), false, true, ""),
            ("a direct write to standard output in main", inMain("        _ = write(STDOUT_FILENO, \"{}\\n\", 3)\n"), true, false, "C writes"),
            ("a write to descriptor 1 in the connector", planted(started, "            _ = write(1, \"{}\\n\", 3)\n" + started), true, false,
             "C writes"),
            ("fputs to standard output in main", inMain("        fputs(\"{}\\n\", stdout)\n"), true, false, "descriptor writers"),
            ("print in main", inMain("        print(\"{}\")\n"), true, false, "descriptor writers"),
            ("the standard output handle in main", inMain("        FileHandle.standardOutput.write(Data(\"{}\\n\".utf8))\n"), true, false,
             "descriptor writers"),
            ("a direct write to standard output in the input reader", planted(readIn, readIn + "        _ = write(STDOUT_FILENO, \"{}\\n\", 3)\n"),
             false, false, "C writes"),
            ("fputs to standard output in the input reader", planted(readIn, readIn + "        fputs(\"{}\\n\", stdout)\n"), false, false,
             "descriptor writers"),
            ("a statement in main that writes nothing", inMain("        _ = 0\n"), true, false, ""),
            ("a harmless edit in main, the queue's label", planted(queued, queued.replacingOccurrences(of: ".channel\"", with: ".channel.zz\"")),
             true, false, ""),
            ("a member added to the entry point's type", planted(logged, logged + "    static let zz = 0\n"), true, false, ""),
            ("the pinned entry point kept in a literal, the real one changed", decoy, true, true, "C writes"),
        ]
        for (name, mutant, whole, words, also) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(Self.serverMainFailures(mutant).isEmpty != whole, "canary '\(name)': the whole pin \(whole ? "missed it" : "read it")")
            #expect(Self.streamWordFailures(mutant).isEmpty != words, "canary '\(name)': the word pin \(words ? "missed it" : "read it")")
            if !also.isEmpty {
                let lock = DecisionSinkStructureTests.sourcePins.filter { $0.name == also }
                #expect(lock.count == 1 && lock.allSatisfy { !$0.failures(mutant).isEmpty }, "canary '\(name)' was NOT caught by the \(also) lock")
            }
        }
        // Over-match controls: whitespace and comments inside `main` (no
        // trailing comment on a line the word pin reads: those lines are
        // read as written), a comment above the entry point, a body outside
        // it, and names that only contain the stream's words.
        let guarded: String = "            guard let socketPath, let connection = SeamClient.connect(socketPath: socketPath, queue: queue) else { return nil }\n"
        let started2: String = "        input.start()\n"
        for anchor in [readIn, guarded, started2, "@main\n"] {
            #expect(Self.count(anchor, in: server) == 1, "vacuity: '\(anchor.prefix(50))' is in the server once")
        }
        let controls: Sources = Self.mutate(sources, Self.serverFile) {
            $0.replacingOccurrences(of: guarded, with: "            guard let socketPath,\n\t\t\t\t  let connection = SeamClient.connect(socketPath: socketPath, "
                                    + "queue: queue) else { return nil }\n")
                .replacingOccurrences(of: started2, with: "\n\t\t// stdin last\n        input.start()   // then wait\n\n")
                .replacingOccurrences(of: "@main\n", with: "/// zz\n@main\n")
                .replacingOccurrences(of: readIn, with: "        let count: Int = read(STDIN_FILENO, &buffer, buffer.count)\n")
                + "\nstruct StandardStreamsLog {}\nenum ZZStandardStreams { static let writeLines = 0, rewriteLine = 1, writeLineCount = 2 }"
                + LidGuardStructureTests.wholeLineCommentsRemoved("\n/// never StandardStreams.writeLine(frame)")
        }
        #expect(controls.map { $0.text } != sources.map { $0.text }, "the controls applied")
        #expect(Self.serverMainFailures(controls).isEmpty, "over-match: \(Self.serverMainFailures(controls))")
        #expect(Self.streamWordFailures(controls).isEmpty, "over-match: \(Self.streamWordFailures(controls))")
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

    /// The lifecycle's open (#198), read on the flattened code of every scan
    /// copy, so a line break or a comment between its parts reads as at
    /// most one space and a backtick as nothing: in the intake, any member
    /// named `open`, qualified, implicit or unapplied; in every other file
    /// but the state machine (the open's own), the call's shape — an `open`
    /// whose first argument label is `id`, qualified by any name, implicit
    /// or bare, applied or named with its labels — and the lifecycle's name
    /// before `.open`, also inside a longer name or across a postfix `#if`'s
    /// directives (#211: each `#if`, `#elseif` or `#else` with what it holds
    /// up to the next directive, a brace or a semicolon, and each `#endif`),
    /// applied or not. Outside the intake, a reference written neither way
    /// is not read.
    static let intakeOpenPattern: String = #"\. ?open\b"#
    static let openShapePattern: String = #"\bopen ?\( ?id ?:"#
    static let postfixDirectives: String = #"(?: ?#(?:if|elseif|else)\b[^#{};]*?| ?#endif\b)*"#
    static let lifecycleOpenPattern: String = #"ApprovalLifecycle"# + postfixDirectives + #" ?\. ?open\b|"# + openShapePattern

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
    /// counted on the flattened code, #198). `sources`: `pathSources()`
    /// (#244: `sources()`, read before, names every file by its file name
    /// alone, so a file in another target under the state machine's name
    /// went unread, one under the gate's name could classify, and one under
    /// the intake's name could classify and open once).
    static func gateOrderFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        let classify = "ApprovalGate.classify("
        // The gate's own file is read for the open, not for `classify`.
        for (name, text) in sources where name != stateMachinePath {
            let found: Int = count(classify, in: text)
            if name != classificationPath && (name == intakeFile ? found != 1 : found != 0) {
                failures.append("\(found) '\(classify)' in \(name)")
            }
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
        let sources = try Self.pathSources()
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
        let intakeShapes: [Int] = Self.flatCounts(Self.openShapePattern, in: intake)
        let declaredShapes: [Int] = Self.flatCounts(Self.openShapePattern, in: Self.text(Self.stateMachinePath, in: sources))
        #expect(intakeShapes.allSatisfy { $0 == 1 } && declaredShapes.allSatisfy { $0 == 1 },
                "vacuity: the call's shape reads the intake's one open and the open's declaration, once each")
        let newFile: (String) -> Sources = { text in sources + [(name: "ZZOpen.swift", text: text)] }
        let arguments: String = "(id: i, classification: c, armed: true, now: 0)"
        let prefixed: String = "typealias ZZApprovalLifecycle = ApprovalLifecycle\n"
        let short: String = "typealias ZZShort = ApprovalLifecycle\n"
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
            // Outside the intake, in a new file: the call's shape as an
            // implicit member, through a short alias or one whose name ends
            // in the lifecycle's, over lines, named with its labels, and bare
            // in an extension; the longer name's open unapplied; and an open
            // in the gate's own file.
            ("an implicit open in a new file", newFile("enum ZZ { static let zz: ApprovalLifecycle = .open" + arguments + ".lifecycle }")),
            ("a short alias's open in a new file", newFile(short + "enum ZZ { static let zz = ZZShort.open" + arguments + " }")),
            ("a longer name's open in a new file", newFile(prefixed + "enum ZZ { static let zz = ZZApprovalLifecycle.open" + arguments + " }")),
            ("an alias's open over lines in a new file", newFile(short + "enum ZZ { static let zz = ZZShort\n    .open(\n        id: i, classification: c, armed: true, now: 0) }")),
            ("an alias's open named with its labels", newFile(short + "enum ZZ { static let zz = ZZShort.open(id:classification:armed:now:timeToLive:) }")),
            ("a bare open in an extension", newFile("extension ApprovalLifecycle { static func zz() -> ApprovalLifecycle { open" + arguments + ".lifecycle } }")),
            ("a longer name's open taken unapplied", newFile(prefixed + "enum ZZ { static let zz = ZZApprovalLifecycle.open }")),
            ("a lifecycle opened in the gate's file", Self.mutate(sources, Self.classificationPath) {
                $0 + "\nlet l = ApprovalLifecycle.open" + arguments }),
            // #211: the lifecycle's name and its `.open` apart across a
            // postfix `#if`, unapplied, in its active branch, an `#else` or an
            // `#elseif` whose condition holds a dot.
            ("the open behind a postfix #if, unapplied", newFile("enum ZZ {\n    static let zz = ApprovalLifecycle\n    #if true\n        .open\n    #endif\n}")),
            ("the open in a postfix #else", newFile("enum ZZ {\n    static let zz = ApprovalLifecycle\n    #if false\n        .zz\n    #else\n        .open\n    #endif\n}")),
            ("the open in a postfix #elseif", newFile(
                "enum ZZ {\n    static let zz = ApprovalLifecycle\n    #if os(iOS)\n        .zz\n    #elseif compiler(>=5.9)\n        .open\n    #endif\n}")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.gateOrderFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // The line break is what the raw count missed.
        let broken: String = "ApprovalLifecycle\n            .open(id: id"
        #expect(Self.count("ApprovalLifecycle.open(", in: broken) == 0 && Self.flatCounts(Self.intakeOpenPattern, in: broken) == [1],
                "vacuity: the line break hides the call from a raw count and not from the flattened one")
        let postfixed: String = "let f = ApprovalLifecycle\n#if true\n    .open\n#endif"
        let postfixedCounts: [Int] = Self.flatCounts(Self.lifecycleOpenPattern, in: postfixed)
        let once: [Int] = [1]
        #expect(postfixedCounts == once, "vacuity: the name half reads the open across a postfix #if (#211)")
        // Over-match controls: a blank line and a line the stripper empties
        // (a comment, read as spaces) between the two checks; and words that
        // only contain the open's, a member of another name, and another
        // type's open outside the intake; and, in a new file, opens of other
        // shapes: another first label, one that only starts like `id`, names
        // that only contain `open`, and the longer name before another member.
        let gap: String = "\n" + String(repeating: " ", count: 20) + "\n"
        let spaced: Sources = without(serverOnly + gap + clientOnly)
        let words: Sources = Self.mutate(opening("        let zzReopened = opened.lifecycle.isTerminalOpen, zzOpenCount = opened.transition\n"),
                                         Self.hostFile) { $0 + "\nfunc zz(_ u: URL) { _ = NSWorkspace.shared.open(u); _ = ZZLifecycle.open }" }
        let shapes: Sources = newFile("enum ZZ { static func zz(_ d: ZZDoor, _ u: URL) { d.open(url: u); _ = d.open(identifier: 3); d.reopen(id: 1); "
                                      + "_ = d.opened(id: 2); _ = ZZApprovalLifecycle.opening } }")
        // #211: a postfix `#if` around other members of the lifecycle's name.
        let postfix: Sources = newFile("enum ZZ {\n    static let zz = ZZApprovalLifecycle\n    #if DEBUG\n        .opening\n    #endif\n"
                                       + "    static let zy = ApprovalLifecycle\n    #if DEBUG\n        .self\n    #endif\n}")
        for (name, control) in [("the checks spaced", spaced), ("words like open", words), ("opens of other shapes", shapes),
                                ("a postfix #if around other members", postfix)] {
            #expect(control.map { $0.text } != sources.map { $0.text }, "the control '\(name)' applied")
            #expect(Self.gateOrderFailures(control).isEmpty, "over-match '\(name)': \(Self.gateOrderFailures(control))")
        }
        // #244: a file in another target under the state machine's, the
        // gate's or the intake's name is not that file. A lifecycle opened in
        // a namesake of the state machine, a classification in a namesake of
        // the gate's file, and the intake's one classification and one open
        // in a namesake of the intake are each named, by the namesake's path.
        let classified: String = "let zz = ApprovalGate.classify(toolName: t, inputPreview: p)\n"
        let openedElsewhere: String = "let zy = ApprovalLifecycle.open" + arguments + "\n"
        var planted: [(path: String, text: String)] = []
        planted += Self.namesakes(of: Self.stateMachinePath).map { ($0, openedElsewhere) }
        planted += Self.namesakes(of: Self.classificationPath).map { ($0, classified) }
        planted += Self.namesakes(of: Self.intakeFile).map { ($0, classified + openedElsewhere) }
        #expect(planted.count == 9, "vacuity: three pinned files, a namesake of each in each other target")
        for (path, text) in planted {
            let mutant: Sources = Self.inserting(sources, path, text)
            #expect(mutant.count == sources.count + 1, "canary at \(path) did not apply")
            #expect(Self.names(Self.gateOrderFailures(mutant), path), "canary at \(path) was NOT named by the gate-order lock")
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

    /// `sources`: `pathSources()` (#244: `sources()`, read before, names
    /// every file by its file name alone, so a file under the seam's, the
    /// relay's, the server's or the wire's name read before it, in
    /// Sources/NapCat say, was read in its place, and one in another target
    /// under the server's name could resolve the real socket path). A file
    /// the check reads that is not there fails it.
    static func serverFailures(_ sources: Sources) -> [String] {
        var failures: [String] = []
        for name in [seamPath, relayPath, serverPath, wirePath] where !sources.contains(where: { $0.name == name }) {
            failures.append("\(name) not found — the server lint would be vacuous")
        }
        for name in [seamPath, relayPath, serverPath] {
            let code = text(name, in: sources)
            for token in serverBannedTokens where code.contains(token) {
                failures.append("'\(token)' in \(name) — the server reads no configuration and writes stdout only through write(2)")
            }
        }
        // The plain channel method would put text in front of Claude (F4.1).
        for (name, text) in sources where text.contains("\"notifications/claude/channel\"") {
            failures.append("\(name) names the channel message method — the server never sends one")
        }
        let wire = text(wirePath, in: sources)
        if wire.contains("\"tools\"") || wire.contains("\\\"tools\\\"") || wire.contains("instructions") {
            failures.append("the handshake must declare the two channel capabilities only")
        }
        // The real socket path is resolved by the server's entry point and
        // (slice S2) by the Mac toggle's one factory — once each, nowhere
        // else. AMENDED (#247): the approvals folder's home is resolved once
        // more, for the outstanding-Unpair record's real file beside the
        // socket (`unpairRecordFile`), never the socket's path.
        for (name, text) in sources {
            let resolutions = count("SeamPaths.homeDirectory(", in: text)
            let allowed = name == serverPath || name == toggleFile || name == unpairRecordFile ? 1 : 0
            if resolutions != allowed {
                failures.append("\(resolutions) real socket path resolution(s) in \(name) — only the server's entry point, "
                    + "the toggle's factory and the Unpair record's real file may, once each")
            }
        }
        let record = text(unpairRecordFile, in: sources)
        if count("SeamPaths.socketPath(", in: record) != 0
            || count(PairingStructureTests.realFileLine, in: record) != 1 {
            failures.append("the Unpair record resolves the home once, for its own file's binding, and never the socket's path")
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
        let sources = try Self.pathSources()
        #expect(Self.serverFailures(sources).isEmpty, "\(Self.serverFailures(sources))")
        let mutants: [(String, Sources)] = [
            ("the server reads the environment", Self.mutate(sources, Self.serverPath) { $0 + "\nlet h = getenv(\"HOME\")" }),
            ("the relay prints", Self.mutate(sources, Self.relayPath) { $0 + "\nfunc p() { print(\"x\") }" }),
            ("the seam reads a file", Self.mutate(sources, Self.seamPath) { $0 + "\nlet f = FileManager.default" }),
            ("a channel message", Self.mutate(sources, Self.wirePath) {
                $0 + "\nstatic let m = \"notifications/claude/channel\"" }),
            ("a tools capability", Self.mutate(sources, Self.wirePath) { $0 + "\nlet t = \"\\\"tools\\\":{}\"" }),
            ("the host resolves the real path", Self.mutate(sources, Self.hostFile) { $0 + "\nlet h = SeamPaths.homeDirectory()" }),
            ("the model resolves the real path", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet h = SeamPaths.homeDirectory()" }),
            ("the toggle resolves it twice", Self.mutate(sources, Self.toggleFile) { $0 + "\nlet h = SeamPaths.homeDirectory()" }),
            ("the Unpair record resolves it twice", Self.mutate(sources, Self.unpairRecordFile) { $0 + "\nlet h = SeamPaths.homeDirectory()" }),
            ("the Unpair record names the socket", Self.mutate(sources, Self.unpairRecordFile) {
                $0 + "\nlet h = SeamPaths.socketPath(home: \"x\")" }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != sources.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.serverFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // #244: a file in another target under the name of a file the check
        // reads is not that file. With a namesake of the seam's, the relay's
        // or the server's file in any other target (one read before the real
        // file was read in its place), a banned word planted in the real file
        // is still named, by its path; a namesake of the server's file may
        // not resolve the real socket path; a namesake of the wire's file
        // does not hide a capability planted in the wire; and a file the
        // check reads, moved to another target, fails it.
        let clean = "enum ZZNamesake {}\n"
        var shadows: [(namesake: String, mutant: Sources, path: String)] = []
        for (path, planted) in [(Self.seamPath, "\nlet f = FileManager.default"), (Self.relayPath, "\nfunc p() { print(\"x\") }"),
                                (Self.serverPath, "\nlet h = getenv(\"HOME\")")] {
            for namesake in Self.namesakes(of: path) {
                shadows.append((namesake, Self.mutate(Self.inserting(sources, namesake, clean), path) { $0 + planted }, path))
            }
        }
        #expect(shadows.count == 9, "vacuity: three read files, a namesake of each in each other target")
        for (namesake, mutant, path) in shadows {
            #expect(mutant.map { $0.text }.contains(clean) && mutant.count == sources.count + 1, "canary at \(namesake) did not apply")
            #expect(Self.names(Self.serverFailures(mutant), path), "a banned word in \(path), beside a namesake at \(namesake), was NOT named")
        }
        for namesake in Self.namesakes(of: Self.serverPath) {
            let mutant = Self.inserting(sources, namesake, "let h = SeamPaths.homeDirectory()\n")
            #expect(Self.names(Self.serverFailures(mutant), namesake), "the namesake at \(namesake) resolving the real path was NOT named")
        }
        let capability = Self.mutate(sources, Self.wirePath) { $0 + "\nlet t = \"\\\"tools\\\":{}\"" }
        for namesake in Self.namesakes(of: Self.wirePath) {
            #expect(Self.serverFailures(Self.inserting(capability, namesake, clean))
                        .contains("the handshake must declare the two channel capabilities only"),
                    "a capability in the wire, beside a namesake at \(namesake), was NOT caught")
        }
        for path in [Self.seamPath, Self.relayPath, Self.serverPath, Self.wirePath] {
            for namesake in Self.namesakes(of: path) {
                let moved: Sources = sources.map { $0.name == path ? (name: namesake, text: $0.text) : $0 }
                #expect(Self.serverFailures(moved).contains("\(path) not found — the server lint would be vacuous"),
                        "\(path) moved to \(namesake) was NOT caught")
            }
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
