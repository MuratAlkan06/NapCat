// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Structural isolation for Track B slice B2 (mirrors
/// ClaudeDetectionStructureTests and the DebugPowerSimulator lint): network I/O
/// and the IOKit power registration each live in exactly ONE file; the whole
/// subsystem is absent from the debug-simulator object graph; the sender API
/// cannot carry free text; the ntfy topic (which IS the password) can never
/// reach a log line; and the feature adds no privileged surface.
///
/// Since B4 the subsystem also asserts what is GONE: no osascript, no
/// AppleEvents, no bundled AppleScript, no Automation (TCC) surface at all.
struct LidGuardStructureTests {
    // MARK: Helpers

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // Tests/NapCatTests/<this file>
            .deletingLastPathComponent()     // Tests/NapCatTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    static func sourcesDir() -> URL { repoRoot().appendingPathComponent("Sources/NapCat") }

    /// Strips `//` line comments so the scan matches executable code only —
    /// doc comments legitimately NAME these symbols to document the boundary.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    static func swiftSources() throws -> [(name: String, text: String)] {
        let dir = sourcesDir()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, codeOnly(try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))) }
    }

    /// The files that make up the B2 subsystem.
    static let b2Files = [
        "LidGuardPolicy.swift",
        "LidGuardController.swift",
        "MessageSender.swift",
        "NtfyMessageSender.swift",
        "SystemSleepSource.swift",
    ]

    /// Files scanned by the no-topic-in-logs lint: the B2 subsystem PLUS the
    /// three menu files, which see the topic (the model mirrors it so the editor
    /// can be prefilled, and the editor renders it). They contain zero `logger.`
    /// calls today; including them turns that fact into a lock, so the first log
    /// line added there has to obey the same rules (security review 2026-09-09).
    ///
    /// Deliberately NOT folded into `b2Files`: the privileged-surface lint would
    /// then trip over MenuContentView's legitimate "sudo ./scripts/setup.sh"
    /// instruction text.
    static let logScannedFiles = b2Files + [
        "MenuStateModel.swift",
        "MenuPanelView.swift",
        "MenuPanelVariants.swift",
        "MenuContentView.swift",
    ]

    /// Every menu source file (2026-10-18 redesign split the view into two
    /// files — a new panel file must be added here).
    static let menuFiles = ["MenuStateModel.swift", "MenuPanelView.swift", "MenuPanelVariants.swift",
                            "MenuContentView.swift"]

    /// What counts as "a line that emits output", matched case-INSENSITIVELY
    /// (so `osLogger.`/`alertLogger.` cannot slip past). `Logger` is the only
    /// one this codebase uses; the other three are here so that reaching for a
    /// cruder tool — which has no `privacy:` annotation at all, and on
    /// `print`/`NSLog` no redaction whatsoever — cannot become a way around the
    /// no-topic-in-logs rule (I-4, review closure pass 2026-09-09). The scanned
    /// files contain none of them today.
    static let logCallTokens = ["logger.", "print(", "nslog", "os_log"]

    // MARK: - Log-call extraction (H1 — shared with FinishAlertStructureTests)

    /// Log-emitting METHODS — every `os.Logger` level — matched as `.name(`
    /// (case-insensitive, spaces/tabs allowed before the paren) on ANY
    /// receiver, so an aliased or renamed logger is still found.
    static let logMethodNames = ["notice", "error", "fault", "log", "debug", "info", "warning", "critical", "trace"]

    /// Log-emitting free FUNCTIONS (no `privacy:` support at all), matched as
    /// `name(` the same way.
    static let logFunctionNames = ["print", "nslog", "os_log"]

    /// One extracted log call: the 1-based line it starts on, and its text
    /// from the opener (`.notice(`, `print(` …) through the balanced closing
    /// parenthesis — ACROSS lines — or to end of input when it never closes.
    struct LogCall {
        let line: Int
        let text: String
        let closed: Bool
        var isSingleLine: Bool { closed && !text.contains("\n") }
    }

    /// Every log call in comment-stripped `code`. Over-inclusive by design
    /// (an enum pattern like `case .error(let m)` is extracted too and simply
    /// passes the content rules); it must never MISS a call.
    static func logCalls(in code: String) -> [LogCall] {
        let chars = Array(code)
        let lower = chars.map { $0.isASCII ? Character($0.lowercased()) : $0 }
        let methods = logMethodNames.map { Array($0) }
        let functions = logFunctionNames.map { Array($0) }
        func word(_ pattern: [Character], at index: Int) -> Bool {
            guard index + pattern.count <= lower.count else { return false }
            for k in pattern.indices where lower[index + k] != pattern[k] { return false }
            return true
        }
        func paren(after index: Int) -> Int? {
            var i = index
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            return i < chars.count && chars[i] == "(" ? i : nil
        }
        var calls: [LogCall] = []
        var line = 1
        for start in chars.indices {
            if chars[start] == "\n" {
                line += 1
                continue
            }
            let open: Int? = chars[start] == "."
                ? methods.lazy.compactMap { word($0, at: start + 1) ? paren(after: start + 1 + $0.count) : nil }.first
                : functions.lazy.compactMap { word($0, at: start) ? paren(after: start + $0.count) : nil }.first
            guard let open else { continue }
            let end = callEnd(chars, open: open)
            calls.append(LogCall(line: line, text: String(chars[start...(end ?? chars.count - 1)]), closed: end != nil))
        }
        return calls
    }

    /// Index of the `)` closing the call whose `(` is at `open`, or nil. Code
    /// parentheses are balanced; string literals (`"…"`, `"""…"""`) are
    /// skipped, so a `(` or `)` inside a message cannot end the call early or
    /// late — but each `\( … )` interpolation inside one is code again.
    static func callEnd(_ chars: [Character], open: Int) -> Int? {
        enum Mode { case code(depth: Int), string(multiline: Bool) }
        func tripleQuote(at i: Int) -> Bool {
            i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
        }
        var stack: [Mode] = [.code(depth: 0)]
        var i = open
        while i < chars.count, let mode = stack.last {
            switch mode {
            case .code(let depth):
                if chars[i] == "(" {
                    stack[stack.count - 1] = .code(depth: depth + 1)
                } else if chars[i] == ")" {
                    if depth > 1 {
                        stack[stack.count - 1] = .code(depth: depth - 1)
                    } else if stack.count == 1 {
                        return i                                   // the call's own `)`
                    } else {
                        stack.removeLast()                         // an interpolation ends
                    }
                } else if chars[i] == "\"" {
                    let triple = tripleQuote(at: i)
                    stack.append(.string(multiline: triple))
                    if triple { i += 2 }
                }
            case .string(let multiline):
                if chars[i] == "\\" {
                    if i + 1 < chars.count, chars[i + 1] == "(" { stack.append(.code(depth: 1)) }
                    i += 1                                         // the escaped char / the `(`
                } else if multiline ? tripleQuote(at: i) : chars[i] == "\"" {
                    stack.removeLast()
                    if multiline { i += 2 }
                }
            }
            i += 1
        }
        return nil
    }

    /// The ONE logger declaration a scanned file may carry.
    static let loggerDeclarationPattern =
        #"^[ \t]*private static let logger = Logger\(subsystem: "com\.muratalkan\.napcat", category: "[a-z]+"\)[ \t]*$"#

    /// H1 shape rules, shared by both log lints (comment-stripped `code`):
    ///  1. every log call starts AND ends on one physical line;
    ///  2. at most one logger declaration, exactly `loggerDeclarationPattern`;
    ///  3. outside it, `Logger` never appears, and `logger` (any identifier
    ///     containing it, any case) appears ONLY as the receiver of a log call
    ///     (`logger.notice(` …): no alias (`let l = Self.logger`), no escape
    ///     (`f(Self.logger)`), no second logger.
    static func logShapeFailures(_ code: String, file: String) -> [String] {
        var failures: [String] = []
        for call in logCalls(in: code) where !call.isSingleLine {
            let head = call.text.prefix { $0 != "\n" }
            failures.append(call.closed
                ? "\(file):\(call.line): log call spans lines — every log call must start and end on one physical line: \(head)"
                : "\(file):\(call.line): log call never closes: \(head)")
        }
        var declarations = 0
        for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if text.range(of: loggerDeclarationPattern, options: .regularExpression) != nil {
                declarations += 1
                continue
            }
            var cursor = text.startIndex
            while let range = text.range(of: "[A-Za-z_][A-Za-z0-9_]*", options: .regularExpression,
                                         range: cursor..<text.endIndex) {
                cursor = range.upperBound
                let identifier = String(text[range])
                guard identifier.lowercased().contains("logger") else { continue }
                let tail = text[range.upperBound...]
                let isReceiver = identifier == "logger" && logMethodNames.contains { name in
                    tail.hasPrefix("." + name)
                        && tail.dropFirst(name.count + 1).drop(while: { $0 == " " || $0 == "\t" }).first == "("
                }
                if !isReceiver {
                    failures.append("\(file):\(offset + 1): '\(identifier)' outside the single logger declaration "
                        + "and not a log-call receiver (logger alias / escape): \(text)")
                }
            }
        }
        if declarations > 1 {
            failures.append("\(file): \(declarations) logger declarations — at most one per file")
        }
        return failures
    }

    /// What the content rules scan: every line holding a `logCallTokens`
    /// token (the pre-H1 unit) PLUS the full text of every extracted log call
    /// — so a secret or an unannotated interpolation on a continuation line is
    /// seen as well.
    static func logScanUnits(_ code: String) -> [String] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { line in logCallTokens.contains { line.lowercased().contains($0) } }
            + logCalls(in: code).map(\.text)
    }

    // MARK: - Symbol confinement

    /// Each externally-visible capability may appear in ONE file only, repo
    /// wide. Vacuity is guarded: the token must really be present there.
    /// `session(for:` (security review L4): the sender's internal per-lane
    /// accessor hands out a live URLSession, so no other Sources file may call
    /// it — that would reach `downloadTask` / `data(from:)` without ever naming
    /// `URLSession`. (Tests are not scanned; they may invalidate the sessions.)
    @Test func externalCapabilitiesAreConfinedToOneFileEach() throws {
        let allowed: [String: String] = [
            "URLSession": "NtfyMessageSender.swift",
            "URLRequest": "NtfyMessageSender.swift",
            "dataTask": "NtfyMessageSender.swift",
            "httpBody": "NtfyMessageSender.swift",
            "setValue": "NtfyMessageSender.swift",
            "session(for:": "NtfyMessageSender.swift",
            "IORegisterForSystemPower": "SystemSleepSource.swift",
            "IODeregisterForSystemPower": "SystemSleepSource.swift",
            "IOAllowPowerChange": "SystemSleepSource.swift",
            "IONotificationPortSetDispatchQueue": "SystemSleepSource.swift",
        ]
        let sources = try Self.swiftSources()
        for (token, owner) in allowed {
            for (name, text) in sources where text.contains(token) {
                #expect(name == owner, "'\(token)' leaked into \(name) — it must stay in \(owner)")
            }
            let present = sources.contains { $0.name == owner && $0.text.contains(token) }
            #expect(present, "'\(token)' not found in \(owner) — this lint would be vacuous")
        }
    }

    /// The B2 subsystem spawns NOTHING. Before B4 the osascript sender was the
    /// one permitted spawner; the ntfy channel needs no subprocess at all, so
    /// the exception is gone and the rule covers every file.
    @Test func theSubsystemNeverSpawnsAProcess() throws {
        let sources = try Self.swiftSources()
        let spawnTokens = ["Process(", "posix_spawn", "NSTask", "system(", "popen", "osascript"]
        for (name, text) in sources where Self.b2Files.contains(name) {
            for token in spawnTokens {
                #expect(!text.contains(token), "'\(token)' in \(name) — B2 must never spawn a process")
            }
        }
    }

    /// B2 adds ZERO privileged surface: no sudo, no pmset, no smc, no PLAN §4
    /// command anywhere in the subsystem.
    @Test func theSubsystemHasNoPrivilegedSurface() throws {
        let sources = try Self.swiftSources()
        let forbidden = ["sudo", "pmset", "PrivilegedCommand", "/usr/local/napcat", "disablesleep"]
        for (name, text) in sources where Self.b2Files.contains(name) {
            for token in forbidden {
                #expect(!text.contains(token), "'\(token)' in \(name) — B2 must stay unprivileged")
            }
        }
    }

    /// Every B2 type is constructed through the gated factories in
    /// LidGuardController.swift. Since Track C the ntfy sender is SHARED: it
    /// is built exactly once, by `makeSharedSender` (same debug-sim gate), and
    /// injected — `makeIfEnabled` no longer constructs one privately.
    @Test func theSubsystemHasASingleConstructionSite() throws {
        let sources = try Self.swiftSources()
        let constructors = [
            "LidGuardController(",
            "IOKitSystemSleepSource(",
            "NtfyMessageSender(",
        ]
        for token in constructors {
            for (name, text) in sources where text.contains(token) {
                #expect(name == "LidGuardController.swift",
                        "'\(token)' in \(name) — construction must go through LidGuardController.makeIfEnabled / makeSharedSender")
            }
        }
        // ONE sender construction site, inside the gated shared factory.
        let controller = try #require(sources.first { $0.name == "LidGuardController.swift" })
        #expect(controller.text.components(separatedBy: "NtfyMessageSender(").count - 1 == 1,
                "the ntfy sender must be constructed exactly once (makeSharedSender) and injected")
        // NapCatApp must reach the feature only through the gated factories.
        let app = try #require(sources.first { $0.name == "NapCatApp.swift" })
        #expect(app.text.contains("LidGuardController.makeIfEnabled("))
        #expect(!app.text.contains("LidGuardController("))
        #expect(app.text.contains("LidGuardController.makeSharedSender("))
        #expect(!app.text.contains("NtfyMessageSender("), "the app injects the shared sender — it never builds one")
    }

    /// A `NtfyDestination` is the ONLY thing that ever becomes a URL, so it
    /// must only ever be built by the validator. Any other source file
    /// assembling one by hand would bypass the ntfy grammar check.
    @Test func onlyThePolicyMayConstructADestination() throws {
        let sources = try Self.swiftSources()
        for (name, text) in sources where text.contains("NtfyDestination(") {
            #expect(name == "LidGuardPolicy.swift",
                    "'NtfyDestination(' in \(name) — build it through LidGuardPolicy.destination(server:topic:)")
        }
        let policy = try #require(sources.first { $0.name == "LidGuardPolicy.swift" })
        #expect(policy.text.contains("NtfyDestination("), "lint would be vacuous")
    }

    // MARK: - Debug-simulator absence

    @Test @MainActor func theSubsystemIsAbsentInDebugSimulatorMode() {
        #expect(!LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: true))
        #expect(LidGuardPolicy.lidGuardMayBeConstructed(debugBattery: false))

        let suite = "com.muratalkan.napcat.tests.lidguard.structure"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // No sender — hence no URLSession, no network — in debugBattery mode.
        #expect(LidGuardController.makeSharedSender(debugBattery: true) == nil,
                "debugBattery mode must not construct the ntfy sender")

        let detection = ClaudeActivityController.makeIfEnabled(debugBattery: false)
        // The predicate is checked FIRST: even an injected sender cannot
        // bring the lid guard into debugBattery mode.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: true,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: RecordingMessageSender()
        ) == nil, "debugBattery mode must not construct the lid guard")
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: true,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: LidGuardController.makeSharedSender(debugBattery: true)
        ) == nil)

        // Without the B1 detection stack there is nothing to notify about.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: false,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: nil,
            sender: RecordingMessageSender()
        ) == nil)

        // Without a sender there is nothing to deliver with.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: false,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection,
            sender: nil
        ) == nil)

        // Outside debugBattery mode the shared sender IS built (two idle
        // URLSessions — no task is created, nothing touches the network).
        let shared = LidGuardController.makeSharedSender(debugBattery: false)
        #expect(shared != nil)
        if let shared {
            for lane in NtfySendLane.allCases { shared.session(for: lane).invalidateAndCancel() }
        }
    }

    /// The panel and model stay free of every low-level symbol (extends the B1
    /// rule to the B2 tokens).
    @Test func menuFilesStayFreeOfTheB2Capabilities() throws {
        let dir = Self.sourcesDir()
        for file in Self.menuFiles {
            let text = Self.codeOnly(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            for token in ["URLSession", "URLRequest", "dataTask", "osascript",
                          "IORegisterForSystemPower", "IOAllowPowerChange"] {
                #expect(!text.contains(token), "'\(token)' must not appear in \(file)")
            }
        }
    }

    // MARK: - The topic is a password

    /// The ntfy topic is the ONLY access control on the feed and it rides
    /// inside the request URL. So no B2 output — `Logger`, `print`, `NSLog`
    /// or `os_log` — may name a topic or a URL, and every interpolation in it
    /// must carry an explicit `privacy:` annotation.
    ///
    /// Scanned units (H1): every line holding a `logCallTokens` token, AND the
    /// whole text of every log call (`logCalls`, extracted across lines on any
    /// receiver) — plus the shared shape rules: one physical line per call,
    /// one logger declaration, no logger alias. Case-INSENSITIVE throughout: a
    /// differently-named logger (`osLogger`, `alertLogger`, …) must not slip
    /// past (canary-caught in the 2026-09-09 security review).
    static func logLintFailures(_ code: String, file: String) -> [String] {
        var failures = logShapeFailures(code, file: file)
        for unit in logScanUnits(code) {
            for secret in ["topic", "Topic", "absoluteString", ".url", "request.url", "endpoint"]
            where unit.contains(secret) {
                failures.append("\(file): a log call must never carry '\(secret)' — the ntfy topic is a password: \(unit)")
            }
            let interpolations = unit.components(separatedBy: "\\(").count - 1
            let annotations = unit.components(separatedBy: "privacy:").count - 1
            if interpolations != annotations {
                failures.append("\(file): every interpolation in a log call needs an explicit privacy level: \(unit)")
            }
        }
        return failures
    }

    @Test func noLidGuardLogLineCanEchoTheTopicOrTheUrl() throws {
        let sources = try Self.swiftSources()
        var scanned = 0
        for (name, text) in sources where Self.logScannedFiles.contains(name) {
            scanned += Self.logCalls(in: text).count
            let failures = Self.logLintFailures(text, file: name)
            #expect(failures.isEmpty, "\(failures)")
        }
        #expect(scanned >= 10, "only \(scanned) log calls scanned — this lint would be (nearly) vacuous")
        // Every scanned file must really exist under that name, or a rename
        // would silently drop it out of the lint.
        for name in Self.logScannedFiles {
            #expect(sources.contains { $0.name == name },
                    "\(name) is not in Sources/NapCat — update the lint's file list")
        }
    }

    /// H1 canaries, injected into EVERY scanned file: a call split across
    /// lines with the topic on the continuation line, an aliased / escaped /
    /// second logger, and an unannotated interpolation hidden on a
    /// continuation line (a line-based scan sees none of them) must each be
    /// caught BY THE RULE THAT TARGETS IT; a clean one-line call must pass.
    @Test func lidGuardLogLintCatchesMutants() throws {
        let sources = try Self.swiftSources()
        let split = "func canary() {\n    Self.logger.notice(\n        \"lid guard: \\(destination.topic, privacy: .private)\")\n}"
        let hidden = "func canary() {\n    Self.logger.notice(\"\"\"\n        lid guard: \\(reason.rawValue)\n        \"\"\")\n}"
        let mutants: [(name: String, code: String, expected: [String])] = [
            ("multi-line split", split, ["spans lines", "'topic'"]),
            ("aliased logger", "func canary() { let l = Self.logger; l.notice(\"lid guard\") }", ["logger alias"]),
            ("aliased bare logger", "func canary() { let l = logger; l.notice(\"lid guard\") }", ["logger alias"]),
            ("escaped logger", "func canary() { relay(Self.logger) }", ["logger alias"]),
            ("second logger", "let other = Logger(subsystem: \"x\", category: \"y\")", ["logger alias"]),
            ("renamed logger", "func canary() { osLogger.notice(\"lid guard\") }", ["logger alias"]),
            ("hidden interpolation", hidden, ["explicit privacy level", "spans lines"]),
            ("never closes", "func canary() { Self.logger.notice(\"lid guard\"", ["never closes"]),
        ]
        var checked = 0
        for (file, text) in sources where Self.logScannedFiles.contains(file) {
            try #require(Self.logLintFailures(text, file: file).isEmpty, "canary baseline must be clean")
            for (name, code, expected) in mutants {
                let failures = Self.logLintFailures(text + "\n" + code + "\n", file: file)
                for marker in expected {
                    #expect(failures.contains { $0.contains(marker) },
                            "canary '\(name)' in \(file) was NOT caught by the '\(marker)' rule: \(failures)")
                }
            }
            let clean = "func canary() { Self.logger.notice(\"lid guard: \\(count, privacy: .public)\") }"
            #expect(Self.logLintFailures(text + "\n" + clean + "\n", file: file).isEmpty,
                    "a clean one-line call must not trip the lint in \(file)")
            checked += 1
        }
        #expect(checked == Self.logScannedFiles.count)
    }

    /// The extractor itself: string-aware balancing (a `(`/`)` inside a
    /// message neither ends nor extends the call), interpolations scanned as
    /// code, any receiver, spaces before the paren, and no false openers.
    @Test func logCallExtractionIsStringAwareAndReceiverAgnostic() {
        let code = """
            Self.logger.notice("disarmed (\\(r, privacy: .public)), x")
            l.error("a) \\(b)")
            print ("p")
            let x = foo.information(1) + bar.logger
            NSLog("n")
            Self.logger.notice(
                "two")
            Self.logger.fault("x"
            """
        let calls = Self.logCalls(in: code)
        #expect(calls.map(\.text) == [
            ".notice(\"disarmed (\\(r, privacy: .public)), x\")",
            ".error(\"a) \\(b)\")",
            "print (\"p\")",
            "NSLog(\"n\")",
            ".notice(\n    \"two\")",
            ".fault(\"x\"",
        ])
        #expect(calls.map(\.line) == [1, 2, 3, 5, 6, 8])
        #expect(calls.map(\.isSingleLine) == [true, true, true, true, false, false])
        #expect(calls.map(\.closed) == [true, true, true, true, true, false])
    }

    /// F1 (2026-10-18): the fire-gate SKIP line used to be `.debug`, which
    /// macOS does not persist — `log show` could not see the skip reason, and a
    /// one-click "Pause detection" (every sleep skipped `noTaskInFlight`) stayed
    /// invisible for five weeks across two hardware drills. It must be logged at
    /// a PERSISTED level, keep its one public reason field, and no B2 line may
    /// drop back to a level macOS discards (`.debug`/`.trace`, or `.info`, which
    /// is memory-only by default).
    @Test func fireGateSkipReasonIsLoggedAtAPersistedLevel() throws {
        let sources = try Self.swiftSources()
        let controller = try #require(sources.first { $0.name == "LidGuardController.swift" })
        let skipLines = controller.text.split(separator: "\n").filter { $0.contains("sleeping, no alert") }
        #expect(skipLines.count == 1, "expected exactly one skip line, found \(skipLines.count)")
        let line = try #require(skipLines.first)
        #expect(line.contains("logger.notice("), "the skip reason must be persisted: \(line)")
        #expect(line.contains("\\(reason.rawValue, privacy: .public)"), "the reason field must stay public")
        #expect(line.components(separatedBy: "\\(").count - 1 == 1, "no new interpolations on the skip line")

        for (name, text) in sources where Self.b2Files.contains(name) {
            for level in ["logger.debug(", "logger.trace(", "logger.info("] {
                #expect(!text.contains(level), "\(name): '\(level)' is not persisted by macOS — use .notice or higher")
            }
        }
    }

    /// The failure detail that reaches the menu and the (private) log comes
    /// from a fixed vocabulary, never from an error's own message — those can
    /// embed the failing URL.
    @Test func senderFailureDetailsNeverComeFromAnErrorDescription() throws {
        let sources = try Self.swiftSources()
        for (name, text) in sources where Self.b2Files.contains(name) {
            #expect(!text.contains("localizedDescription"),
                    "\(name): localizedDescription can carry the failing URL, which carries the topic")
        }
    }

    // MARK: - Sender API surface (body is app-generated, enforced by shape)

    /// The one send entry point takes NO free-text parameter — byte-locked, so
    /// adding a `body:`/`text:` String would fail here. Since B4 it carries no
    /// String at all: the destination is a pre-validated struct.
    @Test func theSenderApiCannotCarryFreeText() throws {
        let source = try String(
            contentsOf: Self.sourcesDir().appendingPathComponent("MessageSender.swift"),
            encoding: .utf8
        )
        let expected = [
            "    func send(",
            "        _ kind: LidGuardMessageKind,",
            "        to destination: NtfyDestination,",
            "        at firedAt: Date,",
            "        completion: @escaping @Sendable (MessageSendOutcome) -> Void",
            "    )",
        ].joined(separator: "\n")
        #expect(source.contains(expected), "the MessageSender signature changed — re-review the free-text guarantee")

        // Within the protocol declaration there is now NO String parameter.
        let start = try #require(source.range(of: "protocol MessageSender"))
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "\n}"))
        let declaration = String(body[..<end.lowerBound])
        let stringParameters = declaration.components(separatedBy: ": String").count - 1
        #expect(stringParameters == 0, "expected no String parameter at all, found \(stringParameters)")
        for forbidden in ["body:", "text:", "message:", "subject:"] {
            #expect(!declaration.contains(forbidden), "'\(forbidden)' would let caller text reach a message")
        }
    }

    /// The dry-run sender proves the produced body really is the template —
    /// for all four closed kinds.
    @Test func theDryRunSenderProducesOnlyTemplateBodies() {
        let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-structure")
        let sender = RecordingMessageSender()
        let kinds: [LidGuardMessageKind] = [
            .lidAlert(busySessionCount: 2),
            .test,
            .sessionFinished(minutes: 42, folded: 1, stillWorking: 1),
            .needsAttention(minutes: 12, stillWorking: 0),
        ]
        for kind in kinds {
            sender.send(kind, to: destination, at: Date(timeIntervalSince1970: 0)) { _ in }
        }
        let bodies = sender.bodies(clockTime: "22:49")
        #expect(bodies.count == kinds.count)
        for (body, kind) in zip(bodies, kinds) {
            #expect(body == LidGuardPolicy.messageBody(kind: kind, clockTime: "22:49"))
        }
        #expect(bodies[2] == "A Claude session finished after 42 min — 1 still working")
        #expect(bodies[3] == "Claude is waiting for your approval — 12 min in")
    }

    // MARK: - What B4 removed (regression locks)

    /// The iMessage channel is gone repo-wide: no sender, no probe, no bundled
    /// AppleScript, no Makefile rule, and no source naming Messages automation.
    @Test func theIMessageChannelIsFullyRemoved() throws {
        let fileManager = FileManager.default
        for removed in [
            "Sources/NapCat/OSAScriptMessageSender.swift",
            "Sources/NapCat/AutomationPermissionProbe.swift",
            "Resources/napcat-send-imessage.applescript",
        ] {
            #expect(!fileManager.fileExists(atPath: Self.repoRoot().appendingPathComponent(removed).path),
                    "\(removed) must be gone after the ntfy swap")
        }

        let sources = try Self.swiftSources()
        for (name, text) in sources {
            for token in ["osascript", "AEDeterminePermissionToAutomateTarget",
                          "com.apple.MobileSMS", "AECreateDesc", "AutomationPermission"] {
                #expect(!text.contains(token), "'\(token)' still in \(name) — the iMessage channel is retired")
            }
        }

        let makefile = try String(contentsOf: Self.repoRoot().appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(!makefile.contains("applescript"), "the Makefile must no longer bundle an AppleScript")
        #expect(makefile.contains("napcat-watchdog.sh"), "lint would be vacuous if resource copying vanished")
    }

    /// NapCat now drives no other application, so it must request no
    /// Automation (TCC) permission — an unused purpose string would be a
    /// standing, unexplained privacy prompt waiting to happen.
    @Test func infoPlistDeclaresNoAppleEventsUsage() throws {
        let plist = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Resources/Info.plist"),
            encoding: .utf8
        )
        #expect(!plist.contains("<key>NSAppleEventsUsageDescription</key>"))
        #expect(plist.contains("LSUIElement"), "lint would be vacuous if the plist were empty")
    }
}

/// The IOKit power-message table, verified without registering anything: the
/// four message numbers are derived from `iokit_common_msg` and mapped to the
/// events the controller acts on.
struct SystemSleepMessageTests {
    @Test func messageNumbersMatchIOMessageHeaderValues() {
        #expect(IOKitSystemSleepSource.canSystemSleepMessage == 0xE000_0270)
        #expect(IOKitSystemSleepSource.systemWillSleepMessage == 0xE000_0280)
        #expect(IOKitSystemSleepSource.systemWillNotSleepMessage == 0xE000_0290)
        #expect(IOKitSystemSleepSource.systemHasPoweredOnMessage == 0xE000_0300)
        #expect(IOKitSystemSleepSource.systemWillPowerOnMessage == 0xE000_0320)
    }

    @Test func theMessageTableMapsEveryHandledNotification() {
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.canSystemSleepMessage) == .canSystemSleep)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillSleepMessage) == .systemWillSleep)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillPowerOnMessage) == .systemWillPowerOn)
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemHasPoweredOnMessage) == .systemHasPoweredOn)
        // Needs no reply — ignoring it cannot delay a sleep.
        #expect(IOKitSystemSleepSource.event(forMessageType: IOKitSystemSleepSource.systemWillNotSleepMessage) == nil)
        #expect(IOKitSystemSleepSource.event(forMessageType: 0) == nil)
    }

    /// A fresh source registers nothing until it is started.
    @Test func aFreshIOKitSourceIsNotRunning() {
        #expect(!IOKitSystemSleepSource().isRunning)
    }

    /// If `stop()` races a callback that IOKit already queued, there is no
    /// handler left to answer it — the source must acknowledge anyway, or
    /// macOS waits out its ~30 s timeout before that sleep.
    ///
    /// The source is deliberately never `start`ed here: registering the test
    /// process for real system power notifications would put a do-nothing
    /// handler on this machine's sleep path.
    @Test func aQueuedNotificationIsAcknowledgedEvenWithNoHandlerInstalled() {
        let source = IOKitSystemSleepSource()
        #expect(!source.isRunning)
        for event in [SystemSleepEvent.canSystemSleep, .systemWillSleep,
                      .systemWillPowerOn, .systemHasPoweredOn] {
            let recorder = AckRecorder()
            source.dispatch(event: event, ack: recorder.ack)
            #expect(recorder.performedCount == 1, "\(event) must never be left unanswered")
        }
    }

    @Test func theAckTokenIsIdempotent() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let counter = Counter()
        let ack = SystemSleepAck { counter.bump() }
        #expect(!ack.didAllow)
        ack.allow()
        ack.allow()
        ack.allow()
        #expect(counter.count == 1, "IOAllowPowerChange must run exactly once per notification")
        #expect(ack.allowCallCount == 3)
        #expect(ack.didAllow)
        // The wake ack does nothing at all.
        SystemSleepAck.noOp().allow()
    }
}
