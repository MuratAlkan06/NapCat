import Testing
@testable import NapCat

/// Locks the privileged argv strings to the exact sudoers entries in
/// PLAN.md §4. The expected literals below ARE the sudoers command strings —
/// if any expectation here changes, scripts/setup.sh and PLAN.md §4 must
/// change in the same commit, and every user must re-run setup.
/// (This suite never reads setup.sh; SetupScriptTests parses the script's
/// sudoers heredoc + LaunchAgent and locks them to this enum.)
struct PrivilegedCommandTests {
    @Test func pmsetArgvByteMatchesSudoersEntries() {
        #expect(PrivilegedCommand.stayAwakeOn.argv == ["/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(PrivilegedCommand.stayAwakeOff.argv == ["/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    @Test func smcArgvByteMatchesSudoersEntries_unusedUntilP3() {
        #expect(PrivilegedCommand.chargingDisableCH0B.argv == ["/usr/local/napcat/smc", "-k", "CH0B", "-w", "02"])
        #expect(PrivilegedCommand.chargingDisableCH0C.argv == ["/usr/local/napcat/smc", "-k", "CH0C", "-w", "02"])
        #expect(PrivilegedCommand.chargingDisableCHTE.argv == ["/usr/local/napcat/smc", "-k", "CHTE", "-w", "01000000"])
        #expect(PrivilegedCommand.chargingEnableCH0B.argv == ["/usr/local/napcat/smc", "-k", "CH0B", "-w", "00"])
        #expect(PrivilegedCommand.chargingEnableCH0C.argv == ["/usr/local/napcat/smc", "-k", "CH0C", "-w", "00"])
        #expect(PrivilegedCommand.chargingEnableCHTE.argv == ["/usr/local/napcat/smc", "-k", "CHTE", "-w", "00000000"])
    }

    /// The full command-line strings, exactly as written in PLAN.md §4 and
    /// installed by scripts/setup.sh (pmset) / the P5 setup extension (smc).
    @Test func commandLineStringsByteMatchPlanSection4() {
        let expected: [(PrivilegedCommand, String)] = [
            (.stayAwakeOn, "/usr/bin/pmset -a disablesleep 1"),
            (.stayAwakeOff, "/usr/bin/pmset -a disablesleep 0"),
            (.chargingDisableCH0B, "/usr/local/napcat/smc -k CH0B -w 02"),
            (.chargingDisableCH0C, "/usr/local/napcat/smc -k CH0C -w 02"),
            (.chargingDisableCHTE, "/usr/local/napcat/smc -k CHTE -w 01000000"),
            (.chargingEnableCH0B, "/usr/local/napcat/smc -k CH0B -w 00"),
            (.chargingEnableCH0C, "/usr/local/napcat/smc -k CH0C -w 00"),
            (.chargingEnableCHTE, "/usr/local/napcat/smc -k CHTE -w 00000000"),
        ]
        // The enum is the complete, closed set — nothing beyond these eight.
        #expect(PrivilegedCommand.allCases.count == expected.count)
        for (command, line) in expected {
            #expect(command.argv.joined(separator: " ") == line)
        }
    }

    @Test func everyCommandRunsThroughNonInteractiveSudo() {
        for command in PrivilegedCommand.allCases {
            #expect(Array(command.sudoArgv.prefix(2)) == ["/usr/bin/sudo", "-n"])
            #expect(Array(command.sudoArgv.dropFirst(2)) == command.argv)
        }
    }

    // MARK: - Result classification (pure function; stderr fixtures are the
    // messages real sudo emits — verified against this machine's sudo).

    @Test func exitZeroIsSuccess() {
        #expect(PrivilegedCommand.classify(exitStatus: 0, stderr: "") == .success)
    }

    @Test func passwordRequiredIsSudoDenied() {
        // `sudo -n` with no matching NOPASSWD rule (setup.sh not run).
        #expect(
            PrivilegedCommand.classify(exitStatus: 1, stderr: "sudo: a password is required\n")
                == .sudoDenied
        )
    }

    @Test func notAllowedToExecuteIsSudoDenied() {
        // Sudoers exists but does not cover the command.
        let stderr = "Sorry, user murat is not allowed to execute '/usr/bin/pmset -a hibernatemode 25' as root on mac.\n"
        #expect(PrivilegedCommand.classify(exitStatus: 1, stderr: stderr) == .sudoDenied)
    }

    @Test func otherNonZeroExitIsCommandFailure() {
        let result = PrivilegedCommand.classify(exitStatus: 1, stderr: "pmset: error 0xe00002c1\n")
        #expect(result == .commandFailed(exitStatus: 1, stderr: "pmset: error 0xe00002c1\n"))
    }
}
