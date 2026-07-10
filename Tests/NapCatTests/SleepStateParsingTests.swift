import Testing
@testable import NapCat

/// Fixture-based tests for the pure `pmset -g` parser (ADR §6 read-back
/// verification path). Fixtures mirror real Sequoia output including the
/// tab-separated SleepDisabled line.
struct SleepStateParsingTests {
    static let sleepDisabledOne = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         gpuswitch            2
         disksleep            10
         sleep                1 (sleep prevented by powerd)
         hibernatemode        3
         ttyskeepawake        1
         displaysleep         10
         tcpkeepalive         1
         lowpowermode         0
         womp                 0
        """

    static let sleepDisabledZero = """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         standby              1
         sleep                1
         displaysleep         10
        """

    /// Some systems omit the line entirely when sleep was never disabled.
    static let missingLine = """
        System-wide power settings:
        Currently in use:
         standby              1
         sleep                1
         displaysleep         10
        """

    @Test func parsesSleepDisabledOne() {
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: Self.sleepDisabledOne) == true)
    }

    @Test func parsesSleepDisabledZero() {
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: Self.sleepDisabledZero) == false)
    }

    @Test func missingLineParsesAsNil() {
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: Self.missingLine) == nil)
    }

    @Test func emptyOutputParsesAsNil() {
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: "") == nil)
    }

    @Test func malformedValueParsesAsNil() {
        let output = "System-wide power settings:\n SleepDisabled\t\tmaybe\n"
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: output) == nil)
    }

    @Test func doesNotMatchSubstringKeys() {
        // A hypothetical key containing "SleepDisabled" as a substring must
        // not match; only an exact first token counts.
        let output = "System-wide power settings:\n DisplaySleepDisabled\t\t1\n"
        #expect(SleepStateController.parseSleepDisabled(fromPmsetG: output) == nil)
    }
}
