// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatSeam
import NapCatWire
import Testing

/// F4 slice I1a: the rails that put the bundled channel server,
/// Contents/MacOS/napcat-channel, in front of Claude Code. Every rule here is
/// a pure function over committed TEXT (the build files, the resources and
/// the scripts), read at test time. No script is ever executed by this suite,
/// and each lock catches planted mutants.
struct ChannelInstallStructureTests {
    typealias Files = [(path: String, text: String)]

    static let makefilePath = "Makefile"
    static let infoPlistPath = "Resources/Info.plist"
    static let packagePath = "Package.swift"
    static let checkPath = "scripts/check-release-entitlements.sh"
    static let installPath = "scripts/install-channel.sh"
    static let uninstallPath = "scripts/uninstall-channel.sh"
    static let scriptPaths = [installPath, uninstallPath]

    static func read(_ path: String) throws -> String {
        try String(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Executable script lines: trimmed, non-blank, not a whole-line comment.
    static func codeLines(_ script: String) -> [String] {
        lines(script)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    static func count(_ token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    /// Every capture group 1 of `pattern` in `line`.
    static func captures(_ pattern: String, in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern>"] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match -> String? in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    /// The lines from `head` to the first `}` line after it (a shell
    /// function), trimmed; nil when `head` is missing.
    static func functionBody(_ head: String, in script: String) -> [String]? {
        let all = lines(script).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = all.firstIndex(of: head) else { return nil }
        guard let end = all[start...].firstIndex(of: "}") else { return nil }
        return Array(all[start...end])
    }

    // MARK: - make bundles the helper and signs it first

    static let channelProduct = ".executable(name: \"napcat-channel\", targets: [\"NapCatChannel\"]),"
    static let channelVariable = "CHANNEL            := napcat-channel"
    static let channelBinaryVariable = "CHANNEL_BINARY     := .build/release/$(CHANNEL)"
    static let installHelper = "\tinstall -m 0755 $(CHANNEL_BINARY) $(APP)/Contents/MacOS/$(CHANNEL)"
    static let signHelper = "\t$(CODESIGN) --identifier $(CHANNEL_IDENTIFIER) $(APP)/Contents/MacOS/$(CHANNEL)"
    static let embedProfilePrefix = "\t$(if $(strip $(PROVISIONING_PROFILE)),install -m 0644 "
    static let signAppPrefix = "\t$(CODESIGN)$(if $(strip $(ENTITLEMENTS)), --entitlements "

    /// Every violation in a Makefile text: the helper is installed and then
    /// signed inside `all`, BEFORE the profile is embedded and the app is
    /// signed (nested code first), with exactly two signing lines in all —
    /// the helper's, which never takes entitlements, and the app's.
    static func makefileFailures(_ makefile: String) -> [String] {
        let all = lines(makefile)
        var failures: [String] = []
        for variable in [channelVariable, channelBinaryVariable] where all.filter({ $0 == variable }).count != 1 {
            failures.append("'\(variable)' must be defined exactly once")
        }
        guard let start = all.firstIndex(of: "all: smc") else { return failures + ["no `all: smc` target"] }
        let recipe = Array(all[(start + 1)...].prefix { $0.hasPrefix("\t") })
        let install = recipe.firstIndex(of: installHelper)
        let sign = recipe.firstIndex(of: signHelper)
        let embed = recipe.firstIndex { $0.hasPrefix(embedProfilePrefix) }
        let app = recipe.firstIndex { $0.hasPrefix(signAppPrefix) }
        guard let install, let sign, let embed, let app else {
            return failures + ["`all` must install the helper, sign it, embed the profile and sign the app: \([install, sign, embed, app])"]
        }
        if !(install < sign && sign < embed && embed < app) {
            failures.append("the helper must be installed, then signed, before the profile and the app: \([install, sign, embed, app])")
        }
        let signing = all.filter { $0.contains("$(CODESIGN)") }
        if signing != [signHelper, recipe[app]] {
            failures.append("exactly two signing lines, the helper's then the app's: \(signing)")
        }
        return failures
    }

    @Test func makeBundlesTheHelperAndSignsItBeforeTheApp() throws {
        let makefile = try Self.read(Self.makefilePath)
        let failures = Self.makefileFailures(makefile)
        #expect(failures.isEmpty, "\(failures)")
        let package = try Self.read(Self.packagePath)
        #expect(Self.count(Self.channelProduct, in: package) == 1,
                "the Makefile's CHANNEL is the napcat-channel product's name, which SwiftPM builds to .build/release/")
    }

    /// Canaries: the helper signed after the app, with entitlements, or not
    /// at all; never installed; a third signing line.
    @Test func theSigningOrderLockCatchesRegressionMutants() throws {
        let makefile = try Self.read(Self.makefilePath)
        try #require(Self.makefileFailures(makefile).isEmpty, "canary baseline must be clean")
        let signApp = try #require(Self.lines(makefile).first { $0.hasPrefix(Self.signAppPrefix) })
        let mutants: [(String, String)] = [
            ("helper signed after the app", makefile
                .replacingOccurrences(of: Self.signHelper + "\n", with: "")
                .replacingOccurrences(of: signApp + "\n", with: signApp + "\n" + Self.signHelper + "\n")),
            ("helper given entitlements", makefile.replacingOccurrences(
                of: Self.signHelper, with: "\t$(CODESIGN) --entitlements \"$(ENTITLEMENTS)\" --identifier $(CHANNEL_IDENTIFIER) $(APP)/Contents/MacOS/$(CHANNEL)")),
            ("helper never signed", makefile.replacingOccurrences(of: Self.signHelper + "\n", with: "")),
            ("helper never installed", makefile.replacingOccurrences(of: Self.installHelper + "\n", with: "")),
            ("a deep re-sign added", makefile.replacingOccurrences(of: signApp + "\n", with: signApp + "\n\t$(CODESIGN) --deep $(APP)\n")),
            ("helper renamed", makefile.replacingOccurrences(of: Self.channelVariable, with: "CHANNEL            := napcat-relay")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != makefile, "canary setup '\(name)': target text must exist")
            #expect(!Self.makefileFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - One helper identifier, wherever it is spelled

    /// The files that define the helper's signing identifier, each on one
    /// line: `prefix + identifier + suffix`.
    static let identifierDefinitions: [(path: String, prefix: String, suffix: String)] = [
        (makefilePath, "CHANNEL_IDENTIFIER := ", ""),
        (checkPath, "CHANNEL_IDENTIFIER=\"", "\""),
        (installPath, "CHANNEL_IDENTIFIER=\"", "\""),
    ]
    /// Files that spell the identifier once without defining it: the
    /// server's own dispatch queue label.
    static let identifierMentions = ["Sources/NapCatChannel/ChannelServer.swift"]

    /// Every text file the identifier could hide in: the build, the scripts,
    /// the resources, the four Mac targets, the workflows and the README.
    static func identifierScanFiles() throws -> Files {
        let root = LidGuardStructureTests.repoRoot()
        let manager = FileManager.default
        var paths = [makefilePath, packagePath, "README.md"]
        let folders = ["scripts", "Resources", ".github/workflows"] + ApprovalChannelStructureTests.directories
        for folder in folders {
            for name in try manager.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).sorted() {
                var isFolder: ObjCBool = false
                let path = folder + "/" + name
                if manager.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isFolder), !isFolder.boolValue {
                    paths.append(path)
                }
            }
        }
        return try paths.compactMap { path -> (path: String, text: String)? in
            guard let data = manager.contents(atPath: root.appendingPathComponent(path).path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return String(data: data, encoding: .utf8).map { (path, $0) }
        }
    }

    /// Every violation: each definition names `expected` on exactly one line
    /// and spells it nowhere else in its file; each mention spells it once;
    /// and no other scanned file spells it at all (a new copy must join this
    /// lock).
    static func identifierFailures(_ files: Files, expected: String) -> [String] {
        var failures: [String] = []
        for definition in identifierDefinitions {
            guard let text = files.first(where: { $0.path == definition.path })?.text else {
                failures.append("\(definition.path) was not read")
                continue
            }
            let defining = lines(text).filter { $0.hasPrefix(definition.prefix) }
            if defining != [definition.prefix + expected + definition.suffix] {
                failures.append("\(definition.path) must define the helper identifier once as \(expected): \(defining)")
            }
            if count(expected, in: text) != 1 {
                failures.append("\(definition.path) spells \(expected) \(count(expected, in: text)) times; use the variable")
            }
        }
        let listed = Set(identifierDefinitions.map(\.path) + identifierMentions)
        for mention in identifierMentions {
            let text = files.first(where: { $0.path == mention })?.text ?? ""
            if count(expected, in: text) != 1 { failures.append("\(mention) must spell \(expected) exactly once") }
        }
        for file in files where !listed.contains(file.path) && file.text.contains(expected) {
            failures.append("\(file.path) spells \(expected) but is not under this parity lock")
        }
        return failures
    }

    /// The helper is signed as the app's bundle identifier + ".channel", and
    /// every file that defines it agrees byte for byte.
    @Test func theHelperIdentifierIsOneStringEverywhere() throws {
        let files = try Self.identifierScanFiles()
        #expect(files.count > 20, "vacuity: the scan read the build, scripts, resources and sources")
        let plist = try #require(files.first { $0.path == Self.infoPlistPath }?.text)
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        let bundleIdentifier = try #require(parsed?["CFBundleIdentifier"] as? String)
        let failures = Self.identifierFailures(files, expected: bundleIdentifier + ".channel")
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Canaries: a drift in any defining file or in the mention, a second
    /// hard-coded copy, and a copy in a file outside the lock.
    @Test func theIdentifierParityCatchesEveryDrift() throws {
        let files = try Self.identifierScanFiles()
        let expected = "com.muratalkan.napcat.channel"
        try #require(Self.identifierFailures(files, expected: expected).isEmpty, "canary baseline must be clean")
        func mutate(_ path: String, _ transform: (String) -> String) -> Files {
            files.map { $0.path == path ? ($0.path, transform($0.text)) : $0 }
        }
        let drifted = "com.muratalkan.napcat.relay"
        var mutants: [(String, Files)] = [
            ("a second copy in the Makefile", mutate(Self.makefilePath) { $0 + "\n# signed as \(expected)\n" }),
            ("a copy outside the lock", mutate(Self.packagePath) { $0 + "\n// signed as \(expected)\n" }),
            ("the Makefile defines it twice", mutate(Self.makefilePath) { $0 + "\nCHANNEL_IDENTIFIER := \(expected)\n" }),
        ]
        for path in Self.identifierDefinitions.map(\.path) + Self.identifierMentions {
            mutants.append(("\(path) drifted", mutate(path) { $0.replacingOccurrences(of: expected, with: drifted) }))
        }
        for (name, mutant) in mutants {
            #expect(mutant.map(\.text) != files.map(\.text), "canary setup '\(name)': target text must exist")
            #expect(Self.identifierFailures(mutant, expected: expected) != [], "canary '\(name)' was NOT caught")
        }
        #expect(!Self.identifierFailures(files, expected: drifted).isEmpty, "the app's bundle identifier moved alone")
    }

    // MARK: - One team, the release's (#193)

    static let entitlementsPath = "Resources/NapCat.entitlements"
    static let teamPrefix = "TEAM_IDENTIFIER=\""
    static let teamRequirement =
        "TEAM_REQUIREMENT=\"anchor apple generic and certificate leaf[subject.OU] = \\\"$TEAM_IDENTIFIER\\\"\""

    /// Every violation: the installer defines the team once, as `expected`
    /// (the team the release is signed for), spells it nowhere else, and
    /// builds its Apple-anchored requirement from that one definition.
    static func teamFailures(install: String, expected: String) -> [String] {
        var failures: [String] = []
        let defining = lines(install).filter { $0.hasPrefix(teamPrefix) }
        if defining != [teamPrefix + expected + "\""] {
            failures.append("install-channel.sh must define the team once as \(expected): \(defining)")
        }
        if count(expected, in: install) != 1 {
            failures.append("install-channel.sh spells \(expected) \(count(expected, in: install)) times; use the variable")
        }
        if codeLines(install).filter({ $0 == teamRequirement }).count != 1 {
            failures.append("install-channel.sh must build its requirement once as \(teamRequirement)")
        }
        return failures
    }

    /// The installer's team is the one the committed entitlements name (the
    /// release's Developer ID team). Canaries: a drift on either side, a
    /// second copy, and a requirement that spells the team itself or drops
    /// its Apple anchor.
    @Test func theInstallerPinsTheTeamTheReleaseIsSignedFor() throws {
        let entitlements = try PropertyListSerialization.propertyList(
            from: Data(try Self.read(Self.entitlementsPath).utf8), format: nil) as? [String: Any]
        let team = try #require(entitlements?["com.apple.developer.team-identifier"] as? String)
        let install = try Self.read(Self.installPath)
        let failures = Self.teamFailures(install: install, expected: team)
        #expect(failures.isEmpty, "\(failures)")
        let drifted = "ABCDE12345"
        #expect(!Self.teamFailures(install: install, expected: drifted).isEmpty, "the entitlements' team moved alone")
        let mutants: [(String, String)] = [
            ("the installer's team drifted", install.replacingOccurrences(of: Self.teamPrefix + team, with: Self.teamPrefix + drifted)),
            ("a second copy", install.replacingOccurrences(of: "\nexit 0\n", with: "\n# signed for \(team)\nexit 0\n")),
            ("the requirement spells the team", install.replacingOccurrences(
                of: "= \\\"$TEAM_IDENTIFIER\\\"\"", with: "= \\\"\(team)\\\"\"")),
            ("the requirement drops its anchor", install.replacingOccurrences(of: "\"anchor apple generic and ", with: "\"")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != install, "canary setup '\(name)': target text must exist")
            #expect(!Self.teamFailures(install: mutant, expected: team).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - Info.plist names the server's version

    static let versionKey = "NapCatChannelVersion"

    /// Every way Info.plist's channel version can disagree with the server:
    /// one key, an `<integer>` holding exactly `expected` on the next line,
    /// and a plist that still parses to that integer.
    static func channelVersionFailures(_ plist: String, expected: Int) -> [String] {
        let all = lines(plist)
        let keys = all.indices.filter { all[$0].contains("<key>\(versionKey)</key>") }
        guard keys.count == 1, let at = keys.first else {
            return ["exactly one \(versionKey) key in Info.plist, found \(keys.count)"]
        }
        var failures: [String] = []
        let valueLine = at + 1 < all.count ? all[at + 1] : ""
        if valueLine != "\t<integer>\(expected)</integer>" {
            failures.append("the \(versionKey) value line reads '\(valueLine)', expected <integer>\(expected)</integer>")
        }
        let parsed = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        let number = parsed?[versionKey] as? NSNumber
        let isInteger = number.map { CFGetTypeID($0 as CFTypeRef) == CFNumberGetTypeID() && $0.intValue == expected } ?? false
        if !isInteger {
            failures.append("Info.plist does not parse to the integer \(expected) under \(versionKey)")
        }
        return failures
    }

    @Test func theInfoPlistNamesTheServersVersion() throws {
        let plist = try Self.read(Self.infoPlistPath)
        let failures = Self.channelVersionFailures(plist, expected: ApprovalChannel.serverVersion)
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Canaries: a bump on either side, another value type, a dropped or a
    /// duplicated key.
    @Test func theVersionParityCatchesADriftOnEitherSide() throws {
        let plist = try Self.read(Self.infoPlistPath)
        let expected = ApprovalChannel.serverVersion
        let value = "\t<integer>\(expected)</integer>"
        let entry = "\t<key>\(Self.versionKey)</key>\n" + value + "\n"
        try #require(Self.channelVersionFailures(plist, expected: expected).isEmpty, "canary baseline must be clean")
        #expect(!Self.channelVersionFailures(plist, expected: expected + 1).isEmpty, "Swift bumped, Info.plist not")
        let mutants: [(String, String)] = [
            ("Info.plist bumped", plist.replacingOccurrences(of: value, with: "\t<integer>\(expected + 1)</integer>")),
            ("a string", plist.replacingOccurrences(of: value, with: "\t<string>\(expected)</string>")),
            ("a boolean", plist.replacingOccurrences(of: value, with: "\t<true/>")),
            ("key dropped", plist.replacingOccurrences(of: entry, with: "")),
            ("key duplicated", plist.replacingOccurrences(of: "</dict>", with: entry + "</dict>")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != plist, "canary setup '\(name)': target text must exist")
            #expect(!Self.channelVersionFailures(mutant, expected: expected).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - The release check verifies the helper

    static let checkHelperPath = "HELPER=\"$APP/Contents/MacOS/napcat-channel\""
    static let checkFunctionHead = "check_channel_helper() {"
    static let checkCall = "check_channel_helper"
    static let unentitledBranch = "if [ \"$MODE\" = \"unentitled\" ]; then"
    static let adHocRefusal = "if grep -qx 'Signature=adhoc' <<< \"$SIGNATURE_INFO\"; then"
    /// What the helper check must compare (its body, verbatim lines).
    static let checkHelperRules = [
        "codesign --verify --strict \"$HELPER\" || die \"$HELPER fails codesign --verify --strict.\"",
        "[ \"$(signature_field \"$helper_info\" Identifier)\" = \"$CHANNEL_IDENTIFIER\" ] \\",
        "codesign -d --entitlements - --xml \"$HELPER\" > \"$WORK/helper.plist\" 2> /dev/null \\",
        "[ \"$helper_team\" = \"$app_team\" ] \\",
        "[ \"$(runtime_flag \"$helper_info\")\" = \"$(runtime_flag \"$app_info\")\" ] \\",
    ]

    /// Every violation in the release check's text: the helper is checked in
    /// both modes (before the mode branch), silently, with every rule, and
    /// before the ad-hoc refusal, which the release dry run needs to stay last.
    static func releaseCheckFailures(_ script: String) -> [String] {
        let code = codeLines(script)
        var failures: [String] = []
        if code.filter({ $0 == checkHelperPath }).count != 1 {
            failures.append("the helper path must be defined once as \(checkHelperPath)")
        }
        guard let body = functionBody(checkFunctionHead, in: script) else { return failures + ["no \(checkFunctionHead)"] }
        for rule in checkHelperRules where !body.contains(rule) {
            failures.append("the helper check lost: \(rule)")
        }
        if body.contains(where: { $0.hasPrefix("echo") }) {
            failures.append("the helper check must print nothing when it passes (the dry run compares whole outputs)")
        }
        let calls = code.indices.filter { code[$0] == checkCall }
        guard calls.count == 1, let call = calls.first,
              let branch = code.firstIndex(of: unentitledBranch), let refusal = code.firstIndex(of: adHocRefusal) else {
            return failures + ["one call of \(checkCall), the mode branch and the ad-hoc refusal must all exist"]
        }
        if !(call < branch && call < refusal) {
            failures.append("\(checkCall) must run before the mode branch and the ad-hoc refusal")
        }
        return failures
    }

    @Test func theReleaseCheckVerifiesTheHelperBeforeItsLastRefusal() throws {
        let script = try Self.read(Self.checkPath)
        let failures = Self.releaseCheckFailures(script)
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Canaries: the call dropped, moved past the ad-hoc refusal or into the
    /// entitled branch, a rule dropped, and a success line printed from the
    /// check.
    @Test func theReleaseCheckLockCatchesRegressionMutants() throws {
        let script = try Self.read(Self.checkPath)
        try #require(Self.releaseCheckFailures(script).isEmpty, "canary baseline must be clean")
        let callLine = "\n" + Self.checkCall + "\n"
        let lastLine = "echo \"check-release-entitlements: $APP is signed with exactly"
        var mutants: [(String, String)] = [
            ("call dropped", script.replacingOccurrences(of: callLine, with: "\n")),
            ("call moved past the ad-hoc refusal", script.replacingOccurrences(of: callLine, with: "\n")
                .replacingOccurrences(of: lastLine, with: Self.checkCall + "\n" + lastLine)),
            ("call moved into the entitled branch", script.replacingOccurrences(of: callLine, with: "\n")
                .replacingOccurrences(of: Self.adHocRefusal, with: Self.checkCall + "\n" + Self.adHocRefusal)),
            ("success printed", script.replacingOccurrences(
                of: Self.checkFunctionHead, with: Self.checkFunctionHead + "\n    echo \"helper ok\"")),
        ]
        for rule in Self.checkHelperRules {
            mutants.append(("rule dropped: \(rule)", script.replacingOccurrences(of: rule, with: "true \\")))
        }
        for (name, mutant) in mutants {
            #expect(mutant != script, "canary setup '\(name)': target text must exist")
            #expect(!Self.releaseCheckFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: - The two scripts keep the house guards

    static let callerPathCapture = "CALLER_PATH=\"$PATH\""
    /// The only way the caller's PATH is used: in the environment of Claude
    /// Code's own process, never assigned in this shell.
    static let callerEnvironment = "/usr/bin/env PATH=\"$CALLER_PATH\" "
    static let callerUses = [callerEnvironment + "/usr/bin/which claude", callerEnvironment + "\"$CLAUDE_BIN\" \"$@\""]
    /// Claude Code's configuration files and the shell profiles: never named.
    static let configNames = [".claude.json", "settings.json", ".claude/", "CLAUDE_CONFIG_DIR", ".zshrc", ".zprofile",
                              ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".bash_login", ".profile", "config.fish",
                              "launchctl setenv", "/etc/paths"]
    /// Where output may be redirected: nowhere, a standard stream, or the
    /// receipt's own temporary file.
    static let redirectTargets: Set<String> = ["/dev/null", "&1", "&2", "\"$RECEIPT_TMP\""]
    static let redirectPattern = #">+\s*(&[0-9]|"[^"]*"|[^\s;|)&]+)"#
    /// A command that changes files, at a command position.
    static let fileChangePattern = #"(^|[\s;&|('])(rm|rmdir|mv|cp|ln|install|chmod|chown|mkdir|mktemp|touch|tee|dd|truncate|ditto|rsync|sed\s+-i|plutil\s+-(replace|insert|remove|convert)|defaults\s+(write|delete|import))\s"#
    /// The only variables a file-changing line may name.
    static let fileChangeVariables: Set<String> = ["APPROVALS_DIR", "RECEIPT", "RECEIPT_TMP"]
    /// The three Claude Code commands the scripts may run, through `claude_cli` only.
    static let claudeCalls = [
        "claude_cli mcp get \"$SERVER_NAME\"",
        "claude_cli mcp remove \"$SERVER_NAME\" --scope user",
        "claude_cli mcp add --scope user --transport stdio \"$SERVER_NAME\" -- \"$HELPER\"",
    ]

    /// Every house-style violation in one channel script's text; empty ==
    /// locked. The first code lines are `set -euo pipefail`, the caller's
    /// PATH kept aside, the PATH pin and `umask 022`; PATH is assigned only by
    /// the pin and the caller's PATH only reaches Claude Code; nothing runs
    /// sudo; nothing names Claude Code's configuration or a shell profile,
    /// appends, or redirects anywhere but /dev/null, a standard stream or the
    /// receipt's temporary file; every file-changing line names only the
    /// receipt and its folder; and Claude Code runs only through `claude_cli`,
    /// with the three commands above.
    static func scriptGuardFailures(_ script: String) -> [String] {
        let code = codeLines(script)
        guard code.count >= 4 else { return ["fewer than four code lines (the lock would be vacuous)"] }
        var failures: [String] = []
        let head = ["set -euo pipefail", callerPathCapture, SetupScriptTests.pinnedPathLine, "umask 022"]
        if Array(code.prefix(4)) != head {
            failures.append("the first four code lines must be \(head), got \(Array(code.prefix(4)))")
        }
        let assignments = code.filter {
            matches($0.replacingOccurrences(of: callerEnvironment, with: ""), #"(^|[;&|\s(])(export\s+)?PATH="#)
        }
        if assignments != [SetupScriptTests.pinnedPathLine] {
            failures.append("PATH must be assigned exactly once, by the pin: \(assignments)")
        }
        for line in code where line.contains("CALLER_PATH") && line != callerPathCapture
            && !callerUses.contains(where: { line.contains($0) }) {
            failures.append("the caller's PATH may only find and run Claude Code: '\(line)'")
        }
        for line in code {
            if matches(line, #"(^|[^A-Za-z0-9_])sudo([^A-Za-z0-9_]|$)"#) { failures.append("sudo: '\(line)'") }
            for name in configNames where line.contains(name) { failures.append("names \(name): '\(line)'") }
            if line.contains(">>") { failures.append("appends: '\(line)'") }
            for target in captures(redirectPattern, in: line) where !redirectTargets.contains(target) {
                failures.append("redirects to \(target): '\(line)'")
            }
            if matches(line, fileChangePattern) {
                let named = Set(captures(#"\$\{?([A-Za-z_][A-Za-z0-9_]*)"#, in: line))
                if named.isEmpty || !named.isSubset(of: fileChangeVariables) || line.contains("~") {
                    failures.append("changes a file other than the receipt and its folder: '\(line)'")
                }
            }
            if matches(line, #"(^|[;&|(]|\bthen|\bdo|\belse)\s*claude\s"#) {
                failures.append("runs claude outside claude_cli: '\(line)'")
            }
            if line.contains("claude_cli "), !claudeCalls.contains(where: { line.contains($0) }) {
                failures.append("an unexpected Claude Code command: '\(line)'")
            }
            if line.contains("add-json") { failures.append("add-json: '\(line)'") }
        }
        // A use of "$CLAUDE_BIN" followed by anything but a test's `]` or a
        // `case … in` runs it: only claude_cli may.
        let runs = code.filter { line in
            captures(#""\$CLAUDE_BIN"\s+(\S+)"#, in: line).contains { !$0.hasPrefix("]") && $0 != "in" }
        }
        if runs.count != 1 || !runs[0].contains(callerUses[1]) {
            failures.append("Claude Code's binary runs only inside claude_cli: \(runs)")
        }
        return failures
    }

    @Test func bothChannelScriptsKeepTheHouseGuards() throws {
        for path in Self.scriptPaths {
            let failures = Self.scriptGuardFailures(try Self.read(path))
            #expect(failures.isEmpty, "\(path): \(failures)")
        }
    }

    /// Canaries, in BOTH scripts: each guard dropped or weakened, the
    /// caller's PATH put to other use, sudo, a profile edited, Claude Code's
    /// configuration edited or written through a variable, output redirected
    /// to a file, another Claude Code command, and Claude Code run bare or
    /// by its binary directly.
    @Test func theGuardLockCatchesRegressionMutants() throws {
        let anchor = "SERVER_NAME=\"napcat\"\n"
        let exit = "\nexit 0\n"
        for path in Self.scriptPaths {
            let original = try Self.read(path)
            try #require(Self.scriptGuardFailures(original).isEmpty, "\(path): canary baseline must be clean")
            let mutants: [(String, String)] = [
                ("set -e dropped", original.replacingOccurrences(of: "set -euo pipefail\n", with: "set -uo pipefail\n")),
                ("PATH pin dropped", original.replacingOccurrences(of: SetupScriptTests.pinnedPathLine + "\n", with: "")),
                ("PATH pin widened", original.replacingOccurrences(of: "PATH=/usr/bin:", with: "PATH=/usr/local/bin:/usr/bin:")),
                ("caller PATH appended to the pin", original.replacingOccurrences(
                    of: "/usr/sbin:/sbin; export PATH", with: "/usr/sbin:/sbin:$CALLER_PATH; export PATH")),
                ("umask dropped", original.replacingOccurrences(of: "\numask 022\n", with: "\n")),
                ("caller PATH restored", original.replacingOccurrences(of: anchor, with: "export PATH=\"$CALLER_PATH\"\n" + anchor)),
                ("claude run by a shell PATH assignment", original.replacingOccurrences(
                    of: "(cd / && /usr/bin/env PATH=\"$CALLER_PATH\" \"$CLAUDE_BIN\" \"$@\")",
                    with: "(cd / && PATH=\"$CALLER_PATH\" \"$CLAUDE_BIN\" \"$@\")")),
                ("caller PATH used for another tool", original.replacingOccurrences(
                    of: anchor, with: "/usr/bin/env PATH=\"$CALLER_PATH\" codesign -dv \"$0\"\n" + anchor)),
                ("sudo", original.replacingOccurrences(of: anchor, with: "sudo -v\n" + anchor)),
                ("profile appended", original.replacingOccurrences(
                    of: exit, with: "\necho \"alias claude='claude --flag'\" >> \"$HOME/.zshrc\"" + exit)),
                ("Claude config edited", original.replacingOccurrences(
                    of: exit, with: "\nsed -i '' 's/a/b/' \"$HOME/.claude.json\"" + exit)),
                ("config written through a variable", original.replacingOccurrences(
                    of: exit, with: "\ncp \"$RECEIPT\" \"$CONFIG_FILE\"" + exit)),
                ("output redirected to a file", original.replacingOccurrences(
                    of: exit, with: "\nprintf '%s' \"$SERVER_NAME\" > \"$OUT\"" + exit)),
                ("add-json", original.replacingOccurrences(
                    of: exit, with: "\nclaude_cli mcp add-json \"$SERVER_NAME\" '{}' > /dev/null" + exit)),
                ("a project-scope registration", original.replacingOccurrences(
                    of: exit, with: "\nclaude_cli mcp add --scope project \"$SERVER_NAME\" -- \"$HELPER\"" + exit)),
                ("claude run bare", original.replacingOccurrences(of: exit, with: "\nclaude mcp remove napcat" + exit)),
                ("claude's binary run directly", original.replacingOccurrences(
                    of: exit, with: "\n\"$CLAUDE_BIN\" mcp list > /dev/null" + exit)),
            ]
            for (name, mutant) in mutants {
                #expect(mutant != original, "\(path): canary setup '\(name)': target text must exist")
                #expect(!Self.scriptGuardFailures(mutant).isEmpty, "\(path): canary '\(name)' was NOT caught")
            }
        }
    }

    /// Over-match controls: what the lock must NOT flag.
    @Test func theGuardLockLetsTheHarmlessFormsThrough() {
        let base = ["set -euo pipefail", Self.callerPathCapture, SetupScriptTests.pinnedPathLine, "umask 022",
                    "CLAUDE_BIN=\"$(" + Self.callerUses[0] + " 2> /dev/null)\" || CLAUDE_BIN=\"\"",
                    "case \"$CLAUDE_BIN\" in", "/*) [ -x \"$CLAUDE_BIN\" ] || CLAUDE_BIN=\"\" ;;",
                    "if [ -z \"$CLAUDE_BIN\" ]; then", "(cd / && " + Self.callerUses[1] + ")"]
        let harmless = [
            "echo \"Undo with ./scripts/uninstall-channel.sh; the installer wrote it.\"",
            "echo \"    claude --dangerously-load-development-channels server:$SERVER_NAME\"",
            "die \"inspect it with: claude mcp get $SERVER_NAME\"",
            "echo \"usage: $0\" >&2",
            "found=\"$(sed -n 's/^x//p' <<< \"$output\")\"",
            "codesign -d --verbose=2 \"$HELPER\" 2>&1",
            "trap 'rm -f \"$RECEIPT_TMP\"' EXIT",
            "mkdir -p \"${APPROVALS_DIR%/*}\" || die \"cannot create ${APPROVALS_DIR%/*}.\"",
            "echo \"a .provisionprofile is not a shell profile\"",
        ]
        let script = (base + harmless).joined(separator: "\n") + "\n"
        #expect(Self.scriptGuardFailures(script).isEmpty, "\(Self.scriptGuardFailures(script))")
    }

    // MARK: - The scripts name what the app and the bundle name

    /// Every name the scripts share with the app or the bundle, and the
    /// functions both scripts must hold byte for byte.
    static func parityFailures(install: String, uninstall: String, check: String, makefile: String) -> [String] {
        var failures: [String] = []
        let definition = lines(makefile).first(where: { $0.hasPrefix("CHANNEL ") && $0.contains(" := ") })
        let channel = definition?.components(separatedBy: " := ").last ?? ""
        let shared = [
            "SERVER_NAME=\"\(ApprovalChannel.serverName)\"",
            "HELPER_IN_BUNDLE=\"Contents/MacOS/\(channel)\"",
            "APPROVALS_DIR=\"$HOME/\(SeamPaths.directoryRelativePath)\"",
            "RECEIPT=\"$APPROVALS_DIR/channel-registration\"",
            "?*.app) return 0 ;;",
            "NOT_FOUND_PREFIX=\"No MCP server named \\\"$SERVER_NAME\\\".\"",
        ]
        for (name, script) in [("install-channel.sh", install), ("uninstall-channel.sh", uninstall)] {
            let code = codeLines(script)
            for line in shared where code.filter({ $0 == line }).count != 1 {
                failures.append("\(name) must hold exactly one '\(line)'")
            }
        }
        if !codeLines(check).contains("HELPER=\"$APP/Contents/MacOS/\(channel)\"") {
            failures.append("the release check's helper path is not Contents/MacOS/\(channel)")
        }
        for head in ["claude_cli() {", "registered_command() {", "is_napcat_helper() {"] {
            let installed = functionBody(head, in: install)
            if installed == nil || installed != functionBody(head, in: uninstall) {
                failures.append("\(head) must be identical in both scripts")
            }
        }
        return failures
    }

    @Test func theScriptsNameWhatTheAppAndTheBundleName() throws {
        let failures = Self.parityFailures(install: try Self.read(Self.installPath), uninstall: try Self.read(Self.uninstallPath),
                                           check: try Self.read(Self.checkPath), makefile: try Self.read(Self.makefilePath))
        #expect(failures.isEmpty, "\(failures)")
        #expect(ApprovalChannel.serverName == "napcat" && SeamPaths.directoryRelativePath.hasSuffix("/approvals"),
                "vacuity: the values the scripts are held to")
    }

    @Test func theNameParityCatchesADrift() throws {
        let install = try Self.read(Self.installPath)
        let uninstall = try Self.read(Self.uninstallPath)
        let check = try Self.read(Self.checkPath)
        let makefile = try Self.read(Self.makefilePath)
        try #require(Self.parityFailures(install: install, uninstall: uninstall, check: check, makefile: makefile).isEmpty,
                     "canary baseline must be clean")
        let mutants: [(String, String, String)] = [
            ("server renamed in the installer", "SERVER_NAME=\"napcat\"", "SERVER_NAME=\"napcat-approvals\""),
            ("receipt moved", "RECEIPT=\"$APPROVALS_DIR/channel-registration\"", "RECEIPT=\"$APPROVALS_DIR/registration\""),
            ("approvals folder moved", "NapCat/approvals\"", "NapCat/channel\""),
            ("helper test loosened", "?*.app) return 0 ;;", "*.app) return 0 ;;"),
            ("helper test lets a dot-dot through", "*//* | */./* | */../*) return 1 ;;", "*//* | */./*) return 1 ;;"),
            ("claude_cli drifted", "(cd / && /usr/bin/env", "(cd \"$HOME\" && /usr/bin/env"),
            ("not-found line drifted", "NOT_FOUND_PREFIX=\"No MCP server named", "NOT_FOUND_PREFIX=\"No MCP server found with name"),
            ("registered_command drifted", "[ \"$status\" -eq 1 ] || return 1", "true"),
        ]
        for (name, target, replacement) in mutants {
            let mutant = install.replacingOccurrences(of: target, with: replacement)
            #expect(mutant != install, "canary setup '\(name)': target text must exist")
            #expect(!Self.parityFailures(install: mutant, uninstall: uninstall, check: check, makefile: makefile).isEmpty,
                    "canary '\(name)' was NOT caught")
        }
        let renamed = makefile.replacingOccurrences(of: Self.channelVariable, with: "CHANNEL            := napcat-relay")
        #expect(!Self.parityFailures(install: install, uninstall: uninstall, check: check, makefile: renamed).isEmpty,
                "the bundled helper renamed alone")
    }

    // MARK: - The installer verifies before anything; the uninstaller removes only NapCat's

    /// The installer's steps, in the order they must appear (and run: no
    /// step is in a function that runs earlier).
    static let installOrder = [
        "APP=\"$(cd -P -- \"$APP\" && pwd -P && echo .)\" || die \"cannot resolve $APP.\"",
        "APP=\"${APP%??}\"",
        "*[[:cntrl:]]*) die \"the bundle path contains a control character.\" ;;",
        "is_napcat_helper \"$HELPER\" || die \"$APP is not a bundle whose name ends in .app, as NapCat.app does. Nothing was registered.\"",
        "codesign --verify --strict \"$HELPER\" || die \"$HELPER fails codesign --verify --strict. Nothing was registered.\"",
        "grep -qxF \"Identifier=$CHANNEL_IDENTIFIER\" <<< \"$HELPER_SIGNATURE\" \\",
        "codesign --verify --strict \"$APP\" || die \"$APP fails codesign --verify --strict. Nothing was registered.\"",
        "[ \"$HELPER_TEAM\" = \"$APP_TEAM\" ] \\",
        "[ \"$APP_TEAM\" = \"$TEAM_IDENTIFIER\" ] \\",
        "codesign --verify --strict -R \"=identifier \\\"$CHANNEL_IDENTIFIER\\\" and $TEAM_REQUIREMENT\" \"$HELPER\" \\",
        "codesign --verify --strict -R \"=identifier \\\"$BUNDLE_IDENTIFIER\\\" and $TEAM_REQUIREMENT\" \"$APP\" \\",
        "FOUND_BUNDLE_IDENTIFIER=\"$(plutil -extract CFBundleIdentifier raw -o - \"$INFO_PLIST\" 2> /dev/null)\" || FOUND_BUNDLE_IDENTIFIER=\"\"",
        "CHANNEL_VERSION=\"$(plutil -extract NapCatChannelVersion raw -o - \"$INFO_PLIST\" 2> /dev/null)\" || CHANNEL_VERSION=\"\"",
        "[ ! -L \"$APPROVALS_DIR\" ] || die \"$APPROVALS_DIR is a symlink; refusing to write the receipt through it. Nothing was registered.\"",
        "if [ -L \"$APPROVALS_DIR\" ] || [ ! -d \"$APPROVALS_DIR\" ] || [ \"$(stat -f %u \"$APPROVALS_DIR\")\" != \"$(id -u)\" ]; then",
        "chmod 700 \"$APPROVALS_DIR\"",
        "if [ -L \"$RECEIPT\" ] || { [ -e \"$RECEIPT\" ] && [ ! -f \"$RECEIPT\" ]; }; then",
        "CURRENT=\"$(registered_command)\" \\",
        "claude_cli mcp add --scope user --transport stdio \"$SERVER_NAME\" -- \"$HELPER\" > /dev/null \\",
        "RECEIPT_TMP=\"$(mktemp \"$APPROVALS_DIR/.channel-registration.XXXXXXXX\")\"",
        "printf 'version=%s\\npath=%s\\n' \"$CHANNEL_VERSION\" \"$HELPER\" > \"$RECEIPT_TMP\"",
        "chmod 600 \"$RECEIPT_TMP\"",
        "mv -f \"$RECEIPT_TMP\" \"$RECEIPT\"",
        "echo \"    claude --dangerously-load-development-channels server:$SERVER_NAME\"",
    ]
    /// The uninstaller's registration branch: a NapCat helper the receipt
    /// records, or nothing; and the receipt kept while that branch failed.
    static let uninstallGuard = "elif ! is_napcat_helper \"$CURRENT\"; then"
    static let uninstallRecorded = "RECORDED=\"$(receipt_path)\" || RECORDED=\"\""
    static let uninstallReceiptGuard = "elif [ \"$RECORDED\" != \"$CURRENT\" ]; then"
    static let uninstallRemove = "elif claude_cli mcp remove \"$SERVER_NAME\" --scope user > /dev/null; then"
    static let uninstallKeep = "if [ -n \"$KEEP_RECEIPT\" ]; then"
    /// Each script reads the registration fail-safe: an unknown answer stops
    /// the installer and is an uninstall error, never an empty command.
    static let installRead = "CURRENT=\"$(registered_command)\" \\"
    static let installReadRefusal = "|| die \"cannot read the \\\"$SERVER_NAME\\\" entry: "
    static let uninstallRead = "elif ! CURRENT=\"$(registered_command)\"; then"
    static let uninstallReadFailure = "FAILURES+=(\"cannot read the \\\"$SERVER_NAME\\\" entry: "
    static let failOpenRead = "$(registered_command)\" || CURRENT=\"\""
    static let uninstallLink = "elif [ -L \"$RECEIPT\" ]; then"

    /// The index of the next `elif`/`else` of the `if` chain that holds
    /// `code[start]`, skipping any `if … fi` nested in between.
    static func nextBranch(after start: Int, in code: [String]) -> Int? {
        var depth = 0
        for index in code.indices where index > start {
            let line = code[index]
            if line.hasPrefix("if ") {
                depth += 1
            } else if line == "fi" {
                if depth == 0 { return nil }
                depth -= 1
            } else if depth == 0, line.hasPrefix("elif ") || line == "else" {
                return index
            }
        }
        return nil
    }

    static func stepFailures(install: String, uninstall: String) -> [String] {
        var failures: [String] = []
        let code = codeLines(install)
        let found = installOrder.map { step in code.indices.filter { code[$0] == step } }
        for (step, at) in zip(installOrder, found) where at.count != 1 {
            failures.append("install-channel.sh must hold '\(step)' exactly once, found \(at.count)")
        }
        let positions = found.compactMap { $0.count == 1 ? $0[0] : nil }
        if positions.count == installOrder.count, positions != positions.sorted() {
            failures.append("install-channel.sh: verify, read, check the receipt's folder, register, then the receipt and the flag: \(positions)")
        }
        let removal = codeLines(uninstall)
        let removes = removal.indices.filter { removal[$0].contains("claude_cli mcp remove") }
        // The removal is the branch right after the receipt's: past the
        // helper test, then the receipt match, with no other branch between.
        guard removes.count == 1, let remove = removes.first, removal[remove] == uninstallRemove,
              let recorded = removal.firstIndex(of: uninstallRecorded),
              let guardLine = removal.firstIndex(of: uninstallGuard), recorded < guardLine,
              removal[guardLine + 1].hasPrefix("echo "), removal[guardLine + 2] == uninstallReceiptGuard,
              nextBranch(after: guardLine + 2, in: removal) == remove else {
            return failures + ["uninstall-channel.sh must remove the registration once, only past \(uninstallGuard) and \(uninstallReceiptGuard)"]
        }
        if removal.contains(where: { $0.contains("rm -rf") || $0.contains("rmdir") }) {
            failures.append("uninstall-channel.sh removes only the receipt, never a folder")
        }
        if let read = code.firstIndex(of: installRead) {
            if read + 1 >= code.count || !code[read + 1].hasPrefix(installReadRefusal) {
                failures.append("install-channel.sh must stop when it cannot read the registration")
            }
        }
        let reads = removal.indices.filter { removal[$0] == uninstallRead }
        if reads.count != 1 || reads[0] + 2 >= removal.count || !removal[reads[0] + 1].hasPrefix(uninstallReadFailure)
            || removal[reads[0] + 2] != "KEEP_RECEIPT=1" {
            failures.append("uninstall-channel.sh must report an unreadable registration as an error and keep the receipt")
        }
        for (name, lines) in [("install-channel.sh", code), ("uninstall-channel.sh", removal)]
        where lines.contains(where: { $0.contains(failOpenRead) }) {
            failures.append("\(name) reads an unknown registration as none")
        }
        guard let keep = removal.firstIndex(of: uninstallKeep), let link = removal.firstIndex(of: uninstallLink),
              let receipt = removal.firstIndex(of: "if rm -f \"$RECEIPT\"; then"), keep < link, link < receipt else {
            return failures + ["uninstall-channel.sh must keep the receipt while a registration step failed, and refuse a symlinked one, before removing one"]
        }
        return failures
    }

    @Test func theInstallerVerifiesFirstAndTheUninstallerRemovesOnlyNapCats() throws {
        let failures = Self.stepFailures(install: try Self.read(Self.installPath), uninstall: try Self.read(Self.uninstallPath))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// The one step of `installOrder` that starts with `prefix`.
    static func step(_ prefix: String) -> String {
        let steps = installOrder.filter { $0.hasPrefix(prefix) }
        return steps.count == 1 ? steps[0] : "<\(steps.count) steps start with \(prefix)>"
    }

    /// Canaries: the bundle path resolved without its sentinel (a trailing
    /// newline lost), the bundle name check or the helper's verification
    /// dropped, the Info.plist read before the seal is checked, each team
    /// check dropped or moved past the registration, each receipt-folder
    /// guard, the folder's or the receipt's mode dropped, a folder or receipt
    /// guard moved past the registration, the receipt written before the
    /// registration, the flag line dropped; and
    /// an unguarded or a second removal, a folder removed, the receipt's
    /// symlink guard or match dropped, the receipt never read, or removed
    /// while a registration step failed.
    @Test func theStepLockCatchesRegressionMutants() throws {
        let install = try Self.read(Self.installPath)
        let uninstall = try Self.read(Self.uninstallPath)
        try #require(Self.stepFailures(install: install, uninstall: uninstall).isEmpty, "canary baseline must be clean")
        let verify = Self.step("codesign --verify --strict \"$HELPER\"") + "\n"
        let plistRead = Self.step("CHANNEL_VERSION=") + "\n"
        let teamMatch = Self.step("[ \"$HELPER_TEAM\"")
        let expectedTeam = Self.step("[ \"$APP_TEAM\"")
        let helperRequirement = Self.step("codesign --verify --strict -R \"=identifier \\\"$CHANNEL_IDENTIFIER")
        let appRequirement = Self.step("codesign --verify --strict -R \"=identifier \\\"$BUNDLE_IDENTIFIER")
        let add = Self.step("claude_cli mcp add ") + "\n"
        let current = Self.step("CURRENT=") + "\n"
        let receiptTemp = Self.step("RECEIPT_TMP=") + "\n"
        let installMutants: [(String, String)] = [
            ("the bundle path resolved without its sentinel", install.replacingOccurrences(
                of: Self.step("APP=\"$(cd -P") + "\n" + Self.step("APP=\"${APP%") + "\n",
                with: "APP=\"$(cd -P -- \"$APP\" && pwd -P)\" || die \"cannot resolve $APP.\"\n")),
            ("an unreadable registration read as none", install.replacingOccurrences(
                of: Self.installRead + "\n", with: "CURRENT=\"$(registered_command)\" || CURRENT=\"\"\n")),
            ("an unreadable registration let through", install.replacingOccurrences(
                of: Self.installRead + "\n", with: "CURRENT=\"$(registered_command)\" \\\n    || true\n")),
            ("bundle name check dropped", install.replacingOccurrences(of: Self.step("is_napcat_helper ") + "\n", with: "")),
            ("helper verification dropped", install.replacingOccurrences(of: verify, with: "")),
            ("Info.plist read before the seal", install.replacingOccurrences(of: plistRead, with: "")
                .replacingOccurrences(of: verify, with: plistRead + verify)),
            ("team match dropped", install.replacingOccurrences(of: teamMatch, with: "true \\")),
            ("expected team dropped", install.replacingOccurrences(of: expectedTeam, with: "true \\")),
            ("helper requirement dropped", install.replacingOccurrences(of: helperRequirement, with: "true \\")),
            ("app requirement dropped", install.replacingOccurrences(of: appRequirement, with: "true \\")),
            ("expected team checked after the registration", install.replacingOccurrences(of: expectedTeam + "\n", with: "")
                .replacingOccurrences(of: add, with: add + expectedTeam + "\n")),
            ("approvals symlink guard dropped", install.replacingOccurrences(of: Self.step("[ ! -L \"$APPROVALS_DIR\"") + "\n", with: "")),
            ("approvals ownership check dropped", install.replacingOccurrences(of: Self.step("if [ -L \"$APPROVALS_DIR\" ]"), with: "if false; then")),
            ("approvals mode dropped", install.replacingOccurrences(of: Self.step("chmod 700 ") + "\n", with: "")),
            ("receipt folder checked after the registration", install
                .replacingOccurrences(of: Self.step("[ ! -L \"$APPROVALS_DIR\"") + "\n", with: "")
                .replacingOccurrences(of: add, with: add + Self.step("[ ! -L \"$APPROVALS_DIR\"") + "\n")),
            ("receipt checked after the registration", install
                .replacingOccurrences(of: Self.step("if [ -L \"$RECEIPT\" ]") + "\n", with: "")
                .replacingOccurrences(of: add, with: add + Self.step("if [ -L \"$RECEIPT\" ]") + "\n")),
            ("receipt symlink guard dropped", install.replacingOccurrences(of: Self.step("if [ -L \"$RECEIPT\" ]"), with: "if false; then")),
            ("receipt mode dropped", install.replacingOccurrences(of: Self.step("chmod 600 ") + "\n", with: "")),
            ("receipt written before the registration", install.replacingOccurrences(of: receiptTemp, with: "")
                .replacingOccurrences(of: current, with: receiptTemp + current)),
            ("flag line dropped", install.replacingOccurrences(of: Self.step("echo \"    claude --dangerously") + "\n", with: "")),
        ]
        for (name, mutant) in installMutants {
            #expect(mutant != install, "canary setup '\(name)': target text must exist")
            #expect(!Self.stepFailures(install: mutant, uninstall: uninstall).isEmpty, "canary '\(name)' was NOT caught")
        }
        let uninstallMutants: [(String, String)] = [
            ("removal unguarded", uninstall.replacingOccurrences(of: Self.uninstallGuard, with: "elif false; then")),
            ("a second removal", uninstall.replacingOccurrences(
                of: "\nexit 0\n", with: "\nclaude_cli mcp remove \"$SERVER_NAME\" --scope user > /dev/null\nexit 0\n")),
            ("the folder removed", uninstall.replacingOccurrences(of: "\nexit 0\n", with: "\nrm -rf \"$APPROVALS_DIR\"\nexit 0\n")),
            ("receipt symlink guard dropped", uninstall.replacingOccurrences(of: Self.uninstallLink, with: "elif false; then")),
            ("receipt match dropped", uninstall.replacingOccurrences(of: Self.uninstallReceiptGuard, with: "elif false; then")),
            ("receipt never read", uninstall.replacingOccurrences(of: Self.uninstallRecorded, with: "RECORDED=\"$CURRENT\"")),
            ("receipt removed even when a step failed", uninstall.replacingOccurrences(of: Self.uninstallKeep, with: "if false; then")),
            ("an unreadable registration read as none", uninstall.replacingOccurrences(
                of: Self.uninstallRead, with: "elif false; then\nelse\nCURRENT=\"$(registered_command)\" || CURRENT=\"\"")),
            ("an unreadable registration not kept", uninstall.replacingOccurrences(
                of: Self.uninstallRead + "\n", with: Self.uninstallRead + "\n    KEEP_RECEIPT=\"\"\n")),
        ]
        for (name, mutant) in uninstallMutants {
            #expect(mutant != uninstall, "canary setup '\(name)': target text must exist")
            #expect(!Self.stepFailures(install: install, uninstall: mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }
}
