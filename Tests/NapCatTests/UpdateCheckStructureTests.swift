// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #111 — structural locks for the update check, each canary-proven
/// in-suite (a mutated copy of the shipped source must trip the rule):
/// - the GitHub client is provably UNAUTHENTICATED: no Authorization, no
///   token, no cookie or credential handling, nothing read from the
///   environment or the keychain;
/// - the host literal `api.github.com` appears exactly once in Sources;
/// - https only, and the release page is built from the constant prefix and
///   the validated tag — no response field but `tag_name` is ever read;
/// - nothing in the feature schedules anything (no timers);
/// - the feature is Mac-only: the iOS project never compiles it.
/// (URL loading itself is confined by the three-file networking allowlist:
/// `LidGuardStructureTests.urlLoadingIsConfinedToTheThreeSanctionedFiles`.)
struct UpdateCheckStructureTests {
    static let checkerFile = "GitHubReleaseChecker.swift"
    /// Every file of the feature (the controller and the UI wiring join in
    /// later slices of the same issue).
    static let updateFiles = ["UpdateVersion.swift", "UpdateCadence.swift", checkerFile]

    static func raw(_ file: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.sourcesDir().appendingPathComponent(file), encoding: .utf8)
    }

    static func rawSources() throws -> [(name: String, text: String)] {
        let dir = LidGuardStructureTests.sourcesDir()
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
            .map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// The non-comment lines of `text`, RAW. Unlike `codeOnly`, a `//` inside
    /// a string literal (every `https://` URL) cannot truncate the line, so
    /// nothing after it can hide from a scan. A trailing comment on a code
    /// line is kept — it can only over-count, which fails safe.
    static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    static func mutate(_ sources: [(name: String, text: String)], _ name: String,
                       _ transform: (String) -> String) -> [(name: String, text: String)] {
        sources.map { $0.name == name ? ($0.name, transform($0.text)) : $0 }
    }

    // MARK: - Unauthenticated, provably

    /// The configuration lines that DISABLE cookies and credentials — the
    /// only lines of the client allowed to name either. Each must be there.
    static let defensiveLines = [
        "configuration.httpShouldSetCookies = false",
        "configuration.httpCookieStorage = nil",
        "configuration.urlCredentialStorage = nil",
        "request.httpShouldHandleCookies = false",
    ]

    /// Anything that could carry, fetch or answer with a credential, matched
    /// case-INSENSITIVELY on every other code line of the client.
    static let credentialTokens = ["authorization", "bearer", "token", "cookie", "credential", "password", "secret",
                                   "apikey", "api_key", "x-github", "processinfo", "environment", "getenv",
                                   "keychain", "secitem", "userdefaults", "challenge", "httpadditionalheaders",
                                   "netrc", "setvalue(", "addvalue("]

    static func credentialFailures(_ checker: String) -> [String] {
        var failures: [String] = []
        var seen: [String: Int] = [:]
        for line in codeLines(checker) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if defensiveLines.contains(trimmed) {
                seen[trimmed, default: 0] += 1
                continue
            }
            for token in credentialTokens where trimmed.lowercased().contains(token) {
                failures.append("'\(token)' in \(checkerFile) — the update check is unauthenticated: \(trimmed)")
            }
        }
        for line in defensiveLines where seen[line] != 1 {
            failures.append("'\(line)' must appear exactly once in \(checkerFile) — got \(seen[line] ?? 0)")
        }
        // Exactly NapCat's two headers, set as one dictionary.
        let headers = checker.components(separatedBy: "allHTTPHeaderFields").count - 1
        if headers != 1 { failures.append("allHTTPHeaderFields is set \(headers)× — expected once") }
        let block = checker.components(separatedBy: "request.allHTTPHeaderFields = [").dropFirst().first?
            .components(separatedBy: "]").first ?? ""
        let keys = block.components(separatedBy: "\":").count - 1
        if !block.contains("\"User-Agent\": \"\\(userAgentProduct)/\\(running)\"")
            || !block.contains("\"Accept\": acceptValue") || keys != 2 {
            failures.append("the request's headers must be exactly User-Agent and Accept — got \(block)")
        }
        return failures
    }

    @Test func theClientCanCarryNoCredential() throws {
        let checker = try Self.raw(Self.checkerFile)
        #expect(Self.credentialFailures(checker).isEmpty, "\(Self.credentialFailures(checker))")
        let anchor = "        request.allHTTPHeaderFields = ["
        let canaries: [(String, String)] = [
            ("an Authorization header", checker.replacingOccurrences(
                of: anchor, with: "        request.addValue(\"Bearer x\", forHTTPHeaderField: \"Authorization\")\n" + anchor)),
            ("a token from the environment", checker + "\nlet canary = ProcessInfo.processInfo.environment[\"GITHUB_TOKEN\"]"),
            ("a third header", checker.replacingOccurrences(
                of: "            \"Accept\": acceptValue,", with: "            \"Accept\": acceptValue,\n            \"X-Canary\": \"1\",")),
            ("the shared cookie jar", checker.replacingOccurrences(
                of: "configuration.httpCookieStorage = nil", with: "configuration.httpCookieStorage = .shared")),
            ("cookies handled after all", checker.replacingOccurrences(
                of: "request.httpShouldHandleCookies = false", with: "request.httpShouldHandleCookies = true")),
            ("an auth-challenge answer", checker + "\nfunc urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge) {}"),
            // Spelled in pieces: no test file may name a Security item call
            // (KeychainTopicStoreTests.noTestFileCanReachTheRealKeychain).
            ("a keychain read", checker + "\nlet canary = " + "Sec" + "Item" + "CopyMatching(q, &r)"),
            ("extra session headers", checker.replacingOccurrences(
                of: "configuration.waitsForConnectivity = false",
                with: "configuration.waitsForConnectivity = false\n        configuration.httpAdditionalHeaders = [:]")),
        ]
        for (name, mutant) in canaries {
            #expect(mutant != checker, "canary setup '\(name)': target text must exist")
            #expect(!Self.credentialFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Negative control: a doc comment may name what is absent.
        #expect(Self.credentialFailures(checker + "\n/// no Authorization, no token, no cookie").isEmpty)
    }

    // MARK: - One host literal, https only

    static let hostLiteral = "api.github.com"

    static func hostFailures(_ sources: [(name: String, text: String)]) -> [String] {
        var failures: [String] = []
        var sites: [String] = []
        for (name, text) in sources {
            for line in codeLines(text) {
                sites += Array(repeating: name, count: line.components(separatedBy: hostLiteral).count - 1)
            }
        }
        if sites != [checkerFile] {
            failures.append("'\(hostLiteral)' appears at \(sites) — expected exactly once in Sources, in \(checkerFile)")
        }
        let checker = sources.first { $0.name == checkerFile }?.text ?? ""
        if !checker.contains("    static let apiHost = \"\(hostLiteral)\"\n") {
            failures.append("the one literal must be `static let apiHost`")
        }
        let lines = codeLines(checker)
        if lines.contains(where: { $0.contains("http://") }) { failures.append("plain http in \(checkerFile)") }
        let https = lines.filter { $0.contains("https://") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = ["static let releasePagePrefix = \"https://github.com/MuratAlkan06/NapCat/releases/tag/\"",
                        "let address = \"https://\" + apiHost + latestReleasePath"]
        if Set(https) != Set(expected) || https.count != 2 {
            failures.append("https URLs in \(checkerFile) must be exactly the request and the release-page prefix — got \(https)")
        }
        return failures
    }

    @Test func theHostLiteralAppearsExactlyOnce() throws {
        let sources = try Self.rawSources()
        #expect(Self.hostFailures(sources).isEmpty, "\(Self.hostFailures(sources))")
        let canaries: [(String, [(name: String, text: String)])] = [
            ("a second literal in the checker", Self.mutate(sources, Self.checkerFile) {
                $0 + "\nlet canary = URL(string: \"https://api.github.com/x\")" }),
            ("a literal in the model", Self.mutate(sources, "MenuStateModel.swift") {
                $0 + "\nlet canary = \"Contacts api.github.com\"" }),
            ("the literal hidden after a URL's slashes", Self.mutate(sources, "NapCatApp.swift") {
                $0 + "\nlet canary = \"https://\" + \"api.github.com\"" }),
            ("plain http", Self.mutate(sources, Self.checkerFile) {
                $0.replacingOccurrences(of: "let address = \"https://\" + apiHost", with: "let address = \"http://\" + apiHost") }),
            ("a third URL", Self.mutate(sources, Self.checkerFile) {
                $0 + "\nlet canary = \"https://objects.githubusercontent.com\"" }),
        ]
        for (name, mutant) in canaries {
            #expect(!Self.hostFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        #expect(Self.hostFailures(Self.mutate(sources, "MenuStateModel.swift") {
            $0 + "\n/// asks api.github.com"
        }).isEmpty, "a doc comment may name the host")
    }

    // MARK: - tag_name only; the release page from constants

    /// Response fields the client must never read.
    static let foreignFields = ["\"html_url\"", "\"url\"", "\"assets_url\"", "\"upload_url\"", "\"tarball_url\"",
                                "\"zipball_url\"", "\"browser_download_url\"", "\"assets\"", "\"body\"", "\"name\"",
                                "\"target_commitish\"", "\"prerelease\"", "\"draft\""]

    static func responseFailures(_ checker: String) -> [String] {
        var failures: [String] = []
        let lines = codeLines(checker)
        let code = lines.joined(separator: "\n")
        for field in foreignFields where code.contains(field) {
            failures.append("\(field) in \(checkerFile) — tag_name is the only field the update check reads")
        }
        if !code.contains("static let tagField = \"tag_name\"") { failures.append("tagField must be \"tag_name\"") }
        let reads = code.components(separatedBy: "fields[").count - 1
        if reads != 1 || !code.contains("fields[tagField] as? String") {
            failures.append("the response is read exactly once, at fields[tagField] — got \(reads) reads")
        }
        // Every URL the client builds comes from constants (+ the validated
        // tag's own rendering): exactly two, both from a local `address`.
        let builds = lines.filter { $0.contains("URL(string:") }.map { $0.trimmingCharacters(in: .whitespaces) }
        if builds.count != 2 || !builds.allSatisfy({ $0.hasPrefix("guard let url = URL(string: address), ") }) {
            failures.append("URL(string:) must take the local constant-built address, twice — got \(builds)")
        }
        let addresses = lines.filter { $0.contains("let address =") }.map { $0.trimmingCharacters(in: .whitespaces) }
        if Set(addresses) != ["let address = \"https://\" + apiHost + latestReleasePath",
                              "let address = releasePagePrefix + version.tag"] || addresses.count != 2 {
            failures.append("the two addresses must be the pinned request and prefix + validated tag — got \(addresses)")
        }
        if !code.contains("static func releasePageURL(for version: ReleaseVersion) -> URL? {") {
            failures.append("the release page must be built from a validated ReleaseVersion only")
        }
        return failures
    }

    @Test func onlyTheTagIsReadAndTheReleasePageComesFromConstants() throws {
        let checker = try Self.raw(Self.checkerFile)
        #expect(Self.responseFailures(checker).isEmpty, "\(Self.responseFailures(checker))")
        let canaries: [(String, String)] = [
            ("html_url read", checker + "\nlet canary = fields[\"html_url\"] as? String"),
            ("a second field read", checker.replacingOccurrences(
                of: "guard let tag = fields[tagField] as? String",
                with: "_ = fields[\"id\"]\n        guard let tag = fields[tagField] as? String")),
            ("the page from a response string", checker.replacingOccurrences(
                of: "let address = releasePagePrefix + version.tag", with: "let address = releasePagePrefix + rawTag")),
            ("the page from html_url", checker.replacingOccurrences(
                of: "static func releasePageURL(for version: ReleaseVersion) -> URL? {",
                with: "static func releasePageURL(for htmlURL: String) -> URL? {")),
            ("a URL from a response", checker + "\nlet canary = URL(string: tag)"),
        ]
        for (name, mutant) in canaries {
            #expect(mutant != checker, "canary setup '\(name)': target text must exist")
            #expect(!Self.responseFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Ephemeral, redirect-refusing, bounded

    /// The session shape, as code (its values are checked at runtime in
    /// GitHubReleaseClientTests): ephemeral, never the default or shared
    /// configuration, a delegate whose redirect answer is `nil`, and the
    /// same 10 s bound on the request, the resource and the session.
    @Test func theSessionIsEphemeralAndRefusesRedirects() throws {
        let code = Self.codeLines(try Self.raw(Self.checkerFile)).joined(separator: "\n")
        #expect(code.contains("let configuration = URLSessionConfiguration.ephemeral"))
        #expect(!code.contains("URLSessionConfiguration.default") && !code.contains(".background("))
        #expect(code.contains("static let requestTimeout: TimeInterval = 10"))
        for line in ["request.timeoutInterval = requestTimeout", "configuration.timeoutIntervalForRequest = requestTimeout",
                     "configuration.timeoutIntervalForResource = requestTimeout",
                     "configuration.waitsForConnectivity = false"] {
            #expect(code.contains(line), "'\(line)'")
        }
        let redirect = try #require(code.components(separatedBy: "willPerformHTTPRedirection").dropFirst().first)
        let body = try #require(redirect.components(separatedBy: "{").dropFirst().first?.components(separatedBy: "}").first)
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "completionHandler(nil)",
                "a redirect is refused, never followed — got '\(body)'")
        #expect(code.contains("URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)"))
        #expect(code.components(separatedBy: "URLSession(").count - 1 == 1, "one session construction site")
    }

    // MARK: - No timers

    static let schedulingTokens = ["Timer", "asyncAfter", "makeTimerSource", "repeating", "Task.sleep",
                                   "DispatchSource", "sleep(", "RunLoop", "perform(#selector"]

    @Test func nothingInTheFeatureSchedulesAnything() throws {
        for file in Self.updateFiles {
            let code = LidGuardStructureTests.codeOnly(try Self.raw(file))
            for token in Self.schedulingTokens {
                #expect(!code.contains(token), "'\(token)' in \(file) — the update check runs only on a user action")
            }
        }
    }

    // MARK: - Mac only

    /// The iOS receiver never compiles the update check: the files live in
    /// the Mac app's target (never the shared NapCatWire), the phone project
    /// links only the NapCatWire product, and its project file never names
    /// them.
    @Test func theIOSTargetNeverCompilesTheUpdateCheck() throws {
        let root = LidGuardStructureTests.repoRoot()
        let wire = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/NapCatWire").path)
        for file in Self.updateFiles {
            #expect(FileManager.default.fileExists(atPath: LidGuardStructureTests.sourcesDir().appendingPathComponent(file).path),
                    "\(file) belongs to the Mac app target")
            #expect(!wire.contains(file), "\(file) must never be shared with the phone")
        }
        let project = try String(contentsOf: root.appendingPathComponent("ios/NapCatPhone/project.yml"), encoding: .utf8)
        #expect(project.contains("product: NapCatWire") && !project.contains("product: NapCat\n"),
                "the phone links the wire contract only")
        #expect(!project.contains("Sources/NapCat/"), "the phone project never pulls the Mac sources")
        let pbxproj = try String(contentsOf: root.appendingPathComponent(
            "ios/NapCatPhone/NapCatPhone.xcodeproj/project.pbxproj"), encoding: .utf8)
        for name in ["GitHubReleaseChecker", "UpdateCadence", "UpdateVersion", "UpdateCheck", "api.github.com"] {
            #expect(!pbxproj.contains(name), "'\(name)' in the phone project")
        }
        let phoneSources = root.appendingPathComponent("ios/NapCatPhone")
        let paths = try #require(FileManager.default.subpaths(atPath: phoneSources.path)).filter { $0.hasSuffix(".swift") }
        #expect(!paths.isEmpty, "vacuity: the phone sources were found")
        for path in paths {
            let text = try String(contentsOf: phoneSources.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("api.github.com") && !text.contains("GitHubReleaseChecker"), "\(path)")
        }
    }
}
