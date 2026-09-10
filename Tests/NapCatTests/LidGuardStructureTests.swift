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
        "MenuContentView.swift",
    ]

    /// What counts as "a line that emits output", matched case-INSENSITIVELY
    /// (so `osLogger.`/`alertLogger.` cannot slip past). `Logger` is the only
    /// one this codebase uses; the other three are here so that reaching for a
    /// cruder tool — which has no `privacy:` annotation at all, and on
    /// `print`/`NSLog` no redaction whatsoever — cannot become a way around the
    /// no-topic-in-logs rule (I-4, review closure pass 2026-09-09). The scanned
    /// files contain none of them today.
    static let logCallTokens = ["logger.", "print(", "nslog", "os_log"]

    // MARK: - Symbol confinement

    /// Each externally-visible capability may appear in ONE file only, repo
    /// wide. Vacuity is guarded: the token must really be present there.
    @Test func externalCapabilitiesAreConfinedToOneFileEach() throws {
        let allowed: [String: String] = [
            "URLSession": "NtfyMessageSender.swift",
            "URLRequest": "NtfyMessageSender.swift",
            "dataTask": "NtfyMessageSender.swift",
            "httpBody": "NtfyMessageSender.swift",
            "setValue": "NtfyMessageSender.swift",
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

    /// Every B2 type is constructed through the one gated factory.
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
                        "'\(token)' in \(name) — construction must go through LidGuardController.makeIfEnabled")
            }
        }
        // NapCatApp must reach the feature only through the gated factory.
        let app = try #require(sources.first { $0.name == "NapCatApp.swift" })
        #expect(app.text.contains("LidGuardController.makeIfEnabled("))
        #expect(!app.text.contains("LidGuardController("))
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
        let detection = ClaudeActivityController.makeIfEnabled(debugBattery: false)
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: true,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: detection
        ) == nil, "debugBattery mode must not construct the lid guard")

        // Without the B1 detection stack there is nothing to notify about.
        #expect(LidGuardController.makeIfEnabled(
            debugBattery: false,
            defaults: defaults,
            stayAwakeMirror: ObservedStayAwakeMirror(),
            detection: nil
        ) == nil)
    }

    /// The panel and model stay free of every low-level symbol (extends the B1
    /// rule to the B2 tokens).
    @Test func menuFilesStayFreeOfTheB2Capabilities() throws {
        let dir = Self.sourcesDir()
        for file in ["MenuStateModel.swift", "MenuPanelView.swift", "MenuContentView.swift"] {
            let text = Self.codeOnly(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            for token in ["URLSession", "URLRequest", "dataTask", "osascript",
                          "IORegisterForSystemPower", "IOAllowPowerChange"] {
                #expect(!text.contains(token), "'\(token)' must not appear in \(file)")
            }
        }
    }

    // MARK: - The topic is a password

    /// The ntfy topic is the ONLY access control on the feed and it rides
    /// inside the request URL. So no B2 output line — `Logger`, `print`,
    /// `NSLog` or `os_log`, see `logCallTokens` — may name a topic or a URL, and
    /// every interpolation in one must carry an explicit `privacy:` annotation
    /// (all B2 log statements are single-line by construction).
    @Test func noLidGuardLogLineCanEchoTheTopicOrTheUrl() throws {
        let sources = try Self.swiftSources()
        var scanned = 0
        for (name, text) in sources where Self.logScannedFiles.contains(name) {
            // Case-INSENSITIVE: a differently-named logger (`osLogger`,
            // `alertLogger`, …) must not slip past the scan. Caught by a canary
            // during the 2026-09-09 security review, when an injected
            // `canaryLogger.notice("…topic…")` was not matched.
            for line in text.split(separator: "\n", omittingEmptySubsequences: false)
            where Self.logCallTokens.contains(where: { line.lowercased().contains($0) }) {
                scanned += 1
                for secret in ["topic", "Topic", "absoluteString", ".url", "request.url", "endpoint"] {
                    #expect(!line.contains(secret),
                            "\(name): a log line must never carry '\(secret)' — the ntfy topic is a password")
                }
                let interpolations = line.components(separatedBy: "\\(").count - 1
                let annotations = line.components(separatedBy: "privacy:").count - 1
                #expect(interpolations == annotations,
                        "\(name): every interpolation in a log line needs an explicit privacy level: \(line)")
            }
        }
        #expect(scanned > 0, "no log lines scanned — this lint would be vacuous")
        // Every scanned file must really exist under that name, or a rename
        // would silently drop it out of the lint.
        for name in Self.logScannedFiles {
            #expect(sources.contains { $0.name == name },
                    "\(name) is not in Sources/NapCat — update the lint's file list")
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

    /// The dry-run sender proves the produced body really is the template.
    @Test func theDryRunSenderProducesOnlyTemplateBodies() {
        let destination = NtfyDestination(server: "https://ntfy.sh", topic: "napcat-structure")
        let sender = RecordingMessageSender()
        sender.send(.lidAlert(busySessionCount: 2), to: destination, at: Date(timeIntervalSince1970: 0)) { _ in }
        sender.send(.test, to: destination, at: Date(timeIntervalSince1970: 0)) { _ in }
        let bodies = sender.bodies(clockTime: "22:49")
        #expect(bodies.count == 2)
        #expect(bodies[0] == LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: 2), clockTime: "22:49"))
        #expect(bodies[1] == LidGuardPolicy.messageBody(kind: .test, clockTime: "22:49"))
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
