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
}
