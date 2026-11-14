// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Alert-channel healing (issue #23) — structural locks for the connectivity
/// interface, each canary-proven in-suite (a mutated copy of the shipped
/// source must trip the rule; a comment naming the token must not):
/// - the Network framework is confined to ONE file, `ConnectivityMonitor.swift`;
/// - that monitor watches EVERY interface (never Wi-Fi only), builds a fresh
///   monitor inside `start`, and delivers off the main queue;
/// - the simulator is structurally isolated (zero imports, no I/O tokens);
/// - each implementation has ONE construction site — the startup swap;
/// - nothing in the subsystem schedules anything (zero wakeups disarmed);
/// - the "connectivity" log category carries fixed words only — no topic,
///   URL, network name, interface name or address.
struct ConnectivityStructureTests {
    static let interfaceFile = "ConnectivityInterface.swift"
    static let monitorFile = "ConnectivityMonitor.swift"
    static let simulatorFile = "ConnectivitySimulator.swift"
    static let connectivityFiles = [interfaceFile, monitorFile, simulatorFile]

    static func sources() throws -> [(name: String, text: String)] {
        try LidGuardStructureTests.swiftSources()
    }

    static func raw(_ file: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(file), encoding: .utf8)
    }

    /// Replaces `name`'s text in a copy of `sources`.
    static func mutate(_ sources: [(name: String, text: String)], _ name: String,
                       _ transform: (String) -> String) -> [(name: String, text: String)] {
        sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
    }

    // MARK: - Network framework confinement

    /// Tokens that reach the Network framework. Matched case-sensitively in
    /// comment-stripped code.
    static let networkTokens = ["import Network", "NWPath", "NWInterface", "NWConnection", "NWEndpoint",
                                "NWParameters", "NWBrowser", "NWListener", "nw_path", "nw_connection"]

    static func networkConfinementFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where name != monitorFile {
            for token in networkTokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — the Network framework stays in \(monitorFile)")
            }
        }
        let monitor = sources.first { $0.name == monitorFile }?.text ?? ""
        for token in ["import Network", "NWPathMonitor()"] where !monitor.contains(token) {
            failures.append("'\(token)' not found in \(monitorFile) — the confinement lint would be vacuous")
        }
        return failures
    }

    @Test func theNetworkFrameworkIsConfinedToTheMonitorFile() throws {
        let sources = try Self.sources()
        #expect(Self.networkConfinementFailures(sources).isEmpty, "\(Self.networkConfinementFailures(sources))")

        let canaries: [(String, [(name: String, text: String)])] = [
            ("controller builds a monitor", Self.mutate(sources, "FinishAlertController.swift") {
                $0 + "\nlet m = NWPathMonitor()" }),
            ("interface imports Network", Self.mutate(sources, Self.interfaceFile) { "import Network\n" + $0 }),
            ("simulator names a path", Self.mutate(sources, Self.simulatorFile) { $0 + "\nlet p: NWPath? = nil" }),
            ("app reads an interface", Self.mutate(sources, "NapCatApp.swift") { $0 + "\nlet i: NWInterface? = nil" }),
            ("monitor loses its import", Self.mutate(sources, Self.monitorFile) {
                $0.replacingOccurrences(of: "import Network", with: "") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.networkConfinementFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Negative control: a comment may name the framework.
        let commented = Self.mutate(sources, Self.interfaceFile) { $0 + "\n// never NWPathMonitor, import Network" }
        #expect(Self.networkConfinementFailures(commented.map {
            ($0.name, LidGuardStructureTests.codeOnly($0.text))
        }).isEmpty)
    }

    // MARK: - All interfaces, fresh per start, off the main queue

    /// Interface restrictions and interface reads: the monitor never narrows
    /// itself to one kind of interface and never looks at which one is up.
    static let interfaceRestrictionTokens = ["requiredInterfaceType", "prohibitedInterfaceTypes", ".wifi",
                                             ".wiredEthernet", ".cellular", ".loopback", ".other",
                                             "usesInterfaceType", "availableInterfaces", "NWInterface",
                                             "gateways", "localEndpoint", "remoteEndpoint"]

    static func monitorShapeFailures(_ monitorSource: String) -> [String] {
        var failures: [String] = []
        let code = LidGuardStructureTests.codeOnly(monitorSource)
        for token in interfaceRestrictionTokens where code.contains(token) {
            failures.append("'\(token)' in \(monitorFile) — the path monitor watches every interface and names none")
        }
        let constructions = code.components(separatedBy: "NWPathMonitor(").count - 1
        if constructions != 1 { failures.append("NWPathMonitor( appears \(constructions)× — expected exactly one site") }
        if !code.contains("NWPathMonitor()") { failures.append("the path monitor must be built with no interface type") }
        // Fresh per arm cycle: the one construction sits INSIDE `start`.
        if let start = code.range(of: "func start("), let stop = code.range(of: "func stop(") {
            let body = code[start.upperBound..<max(start.upperBound, stop.lowerBound)]
            if !body.contains("NWPathMonitor()") {
                failures.append("NWPathMonitor() is not built inside start — a cancelled monitor is terminal")
            }
            let stopTail = code[stop.upperBound...]
            let stopBody = stopTail[..<(stopTail.range(of: "\n    }\n")?.lowerBound ?? stopTail.endIndex)]
            if !stopBody.contains(".cancel()") { failures.append("stop must cancel the monitor") }
        } else {
            failures.append("start / stop not found in \(monitorFile)")
        }
        // Delivered on the private serial queue, never main.
        for token in [".main", "MainActor"] where code.contains(token) {
            failures.append("'\(token)' in \(monitorFile) — path updates are delivered off the main queue")
        }
        if !code.contains("fresh.start(queue: queue)") { failures.append("the monitor must start on its private queue") }
        return failures
    }

    @Test func theRealMonitorWatchesEveryInterfaceFreshAndOffMain() throws {
        let source = try Self.raw(Self.monitorFile)
        #expect(source.contains("final class PathConnectivityMonitor"), "vacuity: the real monitor file")
        #expect(Self.monitorShapeFailures(source).isEmpty, "\(Self.monitorShapeFailures(source))")

        let mutants: [(String, String, String)] = [
            ("Wi-Fi only", "NWPathMonitor()", "NWPathMonitor(requiredInterfaceType: .wifi)"),
            ("prohibited types", "let fresh = NWPathMonitor()",
             "let fresh = NWPathMonitor(prohibitedInterfaceTypes: [.cellular])"),
            ("main-queue delivery", "fresh.start(queue: queue)", "fresh.start(queue: .main)"),
            ("stored, reused monitor", "    private let lock = NSLock()",
             "    private let shared = NWPathMonitor()\n    private let lock = NSLock()"),
            ("interface read", "let status = Self.status(for: path.status)",
             "let status = Self.status(for: path.status); _ = path.availableInterfaces"),
            ("stop no longer cancels", "        running.cancel()\n", "\n"),
        ]
        for (name, target, replacement) in mutants {
            let mutant = source.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != source, "canary setup '\(name)'")
            #expect(!Self.monitorShapeFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        let commented = source + "\n// never requiredInterfaceType: .wifi, never DispatchQueue.main\n"
        #expect(Self.monitorShapeFailures(commented).isEmpty, "a doc mention must not trip the lint")
    }

    // MARK: - Simulator isolation

    /// Banned in the simulator's code (comment-stripped, case-sensitive).
    static let simulatorBannedTokens = ["NWPath", "Network", "Dispatch", "Timer", "asyncAfter", "Logger", "logger",
                                        "ConnectivityLog", "URLSession", "Process", "Thread", "sleep", "socket",
                                        "PathConnectivityMonitor", "UserDefaults", "FileManager"]

    static func simulatorIsolationFailures(_ source: String) -> [String] {
        var failures: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(separator: " ")
            if let index = words.firstIndex(of: "import"), words[..<index].allSatisfy({ $0.hasPrefix("@") }) {
                failures.append("\(simulatorFile) must have zero imports, found: \(trimmed)")
            }
        }
        let code = LidGuardStructureTests.codeOnly(source)
        for token in simulatorBannedTokens where code.contains(token) {
            failures.append("'\(token)' in \(simulatorFile) — the simulator is in-memory only")
        }
        return failures
    }

    @Test func theSimulatorIsStructurallyIsolated() throws {
        let source = try Self.raw(Self.simulatorFile)
        try #require(source.contains("final class ConnectivitySimulator"), "vacuity: the simulator file")
        #expect(Self.simulatorIsolationFailures(source).isEmpty, "\(Self.simulatorIsolationFailures(source))")

        let anchor = "final class ConnectivitySimulator: ConnectivityInterface {"
        try #require(source.contains(anchor))
        var mutants = Self.simulatorBannedTokens.map { ("token \($0)", anchor + "\n    let canary = \($0)") }
        mutants += [
            ("import", "import Foundation\n" + anchor),
            ("attributed import", "@preconcurrency import Dispatch\n" + anchor),
        ]
        for (name, replacement) in mutants {
            let mutant = source.replacingOccurrences(of: anchor, with: replacement)
            #expect(mutant != source, "canary setup '\(name)'")
            #expect(!Self.simulatorIsolationFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        let commented = source.replacingOccurrences(of: anchor, with: anchor + "\n    // never Network, Timer, Logger")
        #expect(Self.simulatorIsolationFailures(commented).isEmpty, "a doc mention must not trip the lint")
    }

    // MARK: - Seam count (startup protocol swap)

    /// The ONE construction site of each implementation is the startup swap
    /// in `ConnectivityWiring.makeInterface`, and its debug branch builds the
    /// simulator — so debugBattery mode can never hold a real path monitor.
    static let swapExpression = "debugBattery ? ConnectivitySimulator() : PathConnectivityMonitor()"

    static func seamFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for token in ["PathConnectivityMonitor(", "ConnectivitySimulator("] {
            let sites = sources.flatMap { source in
                Array(repeating: source.name, count: source.text.components(separatedBy: token).count - 1)
            }
            if sites != [interfaceFile] {
                failures.append("'\(token)' is constructed at \(sites) — expected exactly one site, in \(interfaceFile)")
            }
        }
        let interface = sources.first { $0.name == interfaceFile }?.text ?? ""
        if interface.components(separatedBy: swapExpression).count - 1 != 1 {
            failures.append("the startup swap must read exactly '\(swapExpression)'")
        }
        return failures
    }

    @Test func eachImplementationHasASingleConstructionSite() throws {
        let sources = try Self.sources()
        #expect(Self.seamFailures(sources).isEmpty, "\(Self.seamFailures(sources))")

        let canaries: [(String, [(name: String, text: String)])] = [
            ("app builds the real monitor", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet m = PathConnectivityMonitor()" }),
            ("controller builds a simulator", Self.mutate(sources, "FinishAlertController.swift") {
                $0 + "\nlet s = ConnectivitySimulator()" }),
            ("swapped branches", Self.mutate(sources, Self.interfaceFile) {
                $0.replacingOccurrences(of: Self.swapExpression,
                                        with: "debugBattery ? PathConnectivityMonitor() : ConnectivitySimulator()") }),
            ("real monitor in debug mode", Self.mutate(sources, Self.interfaceFile) {
                $0.replacingOccurrences(of: Self.swapExpression, with: "PathConnectivityMonitor()") }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.seamFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Zero wakeups

    /// Nothing in the subsystem runs periodically or defers work: the real
    /// monitor only reacts to the system's path updates, and the owner's
    /// debounce lives in its own one-shot scheduler.
    static let schedulingTokens = ["Timer", "asyncAfter", "makeTimerSource", "repeating", "sleep(", "Task {",
                                   "Task.sleep", "DispatchSource"]

    static func schedulingFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        for (name, text) in sources where connectivityFiles.contains(name) {
            for token in schedulingTokens where text.contains(token) {
                failures.append("'\(token)' in \(name) — the connectivity interface never schedules anything")
            }
        }
        if sources.filter({ connectivityFiles.contains($0.name) }).count != connectivityFiles.count {
            failures.append("a connectivity file is missing — the lint would be vacuous")
        }
        return failures
    }

    @Test func theConnectivityFilesNeverScheduleAnything() throws {
        let sources = try Self.sources()
        #expect(Self.schedulingFailures(sources).isEmpty, "\(Self.schedulingFailures(sources))")
        for file in Self.connectivityFiles {
            for token in ["let t = Timer.scheduledTimer", "DispatchQueue.main.asyncAfter(deadline: .now()) {}",
                          "let s = DispatchSource.makeTimerSource()"] {
                #expect(!Self.schedulingFailures(Self.mutate(sources, file) { $0 + "\n" + token }).isEmpty,
                        "canary '\(token)' in \(file) was NOT caught")
            }
        }
    }

    // MARK: - Log hygiene ("connectivity" category)

    /// `.public` interpolations allowed on a connectivity log line: fixed
    /// words only. Nothing is ever logged `.private` — there is nothing worth
    /// hiding to say.
    static let publicLogExpressions: Set<String> = ["status.rawValue"]

    /// A connectivity log line may never name these — the topic is a
    /// password, and network / interface names and addresses identify where
    /// the Mac is.
    static let logSecretTokens = ["topic", "Topic", "url", "URL", "endpoint", "destination", "server", "ssid",
                                  "SSID", "nterface", "debugDescription", "description", "address", "hostname",
                                  "\\(path", "sessionID"]

    static let connectivityLoggerDeclaration =
        #"private static let logger = Logger(subsystem: "com.muratalkan.napcat", category: "connectivity")"#

    static func logFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        // Exactly one file declares the category: the interface file.
        let declaring = sources.filter { $0.text.contains("category: \"connectivity\"") }.map(\.name)
        if declaring != [interfaceFile] {
            failures.append("the connectivity logger is declared in \(declaring) — expected only \(interfaceFile)")
        }
        for (name, text) in sources where connectivityFiles.contains(name) {
            failures += LidGuardStructureTests.logLintFailures(text, file: name)
            if name != interfaceFile {
                // The monitor and the simulator log only through ConnectivityLog.
                for call in LidGuardStructureTests.logCalls(in: text) {
                    failures.append("\(name):\(call.line): log call '\(call.text.prefix { $0 != "\n" })' — log through ConnectivityLog")
                }
                for token in ["Logger", "import os", "os_log"] where text.contains(token) {
                    failures.append("'\(token)' in \(name) — only \(interfaceFile) holds the connectivity logger")
                }
                continue
            }
            if !text.contains(connectivityLoggerDeclaration) {
                failures.append("\(interfaceFile) must declare the connectivity logger exactly as expected")
            }
            for unit in LidGuardStructureTests.logScanUnits(text) {
                for secret in logSecretTokens where unit.contains(secret) {
                    failures.append("\(name): a connectivity log line carries '\(secret)': \(unit)")
                }
                for body in FinishAlertStructureTests.interpolations(in: unit) {
                    guard let split = body.range(of: ", privacy: ", options: .backwards) else {
                        failures.append("\(name): interpolation without a privacy level: \(unit)")
                        continue
                    }
                    let expression = String(body[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let level = String(body[split.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if level != ".public" || !publicLogExpressions.contains(expression) {
                        failures.append("\(name): '\(expression)' at '\(level)' is not a fixed connectivity word: \(unit)")
                    }
                }
            }
            // Type-level: no ConnectivityLog entry point takes a String.
            if let start = text.range(of: "enum ConnectivityLog {") {
                let body = text[start.upperBound...]
                let declaration = body[..<(body.range(of: "\n}")?.lowerBound ?? body.endIndex)]
                if declaration.contains(": String") || declaration.contains("Substring") {
                    failures.append("a ConnectivityLog entry point takes text — fixed words only")
                }
            } else {
                failures.append("enum ConnectivityLog not found in \(interfaceFile)")
            }
        }
        return failures
    }

    @Test func connectivityLogLinesCarryFixedWordsOnly() throws {
        let sources = try Self.sources()
        #expect(Self.logFailures(sources).isEmpty, "\(Self.logFailures(sources))")
        // Vacuity: the facade really logs, and the monitor really uses it.
        let interface = try #require(sources.first { $0.name == Self.interfaceFile })
        #expect(LidGuardStructureTests.logCalls(in: interface.text).count >= 3)
        let monitor = try #require(sources.first { $0.name == Self.monitorFile })
        #expect(monitor.text.contains("ConnectivityLog.pathChanged(status)"))

        let anchor = "enum ConnectivityLog {"
        let interfaceMutants: [(String, String)] = [
            ("text parameter",
             "    static func leak(_ name: String) { logger.notice(\"connectivity: \\(name, privacy: .public)\") }"),
            ("interface name at private",
             "    static func leak(_ s: ConnectivityPathStatus) { logger.notice(\"connectivity: \\(s.debugDescription, privacy: .private)\") }"),
            ("network name", "    static func leak() { logger.notice(\"connectivity: joined ssid\") }"),
            ("unannotated", "    static func leak(_ n: Int) { logger.notice(\"connectivity: \\(n)\") }"),
            ("unlisted public", "    static func leak(_ n: Int) { logger.notice(\"connectivity: \\(n, privacy: .public)\") }"),
            ("second logger", "    private static let other = Logger(subsystem: \"x\", category: \"y\")"),
            ("split call", "    static func leak() { logger.notice(\n        \"connectivity\") }"),
        ]
        for (name, line) in interfaceMutants {
            let mutant = Self.mutate(sources, Self.interfaceFile) { $0.replacingOccurrences(of: anchor, with: anchor + "\n" + line) }
            #expect(!Self.logFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        let shellMutants: [(String, String, String)] = [
            ("monitor logs directly", Self.monitorFile, "\nfunc canary() { Self.logger.notice(\"x\") }"),
            ("monitor declares a logger", Self.monitorFile,
             "\n" + Self.connectivityLoggerDeclaration.replacingOccurrences(of: "connectivity", with: "path")),
            ("simulator prints", Self.simulatorFile, "\nfunc canary() { print(\"x\") }"),
            ("second category owner", "NapCatApp.swift",
             "\nlet x = Logger(subsystem: \"com.muratalkan.napcat\", category: \"connectivity\")"),
        ]
        for (name, file, code) in shellMutants {
            #expect(!Self.logFailures(Self.mutate(sources, file) { $0 + code }).isEmpty, "canary '\(name)' was NOT caught")
        }
    }
}
