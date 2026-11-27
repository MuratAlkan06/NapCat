// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// #193: the two channel scripts, RUN, each time in a sandbox of its own
/// and never against this machine. A run executes a copy of the committed
/// script whose one changed line is the PATH pin, which gains the
/// sandbox's `tools` folder in front, so `codesign` (and `id`, where a test
/// plants one) are stubs. HOME is the sandbox's own folder. The caller's
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
    /// description claims, nothing (ad-hoc or self-signed), or this
    /// identifier and team.
    enum Anchor { case claimed, unproven, proven(String, String) }

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
    /// "<identifier> <team>"; with no such file (an ad-hoc or self-signed
    /// build) every requirement fails, status 3, as codesign's does.
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
        read -r identifier team < "$fixtures/$role-anchor"
        [ "$4" = "=identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\"" ] || exit 3
        exit 0
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
            let authority = team.map { ["Authority=Developer ID Application: NapCat Test Signer (\($0))",
                                        "Authority=Developer ID Certification Authority", "Authority=Apple Root CA"] }
                ?? ["Signature=adhoc"]
            let description = ["Executable=" + (role == .app ? app + "/Contents/MacOS/NapCat" : helper),
                               "Identifier=" + identifier(role), "Format=Mach-O thin (arm64)",
                               "CodeDirectory v=20500 size=1000 flags=0x10000(runtime) hashes=20+7 location=embedded"]
                + authority + lines
            try write(root + "/codesign/\(role.rawValue)-description", description.joined(separator: "\n") + "\n")
            try write(root + "/codesign/\(role.rawValue)-verify", "0\n")
            let proven: (String, String)?
            switch anchor {
            case .claimed: proven = team.map { (identifier(role), $0) }
            case .unproven: proven = nil
            case let .proven(identifier, team): proven = (identifier, team)
            }
            let anchorPath = root + "/codesign/\(role.rawValue)-anchor"
            if let proven {
                try write(anchorPath, "\(proven.0) \(proven.1)\n")
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
        /// front: the only line changed.
        func run(_ name: String, _ arguments: [String] = []) throws -> Run {
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
        func install() throws -> Run { try run("install-channel.sh", [app]) }
        func uninstall() throws -> Run { try run("uninstall-channel.sh") }
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
             "\(helper) is not signed as \(probe.identifier(.helper)) with a certificate Apple issued to team \(team)."),
            ("app claims the team, Apple proves another", { try $0.sign(.app, team: team, anchor: .proven(probe.identifier(.app), other)) },
             "\(app) is not signed as \(probe.identifier(.app)) with a certificate Apple issued to team \(team)."),
            ("helper proven for the team under another identifier",
             { try $0.sign(.helper, team: team, anchor: .proven(probe.identifier(.app), team)) },
             "\(helper) is not signed as \(probe.identifier(.helper)) with a certificate Apple issued to team \(team)."),
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

    /// The two requirements the installer passes compile for the REAL
    /// codesign: an Apple-signed binary of another team fails them with
    /// status 3 ("does not satisfy"), not 1 (a syntax error, which every
    /// signature would fail, the owner's included).
    @Test func theRequirementsTheInstallerPassesCompileForTheRealCodesign() throws {
        let sandbox = try Sandbox()
        #expect(try sandbox.install().status == 0)
        let requirements = sandbox.requirements
        let team = sandbox.team
        #expect(requirements == [
            "=identifier \"\(sandbox.identifier(.helper))\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
            "=identifier \"\(sandbox.identifier(.app))\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
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
}
