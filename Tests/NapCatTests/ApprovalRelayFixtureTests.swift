// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat
@testable import NapCatWire

/// The relay's own previews (#253): the twenty-three permission prompts
/// Claude Code 2.1.326 relayed in a recorded session, each with its tool
/// name and its preview exactly as relayed (its spacing, its escapes and
/// the relay's own elision), the home folder written as `/Users/someone`.
/// Under the listed commands alone the gate keeps every one, with the code
/// shown; the frozen oracle keeps each with the same code, but where the
/// floor names the prompt.
struct ApprovalRelayFixtureTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        let capture: Int
        let tool: String
        let preview: String
        let expected: ApprovalClassification
        let note: String
        init(_ capture: Int, _ tool: String, _ preview: String, _ expected: ApprovalClassification, _ note: String = "") {
            self.capture = capture
            self.tool = tool
            self.preview = preview
            self.expected = expected
            self.note = note
        }
        var testDescription: String { note.isEmpty ? "capture \(capture)" : "capture \(capture): \(note)" }
    }

    static let notInTable = ApprovalClassification.suppress(.unclassifiable(.commandNotInTable))
    static let outside = ApprovalClassification.suppress(.unclassifiable(.commandOutsideGrammar))

    /// In the order they were relayed. Repeats are the same prompt relayed
    /// again.
    static let fixtures: [Fixture] = [
        Fixture(1, "Bash", "{ \"command\": \"echo napcat-drill-ask channel-check\", \"description\": \"Print the drill channel-check line\" }",
                Self.notInTable, "an echo an ask rule relayed"),
        Fixture(2, "Bash", "{ \"command\": \"echo napcat-drill-ask bash-in-bypass\", \"description\": \"Print the drill bash-in-bypass line\" }",
                Self.notInTable),
        Fixture(3, "Bash", "{ \"command\": \"echo napcat-drill-ask bash-in-bypass\", \"description\": \"Print the drill bash-in-bypass line\" }",
                Self.notInTable),
        Fixture(4, "Bash", "{ \"command\": \"echo napcat-drill-ask bash-in-bypass\", \"description\": \"Print the drill bash-in-bypass line\" }",
                Self.notInTable),
        Fixture(5, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/askrule/ask-write.txt\", \"content\": \"hello from the ask rule\\n\" }",
                .suppress(.localOnlyFileEdit), "a one-line write"),
        Fixture(6, "Bash", "{ \"command\": \"GITHUB_WORKFLOW_OK=1 git -C gitrepo commit --allow-empty -F - <<'EOF'\\ndrill: first line\\n\\nsecond paragraph of the message\\nEOF\", \"description\": \"Create an empty commit with a two-paragraph message\" }",
                Self.outside, "a commit message over several lines (a here-document)"),
        Fixture(7, "Bash", "{ \"command\": \"echo \\\"year $(date +%Y)\\\" > subst-out.txt && ls *.txt\", \"description\": \"Write the current year to a text file and list text files\" }",
                Self.outside, "a substitution and a redirection"),
        Fixture(8, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/notes/one.txt\", \"content\": \"alpha beta alpha\" }",
                .suppress(.localOnlyFileEdit)),
        Fixture(9, "Bash", "{ \"command\": \"touch drill-deny-target.txt\", \"description\": \"Create an empty file named drill-deny-target.txt\" }",
                Self.notInTable),
        Fixture(10, "Edit", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/notes/one.txt\", \"old_string\": \"alpha\", \"new_string\": \"omega\", \"replace_all\": true }",
                .suppress(.localOnlyFileEdit)),
        Fixture(11, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/big.txt\", \"content\": \"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcde\n\u{22EF} 982 code points elided \u{22EF}\nBCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n\" }",
                .suppress(.unclassifiable(.previewTooLarge)), "a long write, elided by the relay"),
        Fixture(12, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/dir with space/file name.txt\", \"content\": \"hi\" }",
                .suppress(.unclassifiable(.pathNotCanonical)), "a path with spaces"),
        Fixture(13, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/linked-dir/via-link.txt\", \"content\": \"hi\" }",
                .suppress(.localOnlyFileEdit), "a path through a symlink"),
        Fixture(14, "Read", "{ \"file_path\": \"/etc/hosts\" }",
                .suppress(.forbidden(.privilegeEscalation)), "a read outside the project"),
        Fixture(15, "WebSearch", "{ \"query\": \"IANA reserved example domains\", \"mode\": \"standard\" }",
                .suppress(.unclassifiable(.unknownTool)), "a web search"),
        Fixture(16, "mcp__napcat-drill__drill_echo", "{ \"text\": \"nested test\", \"nested\": {\"level1\":{\"level2\":[\"a\",1,true,null],\"k\":\"v\"}} }",
                .suppress(.floor(.ownNames)), "a connector tool with nested arguments"),
        Fixture(17, "Read", "{ \"file_path\": \"/etc/hosts\" }",
                .suppress(.forbidden(.privilegeEscalation))),
        Fixture(18, "Bash", "{ \"command\": \"rm -rf /Users/someone/capture-drill-scratch-2026-11-27/rm-target/*\", \"description\": \"Delete everything inside the drill's rm-target folder\" }",
                Self.outside, "a delete of a folder's contents"),
        Fixture(19, "Bash", "{ \"command\": \"rm -rf /Users/someone/capture-drill-scratch-2026-11-27/rm-target/*\", \"description\": \"Delete everything inside the drill's rm-target folder\" }",
                Self.outside),
        Fixture(20, "Bash", "{ \"command\": \"rm -rf \\\"$(printf %s /Users/someone/capture-drill-scratch-2026-11-27/rm-target/empty.txt)\\\"\", \"description\": \"Delete the empty.txt file in the drill's rm-target folder\" }",
                Self.outside, "a delete through a substitution"),
        Fixture(21, "Write", "{ \"file_path\": \"/Users/someone/capture-drill-scratch-2026-11-27/project/indent-test.txt\", \"content\": \"top\\n two\\n four\\na b\\n\" }",
                .suppress(.localOnlyFileEdit), "a write whose indentation the relay folded"),
        Fixture(22, "Bash", "{ \"command\": \"printf '%s' 'literal\\\\n' > nl-out.txt\\nls nl-out.txt\", \"description\": \"Write a literal backslash-n string to a file, then list it\" }",
                Self.outside, "a literal backslash-n and a line break"),
        Fixture(23, "Bash", "{ \"command\": \"touch bg-flag.txt\", \"description\": \"Create an empty flag file\", \"run_in_background\": true }",
                Self.notInTable, "a run in the background"),
    ]

    @Test(arguments: fixtures)
    func eachRelayedPreviewIsKeptWithItsCode(_ fixture: Fixture) {
        let answer = ApprovalGate.classify(toolName: fixture.tool, inputPreview: fixture.preview, topic: .absent, policy: .listedOnly)
        #expect(answer == fixture.expected)
        let oracle = FrozenApprovalGate.classify(toolName: fixture.tool, inputPreview: fixture.preview)
        guard case .suppress(.floor) = answer else {
            #expect(oracle == answer, "the oracle's code")
            return
        }
        #expect(oracle == .suppress(.localOnlyMCP), "the one the floor names: a connector named like NapCat's")
    }

    /// The set is the relayed one: twenty-three, in order, every tool and
    /// shape the session relayed, the home folder neutral, and no request
    /// or session field among them.
    @Test func theFixturesAreTheRelayedPreviews() throws {
        let fixtures = Self.fixtures
        #expect(fixtures.map(\.capture) == Array(1...23))
        #expect(Set(fixtures.map(\.tool)) == ["Bash", "Write", "Edit", "Read", "WebSearch", "mcp__napcat-drill__drill_echo"])
        for fixture in fixtures {
            #expect(!fixture.preview.contains("/Users/") || fixture.preview.contains("/Users/someone/"), "capture \(fixture.capture)")
            for field in ["request_id", "client_info", "server_pid"] {
                #expect(!fixture.preview.contains(field), "capture \(fixture.capture) holds \(field)")
            }
        }
        // The long write: elided by the relay, so it is not one strict
        // object, it holds the relay's placeholder, and it is past the size
        // the gate reads. Kept, whichever comes first.
        let long = try #require(fixtures.first { $0.capture == 11 })
        #expect(long.preview.unicodeScalars.count > ApprovalGate.maxPreviewScalars)
        #expect(ApprovalPreview.parseObject(long.preview) == nil)
        #expect(long.preview.contains("\u{22EF} 982 code points elided \u{22EF}"))
        // A line break arrives as an escape, a literal backslash doubled.
        let literal = try #require(fixtures.first { $0.capture == 22 })
        let command = try #require(ApprovalPreview.parseObject(literal.preview)?.first { $0.key == "command" }?.value)
        #expect(command == .string("printf '%s' 'literal\\n' > nl-out.txt\nls nl-out.txt"))
        // The background run arrives as a real boolean.
        let background = try #require(fixtures.first { $0.capture == 23 })
        #expect(ApprovalPreview.parseObject(background.preview)?.last == PreviewMember(key: "run_in_background", value: .bool(true)))
    }
}
