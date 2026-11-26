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
}
