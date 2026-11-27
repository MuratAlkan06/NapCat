// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// #193: the two channel scripts, RUN, each time in a sandbox of its own
/// and never against this machine. A run executes a copy of the committed
/// script whose one changed line is the PATH pin, which gains the
/// sandbox's `tools` folder in front, so `codesign` (and `id` or `sed`, where
/// a test plants one) are stubs. HOME is the sandbox's own folder. The caller's
/// PATH is the sandbox's `bin`, holding a stub `claude` that records every
/// call and keeps its one registration in a file, followed by system
/// folders that hold no `claude`. Nothing here reads or writes the real
/// home, Claude Code's configuration, the real receipt or an installed
/// NapCat.app.
struct ChannelInstallScriptTests {
    // MARK: - The sandbox

    /// The values the scripts are checked against, from their sources: the
    /// committed entitlements' team and Info.plist's bundle identifier.
    static func committedPlist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: LidGuardStructureTests.repoRoot().appendingPathComponent(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    static func team() throws -> String {
        try #require(try committedPlist("Resources/NapCat.entitlements")["com.apple.developer.team-identifier"] as? String)
    }
    static func bundleIdentifier() throws -> String {
        try #require(try committedPlist(ChannelInstallStructureTests.infoPlistPath)["CFBundleIdentifier"] as? String)
    }

    enum Role: String { case app, helper }

    /// What Apple's certificate chain proves about a signature: what its
    /// description claims, with a Developer ID Application certificate;
    /// nothing (ad-hoc or self-signed); this identifier and team, with a
    /// Developer ID Application certificate; or what its description
    /// claims, with an Apple Development certificate.
    enum Anchor { case claimed, unproven, proven(String, String), appleDevelopment }

    /// A stub `claude`: each call is one `<cwd>|<arguments>` line in
    /// claude/calls, and the registration's command is claude/registered.
    /// `mcp get` answers in Claude Code 2.1.326's format (a stdio entry's
    /// lines, or its not-found line on stderr with status 1) unless the test
    /// scripts an answer in claude/get-*.
    static let claudeStub = #"""
    #!/bin/bash
    set -u
    state="$NAPCAT_TEST_SANDBOX/claude"
    printf '%s|%s\n' "$PWD" "$*" >> "$state/calls"
    registered="$state/registered"
    if [ "$#" -eq 3 ] && [ "$*" = "mcp get napcat" ]; then
        if [ -f "$state/get-status" ]; then
            if [ -f "$state/get-stdout" ]; then cat "$state/get-stdout"; fi
            if [ -f "$state/get-stderr" ]; then cat "$state/get-stderr" >&2; fi
            exit "$(cat "$state/get-status")"
        fi
        if [ -f "$registered" ]; then
            printf 'napcat:\n  Scope: User config (available in all your projects)\n  Status: \342\234\223 Connected\n  Type: stdio\n  Command: %s\n  Args: \n\nTo remove this server, run: claude mcp remove "napcat" -s user\n' "$(cat "$registered")"
            exit 0
        fi
        echo 'No MCP server named "napcat". Run `claude mcp add` to add one.' >&2
        exit 1
    fi
    if [ "$#" -eq 9 ] && [ "$1 $2 $3 $4 $5 $6 $7 $8" = "mcp add --scope user --transport stdio napcat --" ]; then
        if [ -f "$state/add-fails" ] || [ -f "$registered" ]; then
            echo 'MCP server napcat already exists in user config' >&2
            exit 1
        fi
        printf '%s' "$9" > "$registered"
        echo "Added stdio MCP server napcat with command: $9 to user config"
        exit 0
    fi
    if [ "$#" -eq 5 ] && [ "$*" = "mcp remove napcat --scope user" ]; then
        if [ -f "$state/remove-fails" ] || [ ! -f "$registered" ]; then
            echo 'No user-scoped MCP server found with name: napcat' >&2
            exit 1
        fi
        rm -f "$registered"
        echo 'Removed MCP server napcat from user config'
        exit 0
    fi
    echo "claude stub: unexpected call: $*" >&2
    exit 99

    """#

    /// A stub `codesign`: answers for the app or its helper from
    /// codesign/<role>-*, and records each call (and each requirement).
    /// <role>-anchor stands for what Apple's certificate chain proves,
    /// "<identifier> <team> <certificate>", where <certificate> is
    /// developer-id (a Developer ID Application leaf, issued by the
    /// Developer ID Certification Authority) or development; with no such
    /// file (an ad-hoc or self-signed build) every requirement fails,
    /// status 3, as codesign's does. A requirement holds when each of its
    /// "and" clauses does; a clause the stub does not know fails it.
    static let codesignStub = #"""
    #!/bin/bash
    set -u
    fixtures="$NAPCAT_TEST_SANDBOX/codesign"
    printf '%s\n' "$*" >> "$fixtures/calls"
    case "${!#}" in
        */Contents/MacOS/napcat-channel) role=helper ;;
        *) role=app ;;
    esac
    if [ "$#" -eq 3 ] && [ "$1 $2" = "--verify --strict" ]; then
        exit "$(cat "$fixtures/$role-verify")"
    fi
    if [ "$#" -eq 3 ] && [ "$1 $2" = "-d --verbose=2" ]; then
        cat "$fixtures/$role-description" >&2
        exit 0
    fi
    if [ "$#" -eq 5 ] && [ "$1 $2 $3" = "--verify --strict -R" ]; then
        printf '%s\n' "$4" >> "$fixtures/requirements"
        [ -f "$fixtures/$role-anchor" ] || exit 3
        read -r identifier team certificate < "$fixtures/$role-anchor"
        rest="${4#=}"
        while :; do
            clause="${rest%% and *}"
            case "$clause" in
                "identifier \"$identifier\"" | "anchor apple generic" | "certificate leaf[subject.OU] = \"$team\"") ;;
                "certificate 1[field.1.2.840.113635.100.6.2.6] exists" | "certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
                    [ "$certificate" = "developer-id" ] || exit 3 ;;
                *) exit 3 ;;
            esac
            [ "$clause" != "$rest" ] || exit 0
            rest="${rest#* and }"
        done
    fi
    echo "codesign stub: unexpected call: $*" >&2
    exit 2

    """#

    /// A stub `id`: `id -u` prints the sandbox's id-u file; anything else
    /// runs the real one.
    static let idStub = #"""
    #!/bin/bash
    if [ "$#" -eq 1 ] && [ "$1" = "-u" ]; then
        cat "$NAPCAT_TEST_SANDBOX/id-u"
        exit 0
    fi
    exec /usr/bin/id "$@"

    """#

    /// One sandbox: a NapCat.app (the committed Info.plist, a helper file),
    /// signed for NapCat's team by default; a home; the stubs. Removed when
    /// the test lets go of it.
    final class Sandbox {
        let root: String
        let team: String
        let bundleIdentifier: String
        var home: String { root + "/home" }
        var bin: String { root + "/bin" }
        var tools: String { root + "/tools" }
        var app: String { root + "/Apps/NapCat.app" }
        var helper: String { app + "/" + ChannelInstallScriptTests.helperInBundle }
        var approvals: String { home + "/Library/Application Support/NapCat/approvals" }
        var receipt: String { approvals + "/channel-registration" }

        init() throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("napcat-channel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            // The physical path, as the installer's `pwd -P` prints it.
            guard let resolved = realpath(made.path, nil) else { throw CocoaError(.fileNoSuchFile) }
            root = String(cString: resolved)
            free(resolved)
            team = try ChannelInstallScriptTests.team()
            bundleIdentifier = try ChannelInstallScriptTests.bundleIdentifier()
            for folder in [home, bin, tools, root + "/claude", root + "/codesign", app + "/Contents/MacOS"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try write(bin + "/claude", ChannelInstallScriptTests.claudeStub, mode: 0o755)
            try write(tools + "/codesign", ChannelInstallScriptTests.codesignStub, mode: 0o755)
            try write(app + "/Contents/Info.plist",
                      try ChannelInstallStructureTests.read(ChannelInstallStructureTests.infoPlistPath))
            try write(helper, "#!/bin/sh\nexit 0\n", mode: 0o755)
            for role in [Role.app, .helper] {
                try sign(role, team: team)
            }
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }

        /// The same, for bytes that need not be UTF-8.
        func write(_ path: String, bytes: Data) throws {
            try bytes.write(to: URL(fileURLWithPath: path))
        }

        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        func identifier(_ role: Role) -> String {
            role == .app ? bundleIdentifier : bundleIdentifier + ".channel"
        }

        /// Signs `role` in the stub's eyes. `team` is the TeamIdentifier its
        /// description names (nil: "not set"); `teamLines` replaces that
        /// line outright; `anchor` is what Apple's chain proves.
        func sign(_ role: Role, team: String?, teamLines: [String]? = nil, anchor: Anchor = .claimed) throws {
            let lines = teamLines ?? ["TeamIdentifier=" + (team ?? "not set")]
            let development: Bool
            if case .appleDevelopment = anchor { development = true } else { development = false }
            let authority = team.map { team in
                development
                    ? ["Authority=Apple Development: NapCat Test Signer (TESTDEV123)",
                       "Authority=Apple Worldwide Developer Relations Certification Authority", "Authority=Apple Root CA"]
                    : ["Authority=Developer ID Application: NapCat Test Signer (\(team))",
                       "Authority=Developer ID Certification Authority", "Authority=Apple Root CA"]
            } ?? ["Signature=adhoc"]
            let description = ["Executable=" + (role == .app ? app + "/Contents/MacOS/NapCat" : helper),
                               "Identifier=" + identifier(role), "Format=Mach-O thin (arm64)",
                               "CodeDirectory v=20500 size=1000 flags=0x10000(runtime) hashes=20+7 location=embedded"]
                + authority + lines
            try write(root + "/codesign/\(role.rawValue)-description", description.joined(separator: "\n") + "\n")
            try write(root + "/codesign/\(role.rawValue)-verify", "0\n")
            let proven: (String, String, String)?
            switch anchor {
            case .claimed: proven = team.map { (identifier(role), $0, "developer-id") }
            case .unproven: proven = nil
            case let .proven(identifier, team): proven = (identifier, team, "developer-id")
            case .appleDevelopment: proven = team.map { (identifier(role), $0, "development") }
            }
            let anchorPath = root + "/codesign/\(role.rawValue)-anchor"
            if let proven {
                try write(anchorPath, "\(proven.0) \(proven.1) \(proven.2)\n")
            } else {
                try? FileManager.default.removeItem(atPath: anchorPath)
            }
        }

        /// Puts a registration named "napcat" in the stub's configuration.
        func register(_ command: String) throws { try write(root + "/claude/registered", command) }
        var registered: String? { read(root + "/claude/registered") }

        /// Every claude call: (working folder, arguments).
        var claudeCalls: [(cwd: String, arguments: String)] {
            (read(root + "/claude/calls") ?? "").split(separator: "\n").map { line in
                let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        }
        var claudeArguments: [String] { claudeCalls.map(\.arguments) }
        var codesignCalls: [String] { (read(root + "/codesign/calls") ?? "").split(separator: "\n").map(String.init) }
        var requirements: [String] { (read(root + "/codesign/requirements") ?? "").split(separator: "\n").map(String.init) }

        struct Run {
            let status: Int32
            let stdout: String
            let stderr: String
            var lines: [String] { stdout.components(separatedBy: "\n") }
            var errors: [String] { stderr.components(separatedBy: "\n").filter { !$0.isEmpty } }
        }

        /// Runs a copy of scripts/<name> whose PATH pin gains `tools` in
        /// front: the only line changed. `environment` adds to the child's
        /// (a locale).
        func run(_ name: String, _ arguments: [String] = [], environment: [String: String] = [:]) throws -> Run {
            let original = try ChannelInstallStructureTests.read("scripts/" + name)
            let pin = SetupScriptTests.pinnedPathLine
            try #require(original.components(separatedBy: pin).count == 2, "\(name) must hold exactly one PATH pin")
            let copy = root + "/" + name
            try write(copy, original.replacingOccurrences(of: pin, with: "PATH=\(tools):" + pin.dropFirst("PATH=".count)),
                      mode: 0o755)
            try #require(home.hasPrefix(root + "/") && home != NSHomeDirectory(), "the sandbox's home is never the real one")
            for system in ["/usr/bin/claude", "/bin/claude"] {
                try #require(!FileManager.default.fileExists(atPath: system), "\(system) would stand in for the stub")
            }
            let out = root + "/stdout", err = root + "/stderr"
            for file in [out, err] { try write(file, "") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [copy] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin", "NAPCAT_TEST_SANDBOX": root]
                .merging(environment) { _, added in added }
            process.standardInput = FileHandle.nullDevice
            let outHandle = try #require(FileHandle(forWritingAtPath: out))
            let errHandle = try #require(FileHandle(forWritingAtPath: err))
            defer {
                try? outHandle.close()
                try? errHandle.close()
            }
            process.standardOutput = outHandle
            process.standardError = errHandle
            try process.run()
            process.waitUntilExit()
            return Run(status: process.terminationStatus, stdout: read(out) ?? "", stderr: read(err) ?? "")
        }

        /// The installer's run for this sandbox's bundle.
        func install(environment: [String: String] = [:]) throws -> Run {
            try run("install-channel.sh", [app], environment: environment)
        }
        func uninstall(environment: [String: String] = [:]) throws -> Run {
            try run("uninstall-channel.sh", environment: environment)
        }
    }

    static let helperInBundle = "Contents/MacOS/napcat-channel"
    static let mcpGet = "mcp get napcat"
    static let mcpRemove = "mcp remove napcat --scope user"
    static func mcpAdd(_ helper: String) -> String { "mcp add --scope user --transport stdio napcat -- " + helper }

    static func registeredLine(_ helper: String) -> String { "registered: \"napcat\" at user scope, running \(helper)" }
    static func unchangedLine(_ helper: String) -> String {
        "ok:         \"napcat\" already runs \(helper) (user scope); registration unchanged."
    }

    /// A refusal before anything: status 1, one error line holding
    /// `fragment`, and no claude call, receipt or approvals folder.
    static func expectRefusedBeforeAnything(_ run: Sandbox.Run, _ sandbox: Sandbox, _ fragment: String,
                                            _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run.status == 1, "\(name): status \(run.status)", sourceLocation: sourceLocation)
        #expect(run.errors.count == 1 && run.errors.first?.hasPrefix("install-channel: error: ") == true,
                "\(name): one error line, got \(run.errors)", sourceLocation: sourceLocation)
        #expect(run.stderr.contains(fragment), "\(name): the error must say '\(fragment)', got \(run.errors)",
                sourceLocation: sourceLocation)
        #expect(sandbox.claudeCalls.isEmpty, "\(name): Claude Code was called: \(sandbox.claudeArguments)",
                sourceLocation: sourceLocation)
        #expect(!sandbox.exists(sandbox.home + "/Library"), "\(name): the approvals folder was created",
                sourceLocation: sourceLocation)
        #expect(sandbox.registered == nil, "\(name): something was registered", sourceLocation: sourceLocation)
    }

    // MARK: - The happy path, twice

    /// Run 1 registers and writes the receipt; run 2 prints the unchanged
    /// line (the owner's second run on 2026-11-26) and calls only `mcp get`.
    /// Both run Claude Code from `/`.
    @Test func aSignedCopyRegistersOnceAndTheSecondRunChangesNothing() throws {
        let sandbox = try Sandbox()
        let first = try sandbox.install()
        #expect(first.status == 0, "run 1: \(first.errors)")
        #expect(first.lines.contains(Self.registeredLine(sandbox.helper)), "run 1: \(first.lines)")
        let version = try #require(try Self.committedPlist(ChannelInstallStructureTests.infoPlistPath)["NapCatChannelVersion"] as? Int)
        #expect(first.lines.contains("receipt:    \(sandbox.receipt) (0600; channel version \(version))"), "run 1: \(first.lines)")
        #expect(first.lines.contains("    claude --dangerously-load-development-channels server:napcat"))
        #expect(sandbox.registered == sandbox.helper)
        #expect(sandbox.read(sandbox.receipt) == "version=\(version)\npath=\(sandbox.helper)\n")
        let receiptMode = try FileManager.default.attributesOfItem(atPath: sandbox.receipt)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: sandbox.approvals)[.posixPermissions] as? Int
        #expect(receiptMode == 0o600 && folderMode == 0o700, "receipt \(String(describing: receiptMode)), folder \(String(describing: folderMode))")
        #expect(sandbox.claudeArguments == [Self.mcpGet, Self.mcpAdd(sandbox.helper)])

        let second = try sandbox.install()
        #expect(second.status == 0, "run 2: \(second.errors)")
        #expect(second.lines.contains(Self.unchangedLine(sandbox.helper)), "run 2: \(second.lines)")
        #expect(!second.lines.contains { $0.hasPrefix("registered:") || $0.hasPrefix("removed:") }, "run 2: \(second.lines)")
        #expect(sandbox.claudeArguments == [Self.mcpGet, Self.mcpAdd(sandbox.helper), Self.mcpGet])
        #expect(sandbox.claudeCalls.allSatisfy { $0.cwd == "/" }, "Claude Code runs from /: \(sandbox.claudeCalls.map(\.cwd))")
        #expect(sandbox.registered == sandbox.helper && sandbox.read(sandbox.receipt) == "version=\(version)\npath=\(sandbox.helper)\n")
    }

    /// The uninstaller undoes it, and a second run finds nothing to undo.
    @Test func theUninstallerUndoesTheInstallAndASecondRunFindsNothing() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        let first = try sandbox.uninstall()
        #expect(first.status == 0, "\(first.errors)")
        #expect(first.lines.contains("removed: the \"napcat\" registration (user scope) for \(sandbox.helper)"), "\(first.lines)")
        #expect(first.lines.contains("removed: \(sandbox.receipt)"), "\(first.lines)")
        #expect(sandbox.registered == nil && !sandbox.exists(sandbox.receipt))
        #expect(sandbox.exists(sandbox.approvals), "the approvals folder stays: it is NapCat's seam folder too")

        let second = try sandbox.uninstall()
        #expect(second.status == 0, "\(second.errors)")
        #expect(second.lines.contains("ok: no \"napcat\" registration; nothing to remove"), "\(second.lines)")
        #expect(second.lines.contains("ok: \(sandbox.receipt) not present; nothing to remove"), "\(second.lines)")
        #expect(Array(sandbox.claudeArguments.suffix(3)) == [Self.mcpGet, Self.mcpRemove, Self.mcpGet])
    }

    /// Root is refused before anything, by both scripts.
    @Test func bothScriptsRefuseRootBeforeAnything() throws {
        let sandbox = try Sandbox()
        try sandbox.write(sandbox.tools + "/id", Self.idStub, mode: 0o755)
        try sandbox.write(sandbox.root + "/id-u", "0\n")
        let install = try sandbox.install()
        Self.expectRefusedBeforeAnything(install, sandbox, "run this as yourself, not as root", "install as root")
        #expect(sandbox.codesignCalls.isEmpty, "nothing was verified either: \(sandbox.codesignCalls)")
        try sandbox.register(sandbox.helper)
        let uninstall = try sandbox.uninstall()
        #expect(uninstall.status == 1 && uninstall.stderr.contains("not as root"), "\(uninstall.errors)")
        #expect(sandbox.claudeCalls.isEmpty && sandbox.registered == sandbox.helper)
    }

    // MARK: - The team

    /// Every way the app and its helper can fail to be NapCat's team's: no
    /// team, a different team on either side, the same other team on both,
    /// a malformed team line, and a description that claims the team while
    /// Apple's chain proves another (or no) team, or another identifier.
    /// Each is refused before Claude Code is called or a folder is made,
    /// naming what differed, without printing codesign's description.
    @Test func aBuildNotSignedForNapCatsTeamIsRefusedBeforeAnything() throws {
        let other = "ABCDE12345"
        let probe = try Sandbox()
        let (app, helper, team) = (probe.app, probe.helper, probe.team)
        let noTeam = "no team (an ad-hoc or unsigned build)"
        typealias Signing = (Sandbox) throws -> Void
        let cases: [(String, Signing, String)] = [
            ("both ad-hoc", { try $0.sign(.app, team: nil); try $0.sign(.helper, team: nil) },
             "\(app) and its helper are signed for \(noTeam), not NapCat's team \(team). Nothing was registered."),
            ("helper ad-hoc", { try $0.sign(.helper, team: nil) },
             "\(helper) is signed for \(noTeam), but \(app) for team \(team). Nothing was registered."),
            ("app ad-hoc", { try $0.sign(.app, team: nil) },
             "\(helper) is signed for team \(team), but \(app) for \(noTeam). Nothing was registered."),
            ("helper from another team", { try $0.sign(.helper, team: other) },
             "\(helper) is signed for team \(other), but \(app) for team \(team). Nothing was registered."),
            ("app from another team", { try $0.sign(.app, team: other) },
             "\(helper) is signed for team \(team), but \(app) for team \(other). Nothing was registered."),
            ("both from another team", { try $0.sign(.app, team: other); try $0.sign(.helper, team: other) },
             "\(app) and its helper are signed for team \(other), not NapCat's team \(team). Nothing was registered."),
            ("no team line on the app", { try $0.sign(.app, team: team, teamLines: []) },
             "\(helper) is signed for team \(team), but \(app) for \(noTeam). Nothing was registered."),
            ("a lower-case team", { try $0.sign(.helper, team: team, teamLines: ["TeamIdentifier=" + team.lowercased()]) },
             "codesign names a malformed team for \(helper). Nothing was registered."),
            ("two team lines", { try $0.sign(.app, team: team, teamLines: ["TeamIdentifier=" + team, "TeamIdentifier=" + other]) },
             "codesign names a malformed team for \(app). Nothing was registered."),
            ("helper claims the team, self-signed", { try $0.sign(.helper, team: team, anchor: .unproven) },
             "\(helper) is not signed as \(probe.identifier(.helper)) with a Developer ID Application certificate Apple issued to team \(team)."),
            ("app claims the team, Apple proves another", { try $0.sign(.app, team: team, anchor: .proven(probe.identifier(.app), other)) },
             "\(app) is not signed as \(probe.identifier(.app)) with a Developer ID Application certificate Apple issued to team \(team)."),
            ("helper proven for the team under another identifier",
             { try $0.sign(.helper, team: team, anchor: .proven(probe.identifier(.app), team)) },
             "\(helper) is not signed as \(probe.identifier(.helper)) with a Developer ID Application certificate Apple issued to team \(team)."),
        ]
        for (name, signing, error) in cases {
            let sandbox = try Sandbox()
            try signing(sandbox)
            // The sandboxes differ only in their root; the messages name the probe's paths.
            let run = try sandbox.install()
            let expected = error.replacingOccurrences(of: probe.root, with: sandbox.root)
            Self.expectRefusedBeforeAnything(run, sandbox, expected, name)
            #expect(!run.stderr.contains("Authority=") && !run.stderr.contains("NapCat Test Signer"),
                    "\(name): codesign's description was printed")
        }
    }

    /// Teeth for the case above: the same fixtures, signed for the team,
    /// pass; so each refusal is the team's, not the stubs'.
    @Test func theTeamCasesPassOnceSignedForTheTeam() throws {
        let sandbox = try Sandbox()
        try sandbox.sign(.app, team: nil)
        #expect(try sandbox.install().status == 1)
        try sandbox.sign(.app, team: sandbox.team)
        let run = try sandbox.install()
        #expect(run.status == 0 && run.lines.contains(Self.registeredLine(sandbox.helper)), "\(run.errors)")
    }

    /// Only a Developer ID signature registers: the app, the helper or
    /// both signed with an Apple Development certificate of NapCat's own
    /// team, for their own identifiers, are refused before anything, naming
    /// the first one that failed and not printing codesign's description.
    /// The same sandbox, signed with Developer ID, registers (teeth).
    @Test func anAppleDevelopmentBuildOfNapCatsTeamIsRefusedBeforeAnything() throws {
        let cases: [(String, [Role], Role)] = [("the helper", [.helper], .helper), ("the app", [.app], .app),
                                               ("both", [.app, .helper], .helper)]
        for (name, roles, refused) in cases {
            let sandbox = try Sandbox()
            for role in roles {
                try sandbox.sign(role, team: sandbox.team, anchor: .appleDevelopment)
            }
            let run = try sandbox.install()
            let path = refused == .app ? sandbox.app : sandbox.helper
            Self.expectRefusedBeforeAnything(run, sandbox, "\(path) is not signed as \(sandbox.identifier(refused)) with a "
                                             + "Developer ID Application certificate Apple issued to team \(sandbox.team). "
                                             + "Nothing was registered.", name)
            #expect(!run.stderr.contains("Authority=") && !run.stderr.contains("NapCat Test Signer"),
                    "\(name): codesign's description was printed")
            for role in roles {
                try sandbox.sign(role, team: sandbox.team)
            }
            let signed = try sandbox.install()
            #expect(signed.status == 0 && signed.lines.contains(Self.registeredLine(sandbox.helper)), "\(name): \(signed.errors)")
        }
    }

    /// The two requirements the installer passes compile for the REAL
    /// codesign: an Apple-signed binary of another team fails them with
    /// status 3 ("does not satisfy"), not 1 (a syntax error, which every
    /// signature would fail, the owner's included).
    @Test func theRequirementsTheInstallerPassesCompileForTheRealCodesign() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        let requirements = sandbox.requirements
        let team = sandbox.team
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        #expect(requirements == [
            "=identifier \"\(sandbox.identifier(.helper))\" and " + developerID,
            "=identifier \"\(sandbox.identifier(.app))\" and " + developerID,
        ], "\(requirements)")
        func realStatus(_ requirement: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--strict", "-R", requirement, "/usr/bin/true"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for requirement in requirements {
            #expect(try realStatus(requirement) == 3, "\(requirement) must compile, and not fit /usr/bin/true")
        }
        #expect(try realStatus("=anchor apple generic and and") == 1, "vacuity: a syntax error is status 1")
    }

    // MARK: - Which command is a NapCat copy's helper

    /// The test #193 replaced: any absolute path ending in
    /// .app/Contents/MacOS/napcat-channel.
    static let looseHelperTest = """
        is_napcat_helper() {
            case "$1" in
                /*.app/"$HELPER_IN_BUNDLE") return 0 ;;
                *) return 1 ;;
            esac
        }
        """

    /// Commands the loose test took for a NapCat copy's helper, and the new
    /// one does not: a "..", "." or empty component, a bundle named just
    /// ".app", and control characters (a tab, a terminal escape).
    static let looselyShapedHelpers = [
        "/Users/someone/../other/NapCat.app/Contents/MacOS/napcat-channel",
        "/../NapCat.app/Contents/MacOS/napcat-channel",
        "/Users/someone/./NapCat.app/Contents/MacOS/napcat-channel",
        "//NapCat.app/Contents/MacOS/napcat-channel",
        "/Users//someone/NapCat.app/Contents/MacOS/napcat-channel",
        "/Users/someone/.app/Contents/MacOS/napcat-channel",
        "/.app/Contents/MacOS/napcat-channel",
        "/Users/someone/Nap\tCat.app/Contents/MacOS/napcat-channel",
        "/Users/someone/Nap\u{1B}[2KCat.app/Contents/MacOS/napcat-channel",
    ]
    /// Both tests take these.
    static let napcatHelpers = [
        "/Applications/NapCat.app/Contents/MacOS/napcat-channel",
        "/NapCat.app/Contents/MacOS/napcat-channel",
        "/Users/someone/Apps/NapCat copy.app/Contents/MacOS/napcat-channel",
        "/Volumes/Backup/x.app/Contents/MacOS/napcat-channel",
    ]
    /// Neither test takes these.
    static let otherCommands = [
        "", "napcat-channel", "NapCat.app/Contents/MacOS/napcat-channel",
        "/Applications/NapCat/Contents/MacOS/napcat-channel",
        "/Applications/NapCat.APP/Contents/MacOS/napcat-channel",
        "/Applications/NapCat.app/Contents/MacOS/napcat-channel2",
        "/Applications/NapCat.app/Contents/MacOS/napcat-channel/",
        "/Applications/NapCat.app/Contents/Resources/napcat-channel",
        "/usr/local/bin/napcat-channel", "/usr/bin/env",
    ]

    /// Status of `function` (an `is_napcat_helper` text) on one command,
    /// in a bare bash, under `locale` if one is given: 0 = a NapCat copy's
    /// helper.
    static func helperTestStatus(_ function: String, _ command: String, locale: String? = nil) throws -> Int32 {
        try functionStatus(function, "is_napcat_helper", command, locale: locale)
    }

    /// Status of the shell function `name`, as `text` defines it, on one
    /// argument, the same way.
    static func functionStatus(_ text: String, _ name: String, _ argument: String, locale: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "HELPER_IN_BUNDLE=\"\(helperInBundle)\"\n" + text + "\n\(name) \"$1\"", name, argument]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(locale.map { ["LANG": $0] } ?? [:]) { _, added in added }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The installer's own `is_napcat_helper` (the uninstaller's is the same
    /// text, ChannelInstallStructureTests) takes exactly the shape the
    /// installer registers; the loose test it replaced took every one of the
    /// loosely shaped commands (teeth).
    @Test func onlyTheShapeTheInstallerRegistersIsANapCatHelper() throws {
        let install = try ChannelInstallStructureTests.read(ChannelInstallStructureTests.installPath)
        let function = try #require(ChannelInstallStructureTests.functionBody("is_napcat_helper() {", in: install))
            .joined(separator: "\n")
        for command in Self.looselyShapedHelpers {
            #expect(try Self.helperTestStatus(function, command) == 1, "\(String(reflecting: command)) is taken")
            #expect(try Self.helperTestStatus(Self.looseHelperTest, command) == 0,
                    "vacuity: the loose test took \(String(reflecting: command))")
        }
        for command in Self.napcatHelpers {
            #expect(try Self.helperTestStatus(function, command) == 0, "\(String(reflecting: command)) is refused")
        }
        for command in Self.otherCommands {
            #expect(try Self.helperTestStatus(function, command) == 1, "\(String(reflecting: command)) is taken")
            #expect(try Self.helperTestStatus(Self.looseHelperTest, command) == 1, "vacuity: \(String(reflecting: command))")
        }
    }

    /// A "napcat" entry whose command is loosely shaped is another server:
    /// the installer stops, removes nothing, adds nothing, writes no
    /// receipt. The same entry with a well-shaped other copy is replaced.
    @Test func aLooselyShapedRegistrationIsAnotherServerAndIsLeftAlone() throws {
        for command in Self.looselyShapedHelpers {
            let sandbox = try Sandbox()
            try sandbox.register(command)
            let run = try sandbox.install()
            #expect(run.status == 1, "\(String(reflecting: command)): status \(run.status)")
            #expect(run.stderr.contains("another MCP server is registered as \"napcat\"; it was left alone and nothing was registered."),
                    "\(String(reflecting: command)): \(run.errors)")
            #expect(sandbox.claudeArguments == [Self.mcpGet], "\(String(reflecting: command)): \(sandbox.claudeArguments)")
            #expect(sandbox.registered == command && !sandbox.exists(sandbox.receipt))
        }
        let sandbox = try Sandbox()
        let other = "/Applications/NapCat.app/Contents/MacOS/napcat-channel"
        try sandbox.register(other)
        let run = try sandbox.install()
        #expect(run.status == 0, "\(run.errors)")
        #expect(run.lines.contains("removed:    the registration for another NapCat copy, \(other)"), "\(run.lines)")
        #expect(run.lines.contains(Self.registeredLine(sandbox.helper)), "\(run.lines)")
        #expect(sandbox.claudeArguments == [Self.mcpGet, Self.mcpRemove, Self.mcpAdd(sandbox.helper)])
        #expect(sandbox.registered == sandbox.helper)
    }

    /// A bundle whose name does not end in .app would be registered at a
    /// path neither script takes for NapCat's: refused before anything.
    @Test func aBundleNotNamedDotAppIsRefusedBeforeAnything() throws {
        for name in ["NapCat", ".app", "NapCat.app.bak"] {
            let sandbox = try Sandbox()
            let bundle = sandbox.root + "/Apps/" + name
            try FileManager.default.moveItem(atPath: sandbox.app, toPath: bundle)
            let run = try sandbox.run("install-channel.sh", [bundle])
            Self.expectRefusedBeforeAnything(run, sandbox, "\(bundle) is not a bundle whose name ends in .app, as NapCat.app does. Nothing was registered.", name)
            #expect(sandbox.codesignCalls.isEmpty, "\(name): nothing was verified either")
        }
    }

    /// A bundle name that ends in a newline is refused by the control-
    /// character test, by both routes that once lost the newline (command
    /// substitution drops trailing newlines, so the path resolved to its
    /// sibling, a symlink to the real bundle that was never tested as one):
    /// the name itself, and a symlink to it given as `<link>/.`. Each is
    /// refused before anything, with no `mcp add`; the plain path to the
    /// same bundle, in the same sandbox, still registers.
    @Test func aBundleNameEndingInANewlineIsRefusedBeforeAnything() throws {
        for route in ["the name itself", "a symlink to it, as <link>/."] {
            let sandbox = try Sandbox()
            let folder = sandbox.root + "/drop"
            let named = folder + "/NapCat.app\n"
            try FileManager.default.createDirectory(atPath: named, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: folder + "/NapCat.app", withDestinationPath: sandbox.app)
            try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: named)
            let path = route == "the name itself" ? named : folder + "/link/."
            let run = try sandbox.run("install-channel.sh", [path])
            Self.expectRefusedBeforeAnything(run, sandbox, "the bundle path contains a control character.", route)
            #expect(!sandbox.claudeArguments.contains { $0.hasPrefix("mcp add") }, "\(route): \(sandbox.claudeArguments)")
            #expect(sandbox.codesignCalls.isEmpty, "\(route): nothing was verified either")
            let plain = try sandbox.install()
            #expect(plain.status == 0 && plain.lines.contains(Self.registeredLine(sandbox.helper)), "\(route): \(plain.errors)")
            #expect(sandbox.registered == sandbox.helper, "\(route): the plain path")
        }
    }

    // MARK: - The receipt's folder is checked before anything is registered

    /// Every receipt-folder refusal comes before Claude Code is called, so
    /// it leaves no registration behind (before #193 these checks ran after
    /// `mcp add`): a symlinked approvals folder, one that is a file, one
    /// that is not the user's (an `id` stub makes the user someone else),
    /// and a receipt that is a symlink or a folder. Nothing is written
    /// through the link either.
    @Test func aRefusedReceiptFolderLeavesNoRegistrationBehind() throws {
        typealias Setup = (Sandbox) throws -> Void
        let parent = { (sandbox: Sandbox) in sandbox.approvals.components(separatedBy: "/").dropLast().joined(separator: "/") }
        let cases: [(String, Setup, (Sandbox) -> String)] = [
            ("a symlinked folder", { sandbox in
                try FileManager.default.createDirectory(atPath: parent(sandbox), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: sandbox.root + "/elsewhere", withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: sandbox.approvals, withDestinationPath: sandbox.root + "/elsewhere")
            }, { "\($0.approvals) is a symlink; refusing to write the receipt through it. Nothing was registered." }),
            ("a file where the folder goes", { sandbox in
                try FileManager.default.createDirectory(atPath: parent(sandbox), withIntermediateDirectories: true)
                try sandbox.write(sandbox.approvals, "")
            }, { "cannot create \($0.approvals). Nothing was registered." }),
            ("a folder that is not the user's", { sandbox in
                try sandbox.write(sandbox.tools + "/id", Self.idStub, mode: 0o755)
                try sandbox.write(sandbox.root + "/id-u", "\(getuid() + 4242)\n")
            }, { "\($0.approvals) is not a directory of yours; refusing to write the receipt there. Nothing was registered." }),
            ("a symlinked receipt", { sandbox in
                try FileManager.default.createDirectory(atPath: sandbox.approvals, withIntermediateDirectories: true)
                try sandbox.write(sandbox.root + "/elsewhere", "")
                try FileManager.default.createSymbolicLink(atPath: sandbox.receipt, withDestinationPath: sandbox.root + "/elsewhere")
            }, { "\($0.receipt) is a symlink or not a regular file; refusing to write through it. Nothing was registered." }),
            ("a folder where the receipt goes", { sandbox in
                try FileManager.default.createDirectory(atPath: sandbox.receipt, withIntermediateDirectories: true)
            }, { "\($0.receipt) is a symlink or not a regular file; refusing to write through it. Nothing was registered." }),
        ]
        for (name, setup, error) in cases {
            let sandbox = try Sandbox()
            try setup(sandbox)
            let run = try sandbox.install()
            #expect(run.status == 1, "\(name): status \(run.status)")
            #expect(run.errors.last == "install-channel: error: " + error(sandbox), "\(name): \(run.errors)")
            #expect(sandbox.claudeCalls.isEmpty, "\(name): Claude Code was called: \(sandbox.claudeArguments)")
            #expect(!sandbox.claudeArguments.contains { $0.hasPrefix("mcp add") } && sandbox.registered == nil,
                    "\(name): a registration was left behind")
            #expect(!sandbox.exists(sandbox.root + "/elsewhere/channel-registration")
                    && (sandbox.read(sandbox.root + "/elsewhere").map(\.isEmpty) ?? true), "\(name): written through the link")
        }
    }

    /// An approvals folder that exists with a wider mode is forced to 0700.
    @Test func anExistingApprovalsFolderIsForcedPrivate() throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(atPath: sandbox.approvals, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        #expect(try sandbox.install().status == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.approvals)[.posixPermissions] as? Int
        #expect(mode == 0o700, "\(String(describing: mode))")
    }

    // MARK: - The uninstaller removes only what the receipt records

    /// A NapCat helper the receipt does not record is left alone and
    /// reported, status 1, with the command that removes it: no receipt, a
    /// receipt naming another copy, one with no path line or two, an empty
    /// one, and a symlink to a receipt that does record it. The receipt, if
    /// any, is kept, so a later run can still match it.
    @Test func aRegistrationTheReceiptDoesNotRecordIsLeftAloneAndReported() throws {
        typealias Receipt = (Sandbox) throws -> Void
        let cases: [(String, Receipt, String)] = [
            ("no receipt", { _ in }, "but no readable receipt records it"),
            ("another copy's receipt", { try $0.write($0.receipt, "version=2\npath=/Applications/NapCat.app/Contents/MacOS/napcat-channel\n") },
             "but the receipt records /Applications/NapCat.app/Contents/MacOS/napcat-channel"),
            ("no path line", { try $0.write($0.receipt, "version=2\n") }, "but no readable receipt records it"),
            ("two path lines", { try $0.write($0.receipt, "version=2\npath=\($0.helper)\npath=\($0.helper)\n") },
             "but no readable receipt records it"),
            ("an empty receipt", { try $0.write($0.receipt, "") }, "but no readable receipt records it"),
            ("a symlinked receipt", { sandbox in
                let real = sandbox.root + "/elsewhere"
                try sandbox.write(real, "version=2\npath=\(sandbox.helper)\n")
                try FileManager.default.createSymbolicLink(atPath: sandbox.receipt, withDestinationPath: real)
            }, "but no readable receipt records it"),
        ]
        for (name, receipt, reason) in cases {
            let sandbox = try Sandbox()
            try FileManager.default.createDirectory(atPath: sandbox.approvals, withIntermediateDirectories: true)
            try sandbox.register(sandbox.helper)
            try receipt(sandbox)
            let before = sandbox.exists(sandbox.receipt)
            let run = try sandbox.uninstall()
            #expect(run.status == 1, "\(name): status \(run.status)")
            #expect(run.stderr.contains("left alone: \"napcat\" runs \(sandbox.helper), \(reason)"), "\(name): \(run.errors)")
            #expect(run.stderr.contains("remove it with: claude mcp remove napcat --scope user"), "\(name): \(run.errors)")
            #expect(!sandbox.claudeArguments.contains(Self.mcpRemove), "\(name): \(sandbox.claudeArguments)")
            #expect(sandbox.registered == sandbox.helper, "\(name): the registration was removed")
            #expect(sandbox.exists(sandbox.receipt) == before, "\(name): the receipt must be kept")
            #expect(!before || run.lines.contains("kept: \(sandbox.receipt), for the registration step reported below"),
                    "\(name): \(run.lines)")
        }
    }

    /// The uninstaller prints the receipt's recorded path only in the one
    /// shape the installer writes: any other recorded path (another
    /// command, a terminal escape inside or after a helper path) is named
    /// by a fixed phrase instead. A well-shaped other copy is still named
    /// (teeth). Each is left alone, status 1, with the receipt kept.
    @Test func aRecordedPathIsPrintedOnlyInTheShapeTheInstallerWrites() throws {
        let shaped = "/Applications/NapCat.app/Contents/MacOS/napcat-channel"
        let odd = ["/usr/local/bin/other-server", "/Users/someone/Nap\u{1B}]0;title\u{07}Cat.app/Contents/MacOS/napcat-channel",
                   shaped + "\u{1B}[2K"]
        for recorded in odd + [shaped] {
            let name = String(reflecting: recorded)
            let sandbox = try Sandbox()
            try FileManager.default.createDirectory(atPath: sandbox.approvals, withIntermediateDirectories: true)
            try sandbox.register(sandbox.helper)
            try sandbox.write(sandbox.receipt, "version=2\npath=\(recorded)\n")
            let run = try sandbox.uninstall()
            #expect(run.status == 1, "\(name): status \(run.status)")
            let left = "left alone: \"napcat\" runs \(sandbox.helper), but the receipt records "
            if recorded == shaped {
                #expect(run.stderr.contains(left + shaped + "; if it is yours"), "\(name): \(run.errors)")
            } else {
                #expect(run.stderr.contains(left + "a path that is not a NapCat helper's (not shown); if it is yours, remove it "
                                            + "with: claude mcp remove napcat --scope user"), "\(name): \(run.errors)")
                #expect(!(run.stdout + run.stderr).contains(recorded) && !(run.stdout + run.stderr).contains("\u{1B}"),
                        "\(name) was printed")
            }
            #expect(!sandbox.claudeArguments.contains(Self.mcpRemove) && sandbox.registered == sandbox.helper, "\(name)")
            #expect(sandbox.exists(sandbox.receipt), "\(name): the receipt must be kept")
        }
    }

    /// A symlinked approvals folder, which the installer refuses, is never
    /// read or cleared through: a receipt behind the link that records the
    /// registered helper does not get it removed, and is neither read nor
    /// deleted, with a registration or without one. Each run reports the
    /// folder, status 1.
    @Test func aSymlinkedApprovalsFolderIsNeitherReadNorClearedThrough() throws {
        for registered in [true, false] {
            let name = registered ? "registered" : "nothing registered"
            let sandbox = try Sandbox()
            let elsewhere = sandbox.root + "/elsewhere"
            let parent = sandbox.approvals.components(separatedBy: "/").dropLast().joined(separator: "/")
            for folder in [elsewhere, parent] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(atPath: sandbox.approvals, withDestinationPath: elsewhere)
            let receipt = "version=2\npath=\(sandbox.helper)\n"
            try sandbox.write(elsewhere + "/channel-registration", receipt)
            if registered {
                try sandbox.register(sandbox.helper)
            }
            let run = try sandbox.uninstall()
            #expect(run.status == 1, "\(name): status \(run.status)")
            #expect(run.stderr.contains("\(sandbox.approvals) is a symlink, which the installer refuses; no receipt was read or "
                                        + "removed through it, check it by hand"), "\(name): \(run.errors)")
            #expect(sandbox.read(elsewhere + "/channel-registration") == receipt, "\(name): the receipt behind the link changed")
            #expect(!sandbox.claudeArguments.contains(Self.mcpRemove), "\(name): \(sandbox.claudeArguments)")
            #expect(!run.lines.contains { $0.hasPrefix("kept: ") || $0.hasPrefix("removed: ") || $0.hasPrefix("Done.") },
                    "\(name): \(run.lines)")
            if registered {
                #expect(sandbox.registered == sandbox.helper, "the registration was removed")
                #expect(run.stderr.contains("left alone: \"napcat\" runs \(sandbox.helper), but no readable receipt records it"),
                        "\(run.errors)")
            }
        }
    }

    /// The receipt is kept whenever the registration may still be there: no
    /// claude on the PATH, and a removal Claude Code refused. A later run
    /// with both fixed removes the registration and the receipt.
    @Test func theReceiptIsKeptWhileTheRegistrationMayRemain() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        try FileManager.default.moveItem(atPath: sandbox.bin + "/claude", toPath: sandbox.root + "/claude-away")
        let missing = try sandbox.uninstall()
        #expect(missing.status == 1 && missing.stderr.contains("cannot find the claude command on your PATH"), "\(missing.errors)")
        #expect(sandbox.exists(sandbox.receipt) && sandbox.registered == sandbox.helper)
        try FileManager.default.moveItem(atPath: sandbox.root + "/claude-away", toPath: sandbox.bin + "/claude")
        try sandbox.write(sandbox.root + "/claude/remove-fails", "")
        let refused = try sandbox.uninstall()
        #expect(refused.status == 1 && refused.stderr.contains("could not remove the \"napcat\" registration for \(sandbox.helper)"),
                "\(refused.errors)")
        #expect(sandbox.exists(sandbox.receipt) && sandbox.registered == sandbox.helper)
        try FileManager.default.removeItem(atPath: sandbox.root + "/claude/remove-fails")
        let fixed = try sandbox.uninstall()
        #expect(fixed.status == 0, "\(fixed.errors)")
        #expect(!sandbox.exists(sandbox.receipt) && sandbox.registered == nil)
    }

    /// The uninstaller's own is_napcat_helper, run (the parity lock holds
    /// its text to the installer's): a "napcat" entry whose command is
    /// loosely shaped is another server, left alone with status 0, even
    /// when the receipt records that same command. Nothing is removed, and
    /// the command is not printed.
    @Test func theUninstallerLeavesALooselyShapedRegistrationAlone() throws {
        for command in Self.looselyShapedHelpers {
            let name = String(reflecting: command)
            let sandbox = try Sandbox()
            try FileManager.default.createDirectory(atPath: sandbox.approvals, withIntermediateDirectories: true)
            try sandbox.register(command)
            try sandbox.write(sandbox.receipt, "version=2\npath=\(command)\n")
            let run = try sandbox.uninstall()
            #expect(run.status == 0, "\(name): status \(run.status), \(run.errors)")
            #expect(run.lines.contains("left alone: the server registered as \"napcat\" does not run a NapCat helper"), "\(name): \(run.lines)")
            #expect(!sandbox.claudeArguments.contains(Self.mcpRemove) && sandbox.registered == command,
                    "\(name): \(sandbox.claudeArguments)")
            #expect(!(run.stdout + run.stderr).contains(command), "\(name): the command was printed")
        }
    }

    /// Another server named "napcat" is left alone, status 0 (it is not the
    /// installer's), and NapCat's own receipt, which no longer names the
    /// registration, is removed.
    @Test func anotherServerIsLeftAloneByTheUninstaller() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        try sandbox.register("/usr/local/bin/some-server")
        let run = try sandbox.uninstall()
        #expect(run.status == 0, "\(run.errors)")
        #expect(run.lines.contains("left alone: the server registered as \"napcat\" does not run a NapCat helper"), "\(run.lines)")
        #expect(!run.stdout.contains("/usr/local/bin/some-server"), "another server's command is never printed")
        #expect(!sandbox.claudeArguments.contains(Self.mcpRemove) && sandbox.registered == "/usr/local/bin/some-server")
        #expect(!sandbox.exists(sandbox.receipt))
    }

    // MARK: - An answer the scripts do not recognise changes nothing

    /// Scripts the stub's next `mcp get` answers.
    static func script(_ sandbox: Sandbox, status: Int32, stdout: String = "", stderr: String = "") throws {
        try sandbox.write(sandbox.root + "/claude/get-status", "\(status)\n")
        try sandbox.write(sandbox.root + "/claude/get-stdout", stdout)
        try sandbox.write(sandbox.root + "/claude/get-stderr", stderr)
    }

    static let secret = "napcat-test-secret-7f3a"

    /// `mcp get` answers neither script was written for: a server that is
    /// not a stdio server (with a secret in its settings), two Command:
    /// lines, a renamed Command: line, another not-found wording, the
    /// not-found line after or before another line or under another status,
    /// a colored not-found line, no answer at all, and a claude that cannot
    /// start.
    static let unrecognisedAnswers: [(String, Int32, String, String)] = [
        ("an http server", 0, "napcat:\n  Scope: User config (available in all your projects)\n  Status: \u{2713} Connected\n  Type: http\n"
            + "  URL: https://example.invalid/mcp\n  Headers:\n    Authorization: Bearer \(secret)\n", ""),
        ("two Command: lines", 0, "napcat:\n  Type: stdio\n  Command: /Applications/NapCat.app/Contents/MacOS/napcat-channel\n"
            + "  Environment:\n    Command: /tmp/x=\(secret)\n", ""),
        ("Command: renamed", 0, "napcat:\n  Type: stdio\n  Command line: /Applications/NapCat.app/Contents/MacOS/napcat-channel\n", ""),
        ("another not-found wording", 1, "", "MCP server napcat not found\n"),
        ("the not-found line after another", 1, "", "Warning: \(secret)\nNo MCP server named \"napcat\". Run `claude mcp add` to add one.\n"),
        ("the not-found line before another", 1, "", "No MCP server named \"napcat\". Run `claude mcp add` to add one.\nWarning: \(secret)\n"),
        ("the not-found line under status 2", 2, "", "No MCP server named \"napcat\". Run `claude mcp add` to add one.\n"),
        ("a colored not-found line", 1, "", "\u{1B}[31mNo MCP server named \"napcat\". Run `claude mcp add` to add one.\u{1B}[39m\n"),
        ("no answer at all", 1, "", ""),
        ("a claude that cannot start", 127, "", "env: node: No such file or directory\n"),
    ]

    /// The installer refuses rather than risk a second registration: it
    /// calls only `mcp get`, adds and removes nothing, writes no receipt,
    /// and prints none of the answer.
    @Test func anUnrecognisedAnswerStopsTheInstallerWithNothingChanged() throws {
        for (name, status, stdout, stderr) in Self.unrecognisedAnswers {
            let sandbox = try Sandbox()
            try Self.script(sandbox, status: status, stdout: stdout, stderr: stderr)
            let run = try sandbox.install()
            #expect(run.status == 1, "\(name): status \(run.status)")
            #expect(run.errors == ["install-channel: error: cannot read the \"napcat\" entry: claude mcp get answered in a way "
                                   + "this script does not recognise (a server that is not a stdio server, or a newer Claude Code's "
                                   + "format). Nothing was registered or removed. Inspect it with: claude mcp get napcat"],
                    "\(name): \(run.errors)")
            #expect(sandbox.claudeArguments == [Self.mcpGet], "\(name): \(sandbox.claudeArguments)")
            #expect(sandbox.registered == nil && !sandbox.exists(sandbox.receipt), "\(name)")
            #expect(!(run.stdout + run.stderr).contains(Self.secret) && !run.stdout.contains("example.invalid"),
                    "\(name): the answer was printed")
        }
    }

    /// The uninstaller reports an error, status 1, rather than "nothing to
    /// remove": it removes nothing, keeps the receipt, and prints none of
    /// the answer.
    @Test func anUnrecognisedAnswerIsAnUninstallErrorNotSuccess() throws {
        for (name, status, stdout, stderr) in Self.unrecognisedAnswers {
            let sandbox = try Sandbox()
            #expect(try sandbox.install().status == 0, "\(name): setup")
            try Self.script(sandbox, status: status, stdout: stdout, stderr: stderr)
            let run = try sandbox.uninstall()
            #expect(run.status == 1, "\(name): status \(run.status)")
            #expect(run.stderr.contains("uninstall-channel finished WITH ERRORS"), "\(name): \(run.errors)")
            #expect(run.stderr.contains("cannot read the \"napcat\" entry: claude mcp get answered in a way this script does not "
                                        + "recognise"), "\(name): \(run.errors)")
            #expect(!run.lines.contains { $0.hasPrefix("ok: no ") || $0.hasPrefix("Done.") }, "\(name): \(run.lines)")
            #expect(!sandbox.claudeArguments.contains(Self.mcpRemove) && sandbox.registered == sandbox.helper, "\(name)")
            #expect(sandbox.exists(sandbox.receipt) && run.lines.contains("kept: \(sandbox.receipt), for the registration step reported below"),
                    "\(name): \(run.lines)")
            #expect(!(run.stdout + run.stderr).contains(Self.secret), "\(name): the answer was printed")
        }
    }

    /// That error names the command that removes the entry by hand, as the
    /// uninstaller's other left-alone errors do.
    @Test func theUnreadableEntryErrorNamesTheCommandThatRemovesIt() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        let (_, status, stdout, stderr) = Self.unrecognisedAnswers[0]
        try Self.script(sandbox, status: status, stdout: stdout, stderr: stderr)
        let run = try sandbox.uninstall()
        #expect(run.status == 1, "status \(run.status)")
        #expect(run.errors.contains("  - cannot read the \"napcat\" entry: claude mcp get answered in a way this script does not "
                                    + "recognise (a server that is not a stdio server, or a newer Claude Code's format); nothing "
                                    + "was removed. Inspect it with: claude mcp get napcat; if it runs a NapCat helper you "
                                    + "registered, remove it with: claude mcp remove napcat --scope user"), "\(run.errors)")
    }

    /// Claude Code 2.1.326's not-found line, whatever hint follows it (the
    /// hint may name other servers), alone on its status-1 answer: no
    /// registration. The installer registers; the uninstaller has nothing
    /// to remove. Neither prints the hint.
    @Test func theNotFoundLineIsReadWhateverItsHint() throws {
        let hints = ["Did you mean \"napcat2\"? Run `claude mcp list` to see all.", "Configured servers: alpha-server, beta-server",
                     "Run `claude mcp add` to add one."]
        for hint in hints {
            let line = "No MCP server named \"napcat\". " + hint
            let sandbox = try Sandbox()
            try Self.script(sandbox, status: 1, stderr: "\n" + line + "\n\n")
            let uninstall = try sandbox.uninstall()
            #expect(uninstall.status == 0 && uninstall.lines.contains("ok: no \"napcat\" registration; nothing to remove"),
                    "\(hint): \(uninstall.lines) \(uninstall.errors)")
            let install = try sandbox.install()
            #expect(install.status == 0 && install.lines.contains(Self.registeredLine(sandbox.helper)), "\(hint): \(install.errors)")
            #expect(sandbox.claudeArguments == [Self.mcpGet, Self.mcpGet, Self.mcpAdd(sandbox.helper)], "\(hint)")
            for output in [uninstall, install] {
                #expect(!(output.stdout + output.stderr).contains(hint), "\(hint): the hint was printed")
            }
        }
    }

    // MARK: - Every locale reads the same

    /// The locales the locale tests run both scripts under: C, and the
    /// UTF-8 locale a Mac's Terminal sets, in which sed stops at the first
    /// byte that is not UTF-8 ("illegal byte sequence").
    static let locales = ["C", "en_US.UTF-8"]
    static func environment(_ locale: String) -> [String: String] { ["LANG": locale] }

    /// A byte that is never UTF-8.
    static let badByte = Data([0xFF])
    static func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// Scripts the stub's next `mcp get` answers, in bytes.
    static func script(_ sandbox: Sandbox, status: Int32, stdout: Data, stderr: Data) throws {
        try sandbox.write(sandbox.root + "/claude/get-status", "\(status)\n")
        try sandbox.write(sandbox.root + "/claude/get-stdout", bytes: stdout)
        try sandbox.write(sandbox.root + "/claude/get-stderr", bytes: stderr)
    }

    /// What `locale` does in a child bash on this Mac: "<characters in é>
    /// <whether a sed regex reads a line holding badByte>". The C locale
    /// counts two and reads it; the UTF-8 one counts one and fails.
    static func localeProbe(_ locale: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", #"printf '\xff\n' | /usr/bin/sed -n 's/^[[:space:]]*x//p' > /dev/null 2>&1 && sed=reads || sed=fails; "#
                             + #"s=$'\xc3\xa9'; printf '%s %s' "${#s}" "$sed""#]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": locale]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// The two answers a UTF-8 locale once read short, because the scripts
    /// used what sed had printed before it stopped at a byte that is not
    /// UTF-8: two Command: lines with such a byte between them (read as one
    /// Command: line), and the not-found line with such a line after it
    /// (read as the not-found line alone).
    static func answersWithABadByte(_ helper: String) -> [(name: String, status: Int32, stdout: Data, stderr: Data)] {
        [("two Command: lines", 0, bytes("napcat:\n  Type: stdio\n  Command: \(helper)\n  Environment:\n    X=") + badByte
            + bytes("\n  Command: \(helper)\n"), Data()),
         ("the not-found line and another", 1, Data(),
          bytes("No MCP server named \"napcat\". Run `claude mcp add` to add one.\n") + badByte + bytes(" warning\n"))]
    }

    /// Both answers are unknown in every locale: the installer stops, with
    /// only `mcp get` called (no `mcp add`, no `mcp remove`) and nothing
    /// written; the uninstaller exits 1, removes nothing and keeps the
    /// receipt. Each names the helper the sandbox would register, the case
    /// a short read took for "unchanged" or for no registration.
    @Test func anAnswerWithAByteThatIsNotUTF8ChangesNothingInEveryLocale() throws {
        let (utf8, c) = (try Self.localeProbe("en_US.UTF-8"), try Self.localeProbe("C"))
        #expect(utf8 == "1 fails" && c == "2 reads", "vacuity: the UTF-8 locale reaches a child bash, and its sed stops at the byte")
        for locale in Self.locales {
            for shape in Self.answersWithABadByte("").indices {
                let install = try Sandbox()
                let answer = Self.answersWithABadByte(install.helper)[shape]
                let name = "\(locale), \(answer.name)"
                try Self.script(install, status: answer.status, stdout: answer.stdout, stderr: answer.stderr)
                let installed = try install.install(environment: Self.environment(locale))
                #expect(installed.status == 1, "\(name): installer status \(installed.status)")
                #expect(installed.errors.count == 1 && installed.stderr.contains("install-channel: error: cannot read the \"napcat\" "
                                                                                 + "entry: claude mcp get answered in a way this script "
                                                                                 + "does not recognise"), "\(name): \(installed.errors)")
                #expect(install.claudeArguments == [Self.mcpGet], "\(name): \(install.claudeArguments)")
                #expect(install.registered == nil && !install.exists(install.receipt), "\(name): the installer wrote something")

                let uninstall = try Sandbox()
                #expect(try uninstall.install().status == 0, "\(name): setup")
                let registered = Self.answersWithABadByte(uninstall.helper)[shape]
                try Self.script(uninstall, status: registered.status, stdout: registered.stdout, stderr: registered.stderr)
                let run = try uninstall.uninstall(environment: Self.environment(locale))
                #expect(run.status == 1, "\(name): uninstaller status \(run.status)")
                #expect(run.stderr.contains("cannot read the \"napcat\" entry: claude mcp get answered in a way this script does not "
                                            + "recognise"), "\(name): \(run.errors)")
                #expect(!run.lines.contains { $0.hasPrefix("ok: no ") || $0.hasPrefix("removed: ") || $0.hasPrefix("Done.") },
                        "\(name): \(run.lines)")
                #expect(!uninstall.claudeArguments.contains(Self.mcpRemove) && uninstall.registered == uninstall.helper,
                        "\(name): \(uninstall.claudeArguments)")
                #expect(uninstall.exists(uninstall.receipt)
                        && run.lines.contains("kept: \(uninstall.receipt), for the registration step reported below"),
                        "\(name): the receipt must be kept: \(run.lines)")
            }
        }
    }

    /// Teeth: input the scripts act on, with a byte that is not UTF-8
    /// where it changes nothing, reads the same in every locale (a UTF-8
    /// sed stopped at it): codesign descriptions with it in a line before
    /// TeamIdentifier register; a stdio entry with it in the line before
    /// Command: is unchanged; a receipt with a line holding it still
    /// records the path, so the uninstaller removes both; and the not-found
    /// line with it in its hint is no registration.
    @Test func aByteThatIsNotUTF8ElsewhereReadsTheSameInEveryLocale() throws {
        for locale in Self.locales {
            let environment = Self.environment(locale)
            let signed = try Sandbox()
            for role in [Role.app, .helper] {
                let path = signed.root + "/codesign/\(role.rawValue)-description"
                let description = try #require(signed.read(path))
                try signed.write(path, bytes: Self.bytes("Authority=NapCat ") + Self.badByte + Self.bytes("\n" + description))
            }
            let first = try signed.install(environment: environment)
            #expect(first.status == 0 && first.lines.contains(Self.registeredLine(signed.helper)), "\(locale), signature: \(first.errors)")

            let answered = try Sandbox()
            #expect(try answered.install(environment: environment).status == 0, "\(locale): setup")
            try Self.script(answered, status: 0,
                            stdout: Self.bytes("napcat:\n  Scope: User config (available in all your projects)\n  Status: ") + Self.badByte
                                + Self.bytes(" Connected\n  Type: stdio\n  Command: \(answered.helper)\n  Args: \n"), stderr: Data())
            let again = try answered.install(environment: environment)
            #expect(again.status == 0 && again.lines.contains(Self.unchangedLine(answered.helper)), "\(locale), stdio entry: \(again.errors)")
            let receipt = try #require(answered.read(answered.receipt))
            try answered.write(answered.receipt, bytes: Self.bytes(receipt + "note=") + Self.badByte + Self.bytes("\n"))
            let removed = try answered.uninstall(environment: environment)
            #expect(removed.status == 0 && removed.lines.contains("removed: \(answered.receipt)")
                    && removed.lines.contains("removed: the \"napcat\" registration (user scope) for \(answered.helper)"),
                    "\(locale), receipt: \(removed.lines) \(removed.errors)")
            try Self.script(answered, status: 1, stdout: Data(),
                            stderr: Self.bytes("No MCP server named \"napcat\". Did you mean \"nap") + Self.badByte + Self.bytes("\"?\n"))
            let none = try answered.uninstall(environment: environment)
            #expect(none.status == 0 && none.lines.contains("ok: no \"napcat\" registration; nothing to remove"),
                    "\(locale), not-found line: \(none.lines) \(none.errors)")
            let added = try answered.install(environment: environment)
            #expect(added.status == 0 && added.lines.contains(Self.registeredLine(answered.helper)), "\(locale), not-found line: \(added.errors)")
            #expect(answered.claudeArguments == [Self.mcpGet, Self.mcpAdd(answered.helper), Self.mcpGet, Self.mcpGet, Self.mcpRemove,
                                                 Self.mcpGet, Self.mcpGet, Self.mcpAdd(answered.helper)], "\(locale): \(answered.claudeArguments)")
        }
    }

    /// A stub `sed` that does its work, then fails when its input holds
    /// "napcat-test-sed-fails".
    static let failingSedStub = #"""
    #!/bin/bash
    input="$(/bin/cat; echo .)"
    input="${input%.}"
    printf '%s' "$input" | /usr/bin/sed "$@" || exit
    case "$input" in
        *napcat-test-sed-fails*) exit 2 ;;
    esac

    """#

    /// A sed that fails while it reads stops the read with nothing
    /// changed, even when what it printed looks whole: a stdio entry naming
    /// this helper and the not-found line stop the installer (only `mcp
    /// get` called) and are an uninstall error (nothing removed, the
    /// receipt kept); a helper description stops the installer before
    /// anything. Teeth: with nothing for it to fail on, the stub registers.
    @Test func aSedThatFailsStopsTheRead() throws {
        let marker = "napcat-test-sed-fails"
        func answers(_ helper: String) -> [(String, Int32, String, String)] {
            [("a stdio entry", 0, "napcat:\n  Type: stdio\n  Command: \(helper)\n  Args: \(marker)\n", ""),
             ("the not-found line", 1, "", "No MCP server named \"napcat\". \(marker)\n")]
        }
        for index in answers("").indices {
            let install = try Sandbox()
            try install.write(install.tools + "/sed", Self.failingSedStub, mode: 0o755)
            let (name, status, stdout, stderr) = answers(install.helper)[index]
            try Self.script(install, status: status, stdout: stdout, stderr: stderr)
            let installed = try install.install()
            #expect(installed.status == 1 && installed.stderr.contains("cannot read the \"napcat\" entry"), "\(name): \(installed.errors)")
            #expect(install.claudeArguments == [Self.mcpGet], "\(name): \(install.claudeArguments)")
            #expect(install.registered == nil && !install.exists(install.receipt), "\(name): the installer wrote something")

            let uninstall = try Sandbox()
            #expect(try uninstall.install().status == 0, "\(name): setup")
            try uninstall.write(uninstall.tools + "/sed", Self.failingSedStub, mode: 0o755)
            let (_, registeredStatus, registeredStdout, registeredStderr) = answers(uninstall.helper)[index]
            try Self.script(uninstall, status: registeredStatus, stdout: registeredStdout, stderr: registeredStderr)
            let run = try uninstall.uninstall()
            #expect(run.status == 1 && run.stderr.contains("cannot read the \"napcat\" entry"), "\(name): \(run.errors)")
            #expect(!uninstall.claudeArguments.contains(Self.mcpRemove) && uninstall.registered == uninstall.helper, "\(name)")
            #expect(uninstall.exists(uninstall.receipt), "\(name): the receipt must be kept")
        }
        let described = try Sandbox()
        try described.write(described.tools + "/sed", Self.failingSedStub, mode: 0o755)
        let path = described.root + "/codesign/helper-description"
        try described.write(path, try #require(described.read(path)) + "Authority=\(marker)\n")
        Self.expectRefusedBeforeAnything(try described.install(), described,
                                         "codesign names a malformed team for \(described.helper). Nothing was registered.",
                                         "a helper description")
        let plain = try Sandbox()
        try plain.write(plain.tools + "/sed", Self.failingSedStub, mode: 0o755)
        let registered = try plain.install()
        #expect(registered.status == 0 && registered.lines.contains(Self.registeredLine(plain.helper)), "teeth: \(registered.errors)")
    }

    /// Control characters, each in a path: an escape and DEL, then C1 as
    /// UTF-8 encodes it (C2 80 to C2 9F): its first, NEL, CSI and its last.
    static let controlCharacters = ["\u{1B}", "\u{7F}", "\u{80}", "\u{85}", "\u{9B}", "\u{9F}"]
    /// Printable non-ASCII text, which registers: é, and two whose UTF-8
    /// sits next to C1's (U+00A0 is C2 A0; U+0110 is C4 90).
    static let printableNonASCII = ["é", "\u{A0}", "\u{110}"]
    /// Format characters, each in a path, that are invisible or reorder the
    /// text around them, so that a printed path can look like another: the
    /// soft hyphen, the Arabic letter mark, the Mongolian vowel separator,
    /// the zero-width characters and directional marks, the directional
    /// embeddings and overrides, the invisible operators, the directional
    /// isolates and the byte order mark.
    static let formatCodePoints: [ClosedRange<UInt32>] = [0xAD...0xAD, 0x61C...0x61C, 0x180E...0x180E, 0x200B...0x200F,
                                                          0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF...0xFEFF]
    static let formatCharacters: [String] = formatCodePoints.flatMap { $0 }.compactMap { Unicode.Scalar($0) }.map { String(Character($0)) }
    /// Printable text whose UTF-8 sits next to a format character's: the
    /// not sign (C2 AC), the registered sign (C2 AE), the Arabic semicolon
    /// (D8 9B) and question mark (D8 9F), the Mongolian digit zero (E1 A0
    /// 90), the hyphen (E2 80 90), the per mille sign (E2 80 B0), the
    /// quadruple prime (E2 81 97), the superscript zero (E2 81 B0), an
    /// Arabic ligature (EF BB BC) and the fullwidth exclamation mark (EF BC
    /// 81).
    static let formatNeighbours = ["\u{AC}", "\u{AE}", "\u{61B}", "\u{61F}", "\u{1810}", "\u{2010}", "\u{2030}", "\u{2057}",
                                   "\u{2070}", "\u{FEFC}", "\u{FF01}"]
    /// Format characters that a UTF-8 [[:cntrl:]] refuses and the byte-wise
    /// rule accepts on purpose: the Arabic number sign (D8 80), the inhibit
    /// symmetric swapping mark (E2 81 AA), the interlinear annotation anchor
    /// (EF BF B9) and the tag latin capital letter A (F3 A0 81 81); APFS
    /// takes each in a folder name. They are here to pin that the checks
    /// read bytes, not the locale: a check that read the locale (its
    /// `local LC_ALL=C` gone) would take them for text under C and for
    /// controls under UTF-8, so the installer would refuse in one locale the
    /// bundle it registers in the other, and the uninstaller would leave a
    /// registration made in the other locale behind.
    static let localeOnlyControls = ["\u{600}", "\u{206A}", "\u{FFF9}", "\u{E0041}"]

    static func codePoint(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    /// Both scripts' own is_napcat_helper texts.
    static func helperFunctions() throws -> [String] {
        try [ChannelInstallStructureTests.installPath, ChannelInstallStructureTests.uninstallPath].map { path in
            try #require(ChannelInstallStructureTests.functionBody("is_napcat_helper() {", in: try ChannelInstallStructureTests.read(path)))
                .joined(separator: "\n")
        }
    }

    /// `text` in a path is refused under `locale`: in the bundle path,
    /// before anything; by both scripts' is_napcat_helper (`functions`);
    /// and in a registered command, which both scripts take for another
    /// server's (the installer stops, the uninstaller leaves it alone even
    /// when the receipt records it, printing neither).
    static func expectRefusedInEveryPath(_ text: String, locale: String, functions: [String]) throws {
        let environment = Self.environment(locale)
        let name = "\(locale), \(Self.codePoint(text))"
        let sandbox = try Sandbox()
        let bundle = sandbox.root + "/Apps/Nap\(text)Cat.app"
        try FileManager.default.moveItem(atPath: sandbox.app, toPath: bundle)
        let run = try sandbox.run("install-channel.sh", [bundle], environment: environment)
        Self.expectRefusedBeforeAnything(run, sandbox, "the bundle path contains a control character.", name)
        #expect(sandbox.codesignCalls.isEmpty, "\(name): nothing was verified either")

        let command = "/Users/someone/Nap\(text)Cat.app/" + Self.helperInBundle
        for function in functions {
            #expect(try Self.helperTestStatus(function, command, locale: locale) == 1, "\(name): is_napcat_helper takes it")
        }
        let registered = try Sandbox()
        try registered.register(command)
        let installed = try registered.install(environment: environment)
        #expect(installed.status == 1 && installed.stderr.contains("another MCP server is registered as \"napcat\"; it was left alone"),
                "\(name): \(installed.errors)")
        #expect(registered.claudeArguments == [Self.mcpGet] && !registered.exists(registered.receipt), "\(name): \(registered.claudeArguments)")
        try FileManager.default.createDirectory(atPath: registered.approvals, withIntermediateDirectories: true)
        try registered.write(registered.receipt, "version=2\npath=\(command)\n")
        let uninstalled = try registered.uninstall(environment: environment)
        #expect(uninstalled.status == 0
                && uninstalled.lines.contains("left alone: the server registered as \"napcat\" does not run a NapCat helper"),
                "\(name): \(uninstalled.lines) \(uninstalled.errors)")
        #expect(!registered.claudeArguments.contains(Self.mcpRemove) && registered.registered == command, "\(name)")
        // In bytes: a joiner is part of the character before it, which a
        // search by character would not find alone.
        for output in [installed, uninstalled] {
            #expect(Data((output.stdout + output.stderr).utf8).range(of: Data(text.utf8)) == nil, "\(name): the command was printed")
        }
    }

    /// A control character is refused byte by byte, the same in every
    /// locale (the C locale once took C1 for text), in every path
    /// (expectRefusedInEveryPath). Teeth: printable non-ASCII bundle names
    /// register and are removed in every locale.
    @Test func aControlCharacterIsRefusedTheSameInEveryLocale() throws {
        let functions = try Self.helperFunctions()
        for locale in Self.locales {
            let environment = Self.environment(locale)
            for control in Self.controlCharacters {
                try Self.expectRefusedInEveryPath(control, locale: locale, functions: functions)
            }
            for text in Self.printableNonASCII {
                let name = "\(locale), \(Self.codePoint(text))"
                let sandbox = try Sandbox()
                let bundle = sandbox.root + "/Apps/Nap\(text)Cat.app"
                try FileManager.default.moveItem(atPath: sandbox.app, toPath: bundle)
                let helper = bundle + "/" + Self.helperInBundle
                let run = try sandbox.run("install-channel.sh", [bundle], environment: environment)
                #expect(run.status == 0 && run.lines.contains(Self.registeredLine(helper)), "\(name): \(run.errors)")
                let removed = try sandbox.uninstall(environment: environment)
                #expect(removed.status == 0 && removed.lines.contains("removed: the \"napcat\" registration (user scope) for \(helper)"),
                        "\(name): \(removed.lines) \(removed.errors)")
            }
        }
    }

    /// A format character that is invisible or reorders the text around it
    /// is refused byte by byte, as a control character is, under each of
    /// the locales, in every path (expectRefusedInEveryPath): one outcome,
    /// refused, where a UTF-8 [[:cntrl:]] took most of them and the C
    /// locale's none. Teeth: the printable text next to them passes both
    /// scripts' is_napcat_helper and the installer's has_control_character.
    @Test(arguments: locales)
    func anInvisibleOrBidirectionalCharacterIsRefusedInEveryLocale(_ locale: String) throws {
        #expect(Self.formatCharacters.count == 23, "vacuity: \(Self.formatCharacters.map(Self.codePoint))")
        let functions = try Self.helperFunctions()
        for text in Self.formatCharacters {
            try Self.expectRefusedInEveryPath(text, locale: locale, functions: functions)
        }
        let install = try ChannelInstallStructureTests.read(ChannelInstallStructureTests.installPath)
        let check = try #require(ChannelInstallStructureTests.functionBody("has_control_character() {", in: install)).joined(separator: "\n")
        for text in Self.formatNeighbours {
            let name = "\(locale), \(Self.codePoint(text))"
            let command = "/Users/someone/Nap\(text)Cat.app/" + Self.helperInBundle
            for function in functions {
                #expect(try Self.helperTestStatus(function, command, locale: locale) == 0, "\(name): is_napcat_helper refuses it")
            }
            #expect(try Self.functionStatus(check, "has_control_character", command, locale: locale) == 1,
                    "\(name): has_control_character refuses it")
        }
    }

    /// A character only a UTF-8 locale calls a control (localeOnlyControls)
    /// is accepted on purpose, to pin that the checks read bytes, not the
    /// locale: under each locale, a bundle whose name holds it registers, a
    /// second run leaves the registration unchanged, and an uninstall under
    /// the other locale removes the registration and the receipt; the
    /// installer's has_control_character and both scripts' is_napcat_helper
    /// give it the same status in both locales. Vacuity: a UTF-8 [[:cntrl:]]
    /// takes it, and the C locale's does not.
    @Test func aCharacterOnlyAUTF8LocaleCallsAControlRegistersInEveryLocale() throws {
        let probe = "locale_control() { case \"$1\" in *[[:cntrl:]]*) return 0 ;; esac; return 1; }"
        let functions = try Self.helperFunctions()
        let install = try ChannelInstallStructureTests.read(ChannelInstallStructureTests.installPath)
        let check = try #require(ChannelInstallStructureTests.functionBody("has_control_character() {", in: install)).joined(separator: "\n")
        for text in Self.localeOnlyControls {
            let code = Self.codePoint(text)
            let command = "/Users/someone/Nap\(text)Cat.app/" + Self.helperInBundle
            let (utf8, c) = (try Self.functionStatus(probe, "locale_control", command, locale: "en_US.UTF-8"),
                             try Self.functionStatus(probe, "locale_control", command, locale: "C"))
            #expect(utf8 == 0 && c == 1, "vacuity: \(code): a UTF-8 [[:cntrl:]] takes it and the C locale's does not")
            for function in functions {
                let statuses = try Self.locales.map { try Self.helperTestStatus(function, command, locale: $0) }
                #expect(statuses == [0, 0], "\(code): is_napcat_helper in \(Self.locales): \(statuses)")
            }
            let checked = try Self.locales.map { try Self.functionStatus(check, "has_control_character", command, locale: $0) }
            #expect(checked == [1, 1], "\(code): has_control_character in \(Self.locales): \(checked)")

            for (locale, other) in zip(Self.locales, Self.locales.reversed()) {
                let name = "\(code), installed under \(locale), removed under \(other)"
                let sandbox = try Sandbox()
                let bundle = sandbox.root + "/Apps/Nap\(text)Cat.app"
                try FileManager.default.moveItem(atPath: sandbox.app, toPath: bundle)
                let helper = bundle + "/" + Self.helperInBundle
                let first = try sandbox.run("install-channel.sh", [bundle], environment: Self.environment(locale))
                #expect(first.status == 0 && first.lines.contains(Self.registeredLine(helper)), "\(name), run 1: \(first.errors)")
                let second = try sandbox.run("install-channel.sh", [bundle], environment: Self.environment(locale))
                #expect(second.status == 0 && second.lines.contains(Self.unchangedLine(helper)),
                        "\(name), run 2: \(second.lines) \(second.errors)")
                #expect(sandbox.claudeArguments == [Self.mcpGet, Self.mcpAdd(helper), Self.mcpGet], "\(name): \(sandbox.claudeArguments)")
                let removed = try sandbox.uninstall(environment: Self.environment(other))
                #expect(removed.status == 0 && removed.lines.contains("removed: the \"napcat\" registration (user scope) for \(helper)")
                        && removed.lines.contains("removed: \(sandbox.receipt)"), "\(name): \(removed.lines) \(removed.errors)")
                #expect(sandbox.registered == nil && !sandbox.exists(sandbox.receipt), "\(name): something was left behind")
            }
        }
    }
}
