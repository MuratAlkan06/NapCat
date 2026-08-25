// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Structural isolation for Track B slice B2 (mirrors
/// ClaudeDetectionStructureTests and the DebugPowerSimulator lint):
/// process spawning, the IOKit power registration, and the AppleEvent
/// permission probe each live in exactly ONE file; the whole subsystem is
/// absent from the debug-simulator object graph; the sender API cannot carry
/// free text; the shipped AppleScript is argv-only; and the feature adds no
/// privileged surface.
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
        "OSAScriptMessageSender.swift",
        "SystemSleepSource.swift",
        "AutomationPermissionProbe.swift",
    ]

    // MARK: - Symbol confinement

    /// Each externally-visible capability may appear in ONE file only, repo
    /// wide. Vacuity is guarded: the token must really be present there.
    @Test func externalCapabilitiesAreConfinedToOneFileEach() throws {
        let allowed: [String: String] = [
            "osascript": "OSAScriptMessageSender.swift",
            "IORegisterForSystemPower": "SystemSleepSource.swift",
            "IODeregisterForSystemPower": "SystemSleepSource.swift",
            "IOAllowPowerChange": "SystemSleepSource.swift",
            "IONotificationPortSetDispatchQueue": "SystemSleepSource.swift",
            "AEDeterminePermissionToAutomateTarget": "AutomationPermissionProbe.swift",
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

    /// Inside the B2 subsystem only the sender may construct a subprocess.
    @Test func onlyTheSenderMaySpawnAProcess() throws {
        let sources = try Self.swiftSources()
        let spawnTokens = ["Process(", "posix_spawn", "NSTask", "system(", "popen"]
        for (name, text) in sources where Self.b2Files.contains(name) && name != "OSAScriptMessageSender.swift" {
            for token in spawnTokens {
                #expect(!text.contains(token), "'\(token)' in \(name) — only the sender may spawn")
            }
        }
        let sender = try #require(sources.first { $0.name == "OSAScriptMessageSender.swift" })
        #expect(sender.text.contains("Process("), "lint would be vacuous if the sender stopped spawning")
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
            "OSAScriptMessageSender(",
            "AppleEventAutomationProbe(",
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
            for token in ["osascript", "IORegisterForSystemPower", "IOAllowPowerChange",
                          "AEDeterminePermissionToAutomateTarget"] {
                #expect(!text.contains(token), "'\(token)' must not appear in \(file)")
            }
        }
    }

    // MARK: - Sender API surface (body is app-generated, enforced by shape)

    /// The one send entry point takes NO free-text parameter — byte-locked, so
    /// adding a `body:`/`text:` String would fail here.
    @Test func theSenderApiCannotCarryFreeText() throws {
        let source = try String(
            contentsOf: Self.sourcesDir().appendingPathComponent("MessageSender.swift"),
            encoding: .utf8
        )
        let expected = [
            "    func send(",
            "        _ kind: LidGuardMessageKind,",
            "        to recipient: String,",
            "        at firedAt: Date,",
            "        completion: @escaping @Sendable (MessageSendOutcome) -> Void",
            "    )",
        ].joined(separator: "\n")
        #expect(source.contains(expected), "the MessageSender signature changed — re-review the free-text guarantee")

        // Within the protocol declaration, `recipient` is the ONLY String.
        let start = try #require(source.range(of: "protocol MessageSender"))
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "\n}"))
        let declaration = String(body[..<end.lowerBound])
        let stringParameters = declaration.components(separatedBy: ": String").count - 1
        #expect(stringParameters == 1, "expected exactly one String parameter (the recipient), found \(stringParameters)")
        for forbidden in ["body:", "text:", "message:", "subject:"] {
            #expect(!declaration.contains(forbidden), "'\(forbidden)' would let caller text reach a message")
        }
    }

    /// The dry-run sender proves the produced body really is the template.
    @Test func theDryRunSenderProducesOnlyTemplateBodies() {
        let sender = RecordingMessageSender()
        sender.send(.lidAlert(busySessionCount: 2), to: "+15551234567", at: Date(timeIntervalSince1970: 0)) { _ in }
        sender.send(.test, to: "+15551234567", at: Date(timeIntervalSince1970: 0)) { _ in }
        let bodies = sender.bodies(clockTime: "22:49")
        #expect(bodies.count == 2)
        #expect(bodies[0] == LidGuardPolicy.messageBody(kind: .lidAlert(busySessionCount: 2), clockTime: "22:49"))
        #expect(bodies[1] == LidGuardPolicy.messageBody(kind: .test, clockTime: "22:49"))
    }

    // MARK: - The shipped AppleScript

    /// The script is FIXED and argv-only. It is deliberately NOT compiled here:
    /// compiling `tell application "Messages"` makes AppleScript fetch the
    /// app's terminology over an AppleEvent, which can launch Messages and
    /// raise the very Automation prompt `make test` must never trigger. The
    /// real proof is the user-run test send (hardware spike SB1).
    @Test func theBundledAppleScriptIsFixedAndArgvOnly() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(LidGuardTuning.scriptResourceName).\(LidGuardTuning.scriptResourceExtension)")
        #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        let script = try String(contentsOf: url, encoding: .utf8)

        for required in [
            "on run argv",
            "set theRecipient to item 1 of argv",
            "set theBody to item 2 of argv",
            "with timeout of 8 seconds",
            "tell application \"Messages\"",
            "send theBody to participant theRecipient",
            "end run",
        ] {
            #expect(script.contains(required), "the script must contain: \(required)")
        }

        // No interpolation, no shell, no nested evaluation: the two inputs are
        // only ever bound to variables from argv.
        for forbidden in ["do shell script", "run script", "sudo", "system attribute", "&", "\\("] {
            #expect(!script.contains(forbidden), "'\(forbidden)' must not appear in the send script")
        }
    }

    /// The bundle must actually ship it (the sender resolves it by name).
    @Test func theMakefileInstallsTheAppleScriptIntoTheBundle() throws {
        let makefile = try String(contentsOf: Self.repoRoot().appendingPathComponent("Makefile"), encoding: .utf8)
        let resource = "\(LidGuardTuning.scriptResourceName).\(LidGuardTuning.scriptResourceExtension)"
        #expect(makefile.contains("Resources/\(resource)"), "Makefile must copy \(resource) into the app bundle")
        #expect(makefile.contains("Contents/Resources/\(resource)"))
    }

    /// The Automation prompt needs a purpose string or macOS shows a bare
    /// dialog (and on some releases refuses outright).
    @Test func infoPlistDeclaresTheAppleEventsUsageDescription() throws {
        let plist = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("Resources/Info.plist"),
            encoding: .utf8
        )
        #expect(plist.contains("NSAppleEventsUsageDescription"))
        #expect(plist.contains("Claude Code task"), "the purpose string must explain what the messages are")
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
