// AppKit, not Foundation (CLT cross-import overlay — PLAN.md decision log):
// Pipe/Data for the bounded-capture test.
import AppKit
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
        #expect(PrivilegedCommand.classify(exitStatus: 0, stdout: "", stderr: "") == .success)
    }

    @Test func passwordRequiredIsSudoDenied() {
        // `sudo -n` with no matching NOPASSWD rule (setup.sh not run).
        #expect(
            PrivilegedCommand.classify(exitStatus: 1, stdout: "", stderr: "sudo: a password is required\n")
                == .sudoDenied
        )
    }

    @Test func notAllowedToExecuteIsSudoDenied() {
        // Sudoers exists but does not cover the command.
        let stderr = "Sorry, user murat is not allowed to execute '/usr/bin/pmset -a hibernatemode 25' as root on mac.\n"
        #expect(PrivilegedCommand.classify(exitStatus: 1, stdout: "", stderr: stderr) == .sudoDenied)
    }

    @Test func otherNonZeroExitIsCommandFailure() {
        let result = PrivilegedCommand.classify(exitStatus: 1, stdout: "", stderr: "pmset: error 0xe00002c1\n")
        #expect(result == .commandFailed(exitStatus: 1, stderr: "pmset: error 0xe00002c1\n"))
    }

    // MARK: - stdout `Error:` lines (issue #58: the vendored smc prints its
    // failures to STDOUT and always exits 0 — third_party/smc/smc.c main)

    /// THE smc blindness case: a refused write exits 0 with an `Error:` line
    /// on stdout. It must be a failure carrying that line, never success.
    @Test func exitZeroWithAnErrorLineOnStdoutIsFailure() {
        let stdout = "Error: SMCWriteKey() = e00002bc\n"
        #expect(PrivilegedCommand.classify(exitStatus: 0, stdout: stdout, stderr: "")
                == .commandFailed(exitStatus: 0, stderr: "Error: SMCWriteKey() = e00002bc"))
    }

    @Test func normalOutputIsNotAFailure() {
        // Value lines as the vendored smc prints them (S2 fixtures), and the
        // silent success of a write.
        for stdout in ["", "\n",
                       "  CHTE  [ui32]  1 (bytes 01 00 00 00)\n",
                       "  CH0B  [hex_]  (bytes 02)\n"] {
            #expect(PrivilegedCommand.classify(exitStatus: 0, stdout: stdout, stderr: "") == .success,
                    "stdout \(stdout.debugDescription)")
        }
    }

    @Test func nonZeroExitWithAnErrorLineCarriesTheLine() {
        #expect(PrivilegedCommand.classify(exitStatus: 1, stdout: "Error: value is not valid\n", stderr: "")
                == .commandFailed(exitStatus: 1, stderr: "Error: value is not valid"))
    }

    @Test func sudoRefusalStillWinsOverStdout() {
        #expect(PrivilegedCommand.classify(exitStatus: 1, stdout: "Error: x\n",
                                           stderr: "sudo: a password is required\n") == .sudoDenied)
    }

    @Test func errorLineDetection() {
        #expect(PrivilegedCommand.errorLine(in: "Error: no SMC found\n") == "Error: no SMC found")
        #expect(PrivilegedCommand.errorLine(in: "  Error: indented  \r\n") == "Error: indented",
                "leading/trailing whitespace is ignored")
        #expect(PrivilegedCommand.errorLine(in: "ok\nError: first\nError: second\n") == "Error: first",
                "the first Error: line is the detail")
        #expect(PrivilegedCommand.errorLine(in: "an Error: mid-line") == nil, "must START the line")
        #expect(PrivilegedCommand.errorLine(in: "Errors: 0") == nil)
        #expect(PrivilegedCommand.errorLine(in: "error: lowercase") == nil, "the helper's prefix is exact")
        #expect(PrivilegedCommand.errorLine(in: "") == nil)
    }

    // MARK: - Bounded capture

    /// At most `limit` bytes are kept, and the stream is drained to its end
    /// so a chatty child can never block on a full pipe.
    @Test func capturedOutputIsBoundedAndDrained() throws {
        let pipe = Pipe()
        let payload = Data(String(repeating: "x", count: 100).utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let kept = PrivilegedCommand.readCapped(pipe.fileHandleForReading, limit: 10)
        #expect(kept == payload.prefix(10))
        let rest = try pipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(rest.isEmpty, "everything past the cap was drained, not left in the pipe")

        let small = Pipe()
        try small.fileHandleForWriting.write(contentsOf: Data("Error: x\n".utf8))
        try small.fileHandleForWriting.close()
        #expect(PrivilegedCommand.readCapped(small.fileHandleForReading) == Data("Error: x\n".utf8))
        #expect(PrivilegedCommand.maxCapturedOutputBytes == 4096)
    }
}
