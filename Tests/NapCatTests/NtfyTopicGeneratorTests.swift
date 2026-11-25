// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing
@testable import NapCat

/// Issue #103 (audit F-3): the ntfy editor's Generate button. Shape and
/// grammar, non-repetition, and an UNBIASED sampler — proven structurally
/// (every accepted byte value maps to each symbol exactly four times) and
/// checked statistically on the real random source. The editor wiring and
/// the soft caption are locked at the bottom.
struct NtfyTopicGeneratorTests {
    /// A deterministic byte source that answers the queued draws in order,
    /// then fails.
    private final class ScriptedBytes {
        private var draws: [[UInt8]]
        private(set) var requests: [Int] = []
        init(_ draws: [[UInt8]]) { self.draws = draws }
        func next(_ count: Int) -> [UInt8]? {
            requests.append(count)
            return draws.isEmpty ? nil : draws.removeFirst()
        }
    }

    // MARK: Shape

    @Test func aGeneratedTopicIsNapcatPlus22Base62CharactersAndPassesTheGrammar() throws {
        let alphabet = Set(NtfyTopicGenerator.alphabet)
        #expect(NtfyTopicGenerator.alphabet.count == 62 && alphabet.count == 62)
        #expect(alphabet == Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"))
        for _ in 0..<200 {
            let topic = try #require(NtfyTopicGenerator.generate())
            #expect(topic.hasPrefix("napcat-"))
            let suffix = topic.dropFirst("napcat-".count)
            #expect(suffix.count == 22)
            #expect(suffix.allSatisfy(alphabet.contains), "'\(suffix)' leaves base62")
            #expect(topic.count == 29 && topic.count <= LidGuardTuning.maxTopicLength)
            #expect(LidGuardPolicy.validateTopic(topic) == .valid(topic), "grammar-valid as generated, no trimming")
            #expect(topic.count >= LidGuardTuning.recommendedMinTopicLength, "never 'short'")
        }
        // ≈ 131 bits of entropy.
        #expect(Double(NtfyTopicGenerator.suffixLength) * log2(62) > 130)
    }

    @Test func generatedTopicsDoNotRepeat() {
        let topics = (0..<2_000).compactMap { _ in NtfyTopicGenerator.generate() }
        #expect(topics.count == 2_000, "the system random source failed")
        #expect(Set(topics).count == topics.count, "a generated topic repeated")
    }

    // MARK: The sampler is unbiased

    /// Structural proof: over every byte value once, the 248 accepted values
    /// hit each of the 62 symbols EXACTLY four times and 248…255 hit none —
    /// so a uniform byte gives a uniform symbol. The naive `% 62` it replaces
    /// would give the first eight symbols five hits each.
    @Test func everySymbolOwnsExactlyFourAcceptedByteValues() {
        let all = (0...255).map(UInt8.init)
        let symbols = NtfyTopicGenerator.symbols(from: all)
        #expect(symbols.count == 248)
        let counts = Dictionary(symbols.map { ($0, 1) }, uniquingKeysWith: +)
        #expect(counts.count == 62)
        #expect(counts.values.allSatisfy { $0 == 4 }, "\(counts)")
        #expect(NtfyTopicGenerator.symbols(from: Array(248...255)).isEmpty, "bytes 248…255 are rejected")
        #expect(NtfyTopicGenerator.acceptBelow == 4 * 62, "the largest multiple of 62 below 256")

        let naive = Dictionary(all.map { (NtfyTopicGenerator.alphabet[Int($0) % 62], 1) }, uniquingKeysWith: +)
        #expect(naive.values.filter { $0 == 5 }.count == 8, "what the rejection step exists to remove")
    }

    /// Statistical check on the REAL source: 66,000 symbols against the
    /// uniform distribution (chi-square, 61 degrees of freedom; 125 is a
    /// p ≈ 3·10⁻⁶ bound, so a pass is not luck and a flake is not plausible),
    /// and every position of the suffix is in play.
    @Test func generatedSymbolsAreUniform() throws {
        var counts: [Character: Int] = [:]
        var positions = Array(repeating: Set<Character>(), count: NtfyTopicGenerator.suffixLength)
        for _ in 0..<3_000 {
            let suffix = Array(try #require(NtfyTopicGenerator.generate()).dropFirst(NtfyTopicGenerator.prefix.count))
            for (index, symbol) in suffix.enumerated() {
                counts[symbol, default: 0] += 1
                positions[index].insert(symbol)
            }
        }
        let total = counts.values.reduce(0, +)
        #expect(total == 66_000)
        let expected = Double(total) / 62
        let chiSquare = NtfyTopicGenerator.alphabet.reduce(0.0) { sum, symbol in
            let observed = Double(counts[symbol, default: 0])
            return sum + (observed - expected) * (observed - expected) / expected
        }
        #expect(chiSquare < 125, "chi-square \(chiSquare) over 61 dof — the symbols are not uniform")
        #expect(positions.allSatisfy { $0.count > 55 }, "a suffix position draws from a narrow set")
    }

    /// Rejected bytes are skipped, never mapped or padded: an all-rejected
    /// draw contributes nothing, a short draw is topped up by the next one,
    /// and the suffix is the first 22 accepted symbols in order.
    @Test func rejectedBytesAreSkippedAndShortDrawsAreToppedUp() {
        let rejected = [UInt8](repeating: 255, count: 32)
        let mixed: [UInt8] = Array(0..<20) + Array(248...255) + [252, 253, 254, 255]   // 20 accepted
        let next: [UInt8] = Array(20..<52)
        let source = ScriptedBytes([rejected, mixed, next])
        let topic = NtfyTopicGenerator.topic(randomBytes: source.next)
        let expected = String((0..<22).map { NtfyTopicGenerator.alphabet[$0] })
        #expect(topic == "napcat-" + expected)
        #expect(source.requests == [32, 32, 32])
    }

    /// A failing source yields no topic — never a weak or partial one — and
    /// one that only ever answers rejected bytes is given up on.
    @Test func aFailingSourceYieldsNoTopic() {
        let failing = ScriptedBytes([])
        #expect(NtfyTopicGenerator.topic(randomBytes: failing.next) == nil)
        #expect(failing.requests == [32])

        let short = ScriptedBytes([[1, 2, 3]])
        #expect(NtfyTopicGenerator.topic(randomBytes: short.next) == nil, "a short answer is a failure")

        let stuck = ScriptedBytes(Array(repeating: [UInt8](repeating: 250, count: 32), count: 100))
        #expect(NtfyTopicGenerator.topic(randomBytes: stuck.next) == nil)
        #expect(stuck.requests.count == NtfyTopicGenerator.maxDraws, "bounded, never a spin")
    }

    // MARK: The soft caption

    @Test func theHintFlagsShortUsableTopicsAndAFreshlyGeneratedOne() throws {
        let short = MenuStateModel.lidAlertShortTopicHint
        #expect(short.hasPrefix("Short — "), "canon C2: state word first")
        #expect(short.contains("16") && short.contains("Generate"))
        #expect(MenuStateModel.lidAlertTopicHint("napcat-abc", generated: nil) == short)
        #expect(MenuStateModel.lidAlertTopicHint("  napcat-abcdefgh  ", generated: nil) == short, "15 after trimming")
        #expect(MenuStateModel.lidAlertTopicHint("napcat-abcdefghi", generated: nil) == nil, "16 is enough")
        #expect(MenuStateModel.lidAlertTopicHint("", generated: nil) == nil, "empty: nothing to advise")
        #expect(MenuStateModel.lidAlertTopicHint("bad/topic", generated: nil) == nil, "unusable: Save says why")

        let generated = try #require(NtfyTopicGenerator.generate())
        let fresh = MenuStateModel.lidAlertGeneratedTopicHint
        #expect(fresh.hasPrefix("Generated — ") && fresh.contains(TopicFieldVisibility.checkboxTitle))
        #expect(MenuStateModel.lidAlertTopicHint(generated, generated: generated) == fresh)
        #expect(MenuStateModel.lidAlertTopicHint(generated + "x", generated: generated) == nil, "edited: no longer 'generated'")
        #expect(MenuStateModel.lidAlertTopicHint(generated, generated: nil) == nil)
        for hint in [short, fresh] {
            #expect(!hint.contains("napcat-"), "a hint never shows a topic")
        }
    }

    // MARK: - Structure

    /// The system random source is used in ONE file; the button is the one
    /// caller of the generator; a generated topic lands only in the VISIBLE
    /// field; and the hints borrow the band only on a pass with no error.
    ///
    /// AMENDED (deliberate, S-PAIR-C1, #168): the pairing ceremony's nonce is
    /// the random source's second user — once each, in the generator and in
    /// the pairing controller's `secureNonce`, and nowhere else.
    @Test func theGenerateButtonIsWiredThroughTheGeneratorOnly() throws {
        let sources = try LidGuardStructureTests.swiftSources()
        let randomSources = ["NtfyTopicGenerator.swift": 1, "PairingController.swift": 1]
        for (name, text) in sources where text.contains("SecRandomCopyBytes") {
            #expect(randomSources[name] == text.components(separatedBy: "SecRandomCopyBytes(").count - 1,
                    "SecRandomCopyBytes in \(name)")
        }
        #expect(Set(sources.filter { $0.text.contains("SecRandomCopyBytes") }.map(\.name)) == Set(randomSources.keys),
                "vacuity: both users are where the lock looks")
        for (name, text) in sources where text.contains("NtfyTopicGenerator.") {
            #expect(name == "MenuContentView.swift", "\(name) generates topics — only the editor's button may")
        }
        let menu = try #require(sources.first { $0.name == "MenuContentView.swift" }).text
        #expect(menu.components(separatedBy: "NtfyTopicGenerator.generate()").count - 1 == 1)
        for token in [
            "generateButton = NSButton(title: TopicFieldVisibility.generateButtonTitle, target: nil, action: nil)",
            "generateButton.action = #selector(generateTopic(_:))",
            "generateButton.setAccessibilityLabel(TopicFieldVisibility.generateAccessibilityLabel)",
            "let shown: NSTextField = visibility.isRevealed ? plainField : secureField\n        shown.stringValue = generated",
            "container.addSubview(generateButton)",
            "var maxX: CGFloat { generateButton.frame.maxX }",
            "if error == nil { topicRow.showsHints(in: errorCaption) }",
            "hintBand.stringValue = MenuStateModel.lidAlertTopicHint(topic, generated: generatedTopic) ?? \"\"",
        ] {
            #expect(menu.contains(token), "'\(token)' not found — the Generate wiring changed")
        }
        #expect(!menu.contains("isRevealed = true") && !menu.contains("visibility = .revealed"),
                "Generate must not unmask the field on the user's behalf")
        #expect(TopicFieldVisibility.generateButtonTitle == "Generate")
        #expect(TopicFieldVisibility.generateAccessibilityLabel == "Generate a random topic")
        #expect(LidGuardTuning.recommendedMinTopicLength == 16)
    }
}
