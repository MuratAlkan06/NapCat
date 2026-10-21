// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// FA-8 (policy half): the pure Track C finish-alert policy stays I/O-free —
/// no filesystem, dispatch sources/timers, network, subprocess, process or
/// IOKit power symbols, logging, clock/environment reads, or defaults — and
/// can never name the stored ntfy topic. Only `import Foundation` is allowed.
/// Canary-proven in-suite: every banned token injected into a copy of the
/// shipped file must trip the lint.
///
/// FA-8 (shell half, slice C3): the watcher + controller bans, their
/// log hygiene, the single gated construction site, the B1 amendment fence,
/// and the wiring points — each canary-proven the same way.
struct FinishAlertStructureTests {
    static let policyFile = "FinishAlertPolicy.swift"

    /// Banned in code (comments are stripped first — doc comments may NAME a
    /// boundary). Matched case-sensitively; the log-call tokens below are
    /// additionally matched case-INSENSITIVELY.
    static let bannedTokens = [
        "FileManager", "FileHandle", "DispatchSource", "DispatchQueue", "URLSession", "URLRequest",
        "Process(", "ProcessInfo", "proc_", "IOPM", "IORegisterForSystemPower", "Logger", "Timer",
        "UserDefaults", "NotificationCenter", "Date()", "lidGuardNtfyTopic", "storedTopic",
    ]

    /// Every lint failure for one policy-file text (empty = clean).
    static func lintFailures(_ source: String) -> [String] {
        var failures: [String] = []
        let code = LidGuardStructureTests.codeOnly(source)
        for token in bannedTokens where code.contains(token) {
            failures.append("'\(token)' in \(policyFile) — the finish-alert policy must stay I/O-free")
        }
        for token in LidGuardStructureTests.logCallTokens where code.lowercased().contains(token) {
            failures.append("log call '\(token)' in \(policyFile) — the policy never logs")
        }
        for line in code.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(separator: " ")
            // `import X`, `@testable import X`, `@_exported import X`, `import struct X.Y` …
            guard let importIndex = words.firstIndex(of: "import"),
                  words[..<importIndex].allSatisfy({ $0.hasPrefix("@") }) else { continue }
            if trimmed != "import Foundation" {
                failures.append("'\(trimmed)' — the only import allowed in \(policyFile) is Foundation")
            }
        }
        return failures
    }

    static func shippedPolicy() throws -> String {
        try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(policyFile),
                   encoding: .utf8)
    }

    @Test func shippedPolicyPassesTheLint() throws {
        let source = try Self.shippedPolicy()
        // Vacuity guard: the file must really be the policy.
        #expect(source.contains("enum FinishAlertPolicy"))
        #expect(source.contains("static func observe("))
        #expect(Self.lintFailures(source).isEmpty, "\(Self.lintFailures(source))")
    }

    /// Canary: every banned token, a log call, and a foreign import must trip
    /// the lock when injected into a copy of the shipped file; the same token
    /// inside a `//` comment must NOT (proves the comment strip is what lets
    /// doc comments name the boundary, not a blind spot).
    @Test func lintCatchesMutants() throws {
        let original = try Self.shippedPolicy()
        try #require(Self.lintFailures(original).isEmpty, "canary baseline must be clean")
        let anchor = "enum FinishAlertPolicy {"
        #expect(original.contains(anchor), "canary setup: anchor must exist")

        var mutants: [(String, String)] = Self.bannedTokens.map { token in
            ("banned token \(token)", "    static let canary = \(token)")
        }
        mutants += [
            ("logger call", "    static func canary() { alertLogger.notice(\"x\") }"),
            ("print call", "    static func canary() { print(\"x\") }"),
            ("NSLog call", "    static func canary() { NSLog(\"x\") }"),
            ("os_log call", "    static func canary() { os_log(\"x\") }"),
            ("defaults read", "    static let canary = UserDefaults.standard.string(forKey: \"x\")"),
            ("topic read", "    static let canary = DefaultsKeys.lidGuardNtfyTopic"),
            ("dispatch timer", "    static let canary = DispatchSource.makeTimerSource()"),
            ("wall clock read", "    static let canary = Date().timeIntervalSince1970"),
        ]
        for (name, line) in mutants {
            let mutant = original.replacingOccurrences(of: anchor, with: anchor + "\n" + line)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.lintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the lint")
        }

        let importMutants = [
            ("second import", "import Foundation", "import Foundation\nimport Darwin"),
            ("IOKit import", "import Foundation", "import IOKit"),
            ("attributed import", "import Foundation", "import Foundation\n@preconcurrency import Dispatch"),
            ("scoped import", "import Foundation", "import Foundation\nimport class Foundation.FileManager"),
        ]
        for (name, target, replacement) in importMutants {
            let mutant = original.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != original, "canary setup '\(name)'")
            #expect(!Self.lintFailures(mutant).isEmpty, "canary '\(name)' was NOT caught by the lint")
        }

        // Negative control: naming a banned symbol in a comment is allowed.
        let commented = original.replacingOccurrences(
            of: anchor, with: anchor + "\n    // never FileManager, Timer, Logger, UserDefaults, lidGuardNtfyTopic")
        #expect(commented != original)
        #expect(Self.lintFailures(commented).isEmpty, "a doc mention must not trip the lint")
    }

    // MARK: - FA-8 (watcher + controller half, slice C3)

    static let watcherFile = "MarkerDirectoryWatcher.swift"
    static let controllerFile = "FinishAlertController.swift"
    static let shellFiles = [watcherFile, controllerFile]

    /// Banned in BOTH shell files: no network (the shared sender is the only
    /// way out), no process probing or B1 sampling, no IOKit power, no
    /// timers or anything periodic (B1 amendment: one-shot callbacks only, via
    /// the injected scheduler), no reach into the B1 snapshot or the menu,
    /// and no way to read the stored topic.
    static let shellBannedTokens = [
        "URLSession", "URLRequest", "proc_", "ClaudeProcessProber", "IOPM", "IORegisterForSystemPower",
        "Process(", "Timer", "makeTimerSource", "repeating", "lidGuardNtfyTopic", "storedTopic",
        ".sample()", "sampleBusyNow", "ClaudeActivityController", "MenuStateModel",
    ]

    /// The watcher is a pure observer: it does not log at all.
    static let watcherOnlyBannedTokens = ["Logger", "import os"]

    /// A log line may never name these (the topic is a password; session ids
    /// are internal diff keys).
    static let logSecretTokens = ["topic", "Topic", "absoluteString", ".url", "endpoint", "sessionID",
                                  "destination", "storedServer", "tracked.keys"]

    /// `.public` interpolations: counts and fixed reason words only — these
    /// exact expressions, or any `….count` (a number; `tracked.keys` and other
    /// id-bearing names are caught by `logSecretTokens` first).
    static let publicLogExpressions: Set<String> = [
        "fields.publicCategory", "reason.rawValue", "Self.kindWord(item.kind)", "Int(delay)", "count", "dropped",
    ]

    static func isPublicLogExpression(_ expression: String) -> Bool {
        publicLogExpressions.contains(expression) || expression.hasSuffix(".count")
    }

    /// `.private` interpolations: the outcome's fixed-vocabulary detail only.
    static let privateLogExpressions: Set<String> = ["detail"]

    /// The `\( … )` bodies of one source line (nested parentheses honoured).
    static func interpolations(in line: String) -> [String] {
        var found: [String] = []
        var rest = Substring(line)
        while let open = rest.range(of: "\\(") {
            var depth = 1
            var index = open.upperBound
            while index < rest.endIndex {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                if depth == 0 { break }
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else {
                found.append(String(rest[open.upperBound...]))
                break
            }
            found.append(String(rest[open.upperBound..<index]))
            rest = rest[rest.index(after: index)...]
        }
        return found
    }

    /// Every lint failure for one shell file's text (empty = clean). Mirrors
    /// `noLidGuardLogLineCanEchoTheTopicOrTheUrl`, stricter: each `.public`
    /// interpolation must be an allow-listed count / reason expression and
    /// each `.private` one the outcome detail; levels must be persisted.
    static func shellLintFailures(_ source: String, file: String) -> [String] {
        var failures: [String] = []
        let code = LidGuardStructureTests.codeOnly(source)
        for token in shellBannedTokens where code.contains(token) {
            failures.append("'\(token)' in \(file) — banned in the finish-alert shell")
        }
        if file == watcherFile {
            for token in watcherOnlyBannedTokens where code.contains(token) {
                failures.append("'\(token)' in \(file) — the watcher never logs")
            }
            for token in LidGuardStructureTests.logCallTokens where code.lowercased().contains(token) {
                failures.append("log call '\(token)' in \(file) — the watcher never logs")
            }
        }
        for level in ["logger.debug(", "logger.trace(", "logger.info("] where code.lowercased().contains(level) {
            failures.append("'\(level)' in \(file) — not persisted by macOS; use .notice or higher")
        }
        for line in code.split(separator: "\n") {
            let text = String(line)
            guard LidGuardStructureTests.logCallTokens.contains(where: { text.lowercased().contains($0) }) else {
                continue
            }
            for secret in logSecretTokens where text.contains(secret) {
                failures.append("\(file): a log line carries '\(secret)': \(text)")
            }
            for body in interpolations(in: text) {
                guard let split = body.range(of: ", privacy: ", options: .backwards) else {
                    failures.append("\(file): interpolation without a privacy level: \(text)")
                    continue
                }
                let expression = String(body[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
                let level = String(body[split.upperBound...]).trimmingCharacters(in: .whitespaces)
                switch level {
                case ".public" where isPublicLogExpression(expression):
                    break
                case ".private" where privateLogExpressions.contains(expression):
                    break
                default:
                    failures.append("\(file): '\(expression)' at '\(level)' is not a count / reason word: \(text)")
                }
            }
        }
        return failures
    }

    static func shipped(_ file: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(file), encoding: .utf8)
    }

    @Test func shippedShellFilesPassTheLint() throws {
        var logLines = 0
        for file in Self.shellFiles {
            let source = try Self.shipped(file)
            #expect(Self.shellLintFailures(source, file: file).isEmpty,
                    "\(Self.shellLintFailures(source, file: file))")
            logLines += LidGuardStructureTests.codeOnly(source).split(separator: "\n")
                .filter { line in LidGuardStructureTests.logCallTokens.contains { line.lowercased().contains($0) } }
                .count
        }
        // Vacuity guards: the files are the real ones, and the controller
        // really logs (so the log rules are exercised).
        #expect(try Self.shipped(Self.watcherFile).contains("makeFileSystemObjectSource("))
        #expect(try Self.shipped(Self.controllerFile).contains("final class FinishAlertController"))
        #expect(logLines >= 8, "expected the controller's log lines to be scanned, found \(logLines)")
    }

    /// Canary: every banned token, every log-hygiene violation, and a watcher
    /// log call must trip the lint when injected; comments must not.
    @Test func shellLintCatchesMutants() throws {
        let anchors = [
            Self.watcherFile: "final class KqueueMarkerDirectoryWatcher: MarkerDirectoryWatching, @unchecked Sendable {",
            Self.controllerFile: "final class FinishAlertController {",
        ]
        for file in Self.shellFiles {
            let original = try Self.shipped(file)
            try #require(Self.shellLintFailures(original, file: file).isEmpty, "canary baseline must be clean")
            let anchor = try #require(anchors[file])
            #expect(original.contains(anchor), "canary setup: anchor must exist in \(file)")
            var mutants: [(String, String)] = Self.shellBannedTokens.map { token in
                ("banned token \(token)", "    let canary = \(token)")
            }
            mutants += [
                ("periodic dispatch timer", "    let canary = DispatchSource.makeTimerSource()"),
                ("B1 sample", "    func canary() { detection.sample() }"),
                ("unpersisted level", "    func canary() { Self.logger.debug(\"x\") }"),
                ("topic in a log line", "    func canary() { Self.logger.notice(\"topic\") }"),
                ("session id at public", "    func canary() { Self.logger.notice(\"\\(id, privacy: .public)\") }"),
                ("missing privacy", "    func canary() { Self.logger.notice(\"\\(dropped)\") }"),
                ("auto privacy", "    func canary() { Self.logger.notice(\"\\(dropped, privacy: .auto)\") }"),
                ("private non-detail", "    func canary() { Self.logger.notice(\"\\(key, privacy: .private)\") }"),
                ("destination echo",
                 "    func canary() { Self.logger.notice(\"\\(destination, privacy: .private)\") }"),
                ("renamed logger", "    func canary() { osLogger.notice(\"\\(tracked.keys, privacy: .public)\") }"),
                ("print", "    func canary() { print(\"\\(id)\") }"),
            ]
            if file == Self.watcherFile {
                mutants += [
                    ("watcher logger", "    let canary = Logger(subsystem: \"x\", category: \"y\")"),
                    ("watcher clean log call", "    func canary() { Self.logger.notice(\"x\") }"),
                ]
            }
            for (name, line) in mutants {
                let mutant = original.replacingOccurrences(of: anchor, with: anchor + "\n" + line)
                #expect(mutant != original, "canary setup '\(name)' in \(file)")
                #expect(!Self.shellLintFailures(mutant, file: file).isEmpty,
                        "canary '\(name)' was NOT caught in \(file)")
            }
            let commented = original.replacingOccurrences(
                of: anchor, with: anchor + "\n    // never Timer, URLSession, storedTopic, Logger, sampleBusyNow")
            #expect(Self.shellLintFailures(commented, file: file).isEmpty, "a doc mention must not trip the lint")
        }
        // The import-os ban is watcher-only: the controller legitimately logs.
        let watcher = try Self.shipped(Self.watcherFile)
        let withImport = watcher.replacingOccurrences(of: "import Foundation", with: "import Foundation\nimport os")
        #expect(!Self.shellLintFailures(withImport, file: Self.watcherFile).isEmpty)
    }

    /// The watcher, the controller and the production scheduler are built in
    /// ONE place: `FinishAlertController.makeIfEnabled` (debug-sim gated).
    /// The app reaches the feature only through that factory.
    static func constructionFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for token in ["KqueueMarkerDirectoryWatcher(", "FinishAlertController(", "MainQueueFinishAlertScheduler("] {
            for (name, text) in sources where text.contains(token) && name != controllerFile {
                failures.append("'\(token)' in \(name) — construct through FinishAlertController.makeIfEnabled")
            }
            let owner = sources.first { $0.name == controllerFile }?.text ?? ""
            let count = owner.components(separatedBy: token).count - 1
            if count != 1 {
                failures.append("'\(token)' appears \(count)× in \(controllerFile) — expected exactly one site")
            }
        }
        let app = sources.first { $0.name == "NapCatApp.swift" }?.text ?? ""
        if !app.contains("FinishAlertController.makeIfEnabled(") {
            failures.append("NapCatApp must build the finish alert through makeIfEnabled")
        }
        return failures
    }

    @Test func theFinishAlertHasASingleGatedConstructionSite() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        #expect(Self.constructionFailures(sources).isEmpty, "\(Self.constructionFailures(sources))")

        // Canaries: a stray construction, a second site, or a missing factory
        // call must all trip.
        func mutate(_ name: String, _ transform: (String) -> String) -> [(name: String, text: String)] {
            sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
        }
        let canaries: [(String, [(name: String, text: String)])] = [
            ("app builds the controller", mutate("NapCatApp.swift") { $0 + "\nlet x = FinishAlertController(" }),
            ("menu builds a watcher", mutate("MenuContentView.swift") { $0 + "\nlet w = KqueueMarkerDirectoryWatcher(" }),
            ("second watcher site", mutate(Self.controllerFile) { $0 + "\nlet w = KqueueMarkerDirectoryWatcher(" }),
            ("second scheduler site", mutate("NapCatApp.swift") { $0 + "\nlet s = MainQueueFinishAlertScheduler(" }),
            ("factory call removed", mutate("NapCatApp.swift") {
                $0.replacingOccurrences(of: "FinishAlertController.makeIfEnabled(", with: "makeFinishAlert(")
            }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.constructionFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// B1 AMENDMENT FENCE: the amendment allows ONE kqueue source + a one-shot
    /// debounce for the ARMED finish alert — it does not repeal "B1 samples on
    /// menu open only". The detection controller stays timer- and source-free.
    static func b1FenceFailures(_ activityController: String) -> [String] {
        let code = LidGuardStructureTests.codeOnly(activityController)
        return ["DispatchSource", "Timer", "asyncAfter", "makeFileSystemObjectSource", "MarkerDirectoryWatching",
                "FinishAlert"]
            .filter { code.contains($0) }
            .map { "'\($0)' in ClaudeActivityController.swift — B1 sampling stays menu-open only" }
    }

    @Test func theB1AmendmentFenceHolds() throws {
        let source = try Self.shipped("ClaudeActivityController.swift")
        #expect(source.contains("func sample()"), "vacuity: the B1 controller must be the real one")
        #expect(Self.b1FenceFailures(source).isEmpty, "\(Self.b1FenceFailures(source))")
        let anchor = "func sample() {"
        for injected in ["let t = Timer.scheduledTimer", "let s = DispatchSource.makeTimerSource()",
                         "DispatchQueue.main.asyncAfter(deadline: .now()) {}"] {
            let mutant = source.replacingOccurrences(of: anchor, with: anchor + "\n        " + injected)
            #expect(mutant != source)
            #expect(!Self.b1FenceFailures(mutant).isEmpty, "canary '\(injected)' was NOT caught")
        }
    }

    /// The wiring points the contract names: launch, every menu open, every
    /// lid-guard arming refresh (hook), the pause toggle, and quit.
    @Test func theFinishAlertIsReconciledAtEveryWiringPoint() throws {
        let app = LidGuardStructureTests.codeOnly(try Self.shipped("NapCatApp.swift"))
        #expect(app.contains("lidGuard?.setArmingRefreshHook"))
        #expect(app.contains("finishAlert?.reconcile()"))
        #expect(app.contains("finishAlert?.disarmForShutdown()"))
        #expect(app.contains("finishAlert: finishAlert"), "the menu receives the controller")

        let menu = LidGuardStructureTests.codeOnly(try Self.shipped("MenuContentView.swift"))
        let open = try #require(menu.range(of: "func menuWillOpen("))
        let tail = menu[open.upperBound...]
        let end = tail.range(of: "\n    private func ")?.lowerBound ?? tail.endIndex
        let body = tail[..<end]
        let refresh = try #require(body.range(of: "lidGuard?.refreshArming()"))
        let reconcile = try #require(body.range(of: "finishAlert?.reconcile()"), "menu open must reconcile")
        #expect(refresh.lowerBound < reconcile.lowerBound)
        #expect(menu.contains("model.onDetectionPausedChange = { [weak self] in self?.finishAlert?.reconcile() }"))
        #expect(menu.contains("finishAlert?.setChangeHandler"))

        let model = LidGuardStructureTests.codeOnly(try Self.shipped("MenuStateModel.swift"))
        let pause = try #require(model.range(of: "func setDetectionPaused("))
        let pauseBody = model[pause.upperBound...].prefix(200)
        #expect(pauseBody.contains("onDetectionPausedChange?()"), "the pause toggle must notify the owner")
    }
}
