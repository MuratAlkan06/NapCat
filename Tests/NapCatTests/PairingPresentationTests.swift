// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import CoreImage
import CryptoKit
import NapCatWire
import SwiftUI
import Testing
@testable import NapCat

/// S-PAIR-C1.5 (the C1 security delta check's (b)): what every way of describing a value shows —
/// `String(describing:)`, an interpolation, `String(reflecting:)`, `dump`
/// and a `Mirror` — and which of them gives one of `secrets` away.
enum Redaction {
    /// The code's every spelling: the payload, its base64url part, the
    /// nonce in hex and as Swift prints a byte array.
    static func secrets(payload: String, nonce: [UInt8]) -> [String] {
        [payload, String(payload.dropFirst("napcat-pair-v1:".count)), ApprovalSigning.lowercaseHex(nonce),
         nonce.prefix(6).map(String.init).joined(separator: ", ")]
    }

    static func channels(_ value: Any) -> [(String, String)] {
        var dumped = ""
        dump(value, to: &dumped)
        let mirror = Mirror(reflecting: value)
        let children = mirror.children.map { "\($0.label ?? "_"): \(String(reflecting: $0.value))" }.joined(separator: "; ")
        return [("String(describing:)", String(describing: value)), ("interpolation", "\(value)"),
                ("String(reflecting:)", String(reflecting: value)), ("dump", dumped), ("Mirror", children)]
    }

    static func leaks(_ value: Any, secrets: [String]) -> [String] {
        channels(value).filter { _, text in secrets.contains { text.contains($0) } }.map(\.0)
    }
}

/// F4 slice S-PAIR-C1 (#168): what the pairing sheet and Settings › Claude
/// show, per state, as tables over the pure mappings (the ratified spec's
/// words, exactly); the QR as drawn (decoded back to its payload, its quiet
/// zone and its pixel grid); and the Settings window's managed sheet seam
/// over recording hooks — no window on screen, nothing activated.
@MainActor
struct PairingPresentationTests {
    static let start = PairingCeremonyTests.start

    static func content(_ state: PairingCeremonyState, at seconds: TimeInterval = 2) -> PairingSheetContent {
        PairingSheetContent.make(state, now: start + seconds)
    }

    // MARK: - The sheet, state by state (S1a–S1e)

    @Test func s1aShowsTheCodeTheCountdownAndThePrivacyNote() {
        let (state, _) = PairingCeremonyTests.begun()
        let sheet = Self.content(state)
        #expect(sheet.screen == .code && sheet.title == "Pair iPhone" && sheet.subtitle == nil)
        #expect(sheet.qrPayload == ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
        #expect(sheet.status == PanelLine(text: "Waiting — scan this code with the NapCat app on your iPhone", severity: .nominal))
        #expect(sheet.notes == ["Pair in private — anyone who can see this code could try to pair while it is up."])
        #expect(sheet.countdown == "Code expires in 4:58")
        #expect(sheet.actions == [.cancel] && sheet.actionsEnabled && sheet.fingerprint == nil)

        var offline = state
        _ = offline.apply(.tick(now: Self.start + 2.5))
        _ = offline.apply(.fetched(.unreachable, now: Self.start + 2.5))
        #expect(Self.content(offline).status == PanelLine(text: "Waiting — iCloud is unreachable; still trying", severity: .warning))
    }

    @Test func s1bHidesTheCodeAndKeepsTheCountdown() {
        var (state, _) = PairingCeremonyTests.begun()
        _ = state.apply(.visible(false))
        let sheet = Self.content(state, at: 61)
        #expect(sheet.screen == .hidden && sheet.qrPayload == nil)
        #expect(sheet.status.text == "Hidden — bring this window to the front to show the code")
        #expect(sheet.status.severity != .nominal, "severity carries an icon, never color alone")
        #expect(sheet.countdown == "Code expires in 3:59" && sheet.actions == [.cancel])
    }

    @Test func s1cShowsTheFrozenCodeAndTheMacFirstOrder() throws {
        let (state, candidate) = try PairingCeremonyTests.comparing()
        let sheet = Self.content(state, at: 3)
        #expect(sheet.screen == .compare && sheet.title == "Compare the Codes" && sheet.qrPayload == nil)
        #expect(sheet.fingerprint == candidate.fingerprint)
        #expect(sheet.status.text == "Your iPhone is showing a code too. If all three groups match, confirm here first, then on your iPhone.")
        #expect(sheet.actions == [.theyDontMatch, .codesMatch], "Codes Match last, and not the default: nothing answers Return")
        #expect(sheet.actions.map(\.title) == ["Codes Don't Match", "Codes Match"])
        #expect(sheet.countdown == "Code expires in 4:57", "the window bounds the comparison too")
        var committing = state
        _ = committing.apply(.codesMatch(now: Self.start + 4))
        #expect(!Self.content(committing).actionsEnabled, "no second press while the key is written")
    }

    @Test func s1dPairedNeverClosesItself() throws {
        var (state, candidate) = try PairingCeremonyTests.comparing()
        _ = state.apply(.codesMatch(now: Self.start + 4))
        _ = state.apply(.committed(true))
        let sheet = Self.content(state)
        #expect(sheet.screen == .paired && sheet.title == "iPhone Paired")
        #expect(sheet.status.text == "Paired — finish on your iPhone: tap Codes Match there.")
        #expect(sheet.notes == ["The iPhone completes its half after you."])
        #expect(sheet.actions == [.done] && sheet.countdown == nil && sheet.fingerprint == candidate.fingerprint)
    }

    /// S1e: a CLOSED set of four causes, each in its words; no Start Over
    /// after a mismatch.
    @Test func s1eEndsInOneOfFourCauses() {
        let expected: [PairingEnd: (String, PanelSeverity, [PairingSheetContent.Action])] = [
            .expired: ("Expired — the code timed out; nothing changed. Start over for a new code.", .warning, [.close, .startOver]),
            .refused: ("Refused — the reply didn't check out; nothing was saved. Start over with a new code.", .error,
                       [.close, .startOver]),
            .stoppedMismatch: ("Stopped — the codes don't match, so nothing was saved. Cancel on your iPhone too, and pair again "
                               + "later, in private.", .warning, [.close]),
            .saveFailed: ("Failed — the key could not be saved; nothing changed. Start over to try again.", .error,
                          [.close, .startOver]),
        ]
        #expect(Set(expected.keys) == Set(PairingEnd.allCases))
        for end in PairingEnd.allCases {
            let line = PairingSheetContent.endedLine(end)
            let (text, severity, actions) = expected[end]!
            #expect(line == PanelLine(text: text, severity: severity), "\(end)")
            #expect(severity != .nominal, "\(end): a failure is never nominal")
            let sheet = Self.content(Self.ended(end))
            #expect(sheet.screen == .ended(end) && sheet.status == line && sheet.actions == actions, "\(end)")
            #expect(sheet.title == "Not Paired" && sheet.subtitle == nil, "\(end): with no pairing before, none now")
            #expect(sheet.qrPayload == nil && sheet.fingerprint == nil && sheet.countdown == nil)
        }
    }

    /// A ceremony begun at `start`, rotating or not, driven to `end`.
    static func ended(_ end: PairingEnd, rotating: Bool = false) -> PairingCeremonyState {
        var (state, _) = PairingCeremonyTests.begun(rotating: rotating)
        switch end {
        case .expired: _ = state.apply(.tick(now: start + 300))
        case .refused:
            _ = state.apply(.tick(now: start + 2.5))
            _ = state.apply(.fetched(.found(.malformed(.wrongZone)), now: start + 2.5))
        case .stoppedMismatch, .saveFailed:
            _ = state.apply(.tick(now: start + 2.5))
            _ = state.apply(.fetched(.found(.response(try! PhoneHalf.response())), now: start + 2.5))
            if end == .stoppedMismatch {
                _ = state.apply(.codesDiffer)
            } else {
                _ = state.apply(.codesMatch(now: start + 3))
                _ = state.apply(.committed(false))
            }
        }
        return state
    }

    /// Rotation honesty at the end (AC7): a rotation that expires, is
    /// refused, is stopped or fails to save wrote nothing, so the paired
    /// phone's key still works — the sheet never says "Not Paired" then. Its
    /// title stays the rotation's own and the subtitle says the current
    /// pairing keeps working; the cause's line and buttons are the same as
    /// for a first pairing. A rotation that commits says "iPhone Paired"
    /// with no note (the new key replaced the old).
    @Test func aRotationThatEndsSaysTheCurrentPairingKeepsWorking() throws {
        for end in PairingEnd.allCases {
            var state = Self.ended(end, rotating: true)
            #expect(state.rotating && state.phase == .ended(end), "\(end)")
            let sheet = Self.content(state)
            #expect(sheet.screen == .ended(end) && sheet.title == "Pair a New iPhone", "\(end)")
            #expect(sheet.subtitle == "Your current pairing keeps working.", "\(end)")
            let first = Self.content(Self.ended(end))
            #expect(sheet.status == first.status && sheet.actions == first.actions && sheet.notes == first.notes, "\(end)")
            _ = state.apply(.cancel)
            #expect(state.phase == .idle, "\(end): Close ends it")
        }
        var (rotated, _) = PairingCeremonyTests.begun(rotating: true)
        _ = rotated.apply(.tick(now: Self.start + 2.5))
        _ = rotated.apply(.fetched(.found(.response(try PhoneHalf.response())), now: Self.start + 2.5))
        _ = rotated.apply(.codesMatch(now: Self.start + 3))
        _ = rotated.apply(.committed(true))
        let paired = Self.content(rotated)
        #expect(paired.screen == .paired && paired.title == "iPhone Paired" && paired.subtitle == nil)
    }

    /// Rotation honesty: the subtitle says the old key keeps working, on
    /// every screen before the commit.
    @Test func aRotationSaysTheOldPairingKeepsWorking() throws {
        let (state, _) = PairingCeremonyTests.begun(rotating: true)
        let sheet = Self.content(state)
        #expect(sheet.title == "Pair a New iPhone")
        #expect(sheet.subtitle == "Your current pairing keeps working until you confirm the new code.")
        var hidden = state
        _ = hidden.apply(.visible(false))
        #expect(Self.content(hidden).subtitle == sheet.subtitle)
    }

    // MARK: - The keyboard

    /// Every state the sheet shows, by name, first pairings and rotations.
    static func everySheetState() throws -> [(name: String, state: PairingCeremonyState)] {
        var states: [(name: String, state: PairingCeremonyState)] = []
        for rotating in [false, true] {
            let tag = rotating ? " (rotating)" : ""
            var (state, _) = PairingCeremonyTests.begun(rotating: rotating)
            states.append(("S1a" + tag, state))
            var offline = state
            _ = offline.apply(.tick(now: start + 2.5))
            _ = offline.apply(.fetched(.unreachable, now: start + 2.5))
            states.append(("S1a offline" + tag, offline))
            var hidden = state
            _ = hidden.apply(.visible(false))
            states.append(("S1b" + tag, hidden))
            _ = state.apply(.tick(now: start + 2.5))
            _ = state.apply(.fetched(.found(.response(try PhoneHalf.response())), now: start + 2.5))
            states.append(("S1c" + tag, state))
            _ = state.apply(.codesMatch(now: start + 3))
            states.append(("S1c committing" + tag, state))
            _ = state.apply(.committed(true))
            states.append(("S1d" + tag, state))
            for end in PairingEnd.allCases { states.append(("S1e \(end)" + tag, ended(end, rotating: rotating))) }
        }
        return states
    }

    /// The keyboard (design review H2): Esc presses each state's Cancel,
    /// Done or Close — in S1c, whose two buttons each decide something, a
    /// Cancel with no button of its own — and each of them only ends the
    /// sheet. No action is the default, so nothing answers Return.
    @Test func escEndsEveryStateAndNoActionIsTheDefault() throws {
        #expect(PairingSheetContent.Action.allCases.filter(\.isEscape) == [.cancel, .done, .close])
        let states = try Self.everySheetState()
        #expect(states.count == 20 && Set(states.map(\.name)).count == 20)
        for (name, state) in states {
            let sheet = Self.content(state)
            #expect(sheet.escape.isEscape, "\(name)")
            #expect(sheet.actions.filter(\.isEscape).count <= 1, "\(name): one way out")
            if sheet.screen == .compare {
                #expect(sheet.escape == .cancel && !sheet.actions.contains(.cancel), "\(name): the faceless Cancel")
            } else {
                #expect(sheet.actions.contains(sheet.escape), "\(name): Esc's button is on the sheet")
            }
        }
    }

    /// The keys on the sheet itself, hosted as the Settings window hosts it
    /// (in a window never shown; nothing is activated): in every state Return
    /// does nothing — in S1c it never commits — and Esc ends the ceremony,
    /// with no control focused.
    @Test @MainActor func onTheSheetEscEndsAndReturnNeverCommits() async throws {
        let world = PairingWorld()
        let window = NSWindow(contentViewController: NSHostingController(rootView: PairingSheetView(pairing: world.controller)))
        window.isReleasedWhenClosed = false
        func press(_ characters: String, _ keyCode: UInt16) throws -> Bool {
            window.contentView?.layoutSubtreeIfNeeded()
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: keyCode))
            return window.performKeyEquivalent(with: event)
        }
        func returnDoesNothingThenEscEnds(_ name: String) throws {
            let before = world.controller.state
            #expect(try !press("\r", 36), "\(name): nothing answers Return")
            #expect(world.controller.state == before, "\(name): Return changed nothing")
            #expect(try press("\u{1b}", 53), "\(name): Esc is bound")
            #expect(world.controller.state.phase == .idle, "\(name): Esc ended it")
        }
        let response = try PhoneHalf.response()
        func compare(at seconds: TimeInterval) async {
            world.controller.begin()
            world.records.answer(.found(.response(response)))
            await world.advance(to: seconds)
        }
        // S1a, then S1b.
        world.controller.begin()
        try returnDoesNothingThenEscEnds("S1a")
        world.controller.begin()
        world.controller.setVisible(false)
        #expect(world.controller.sheetContent.screen == .hidden)
        try returnDoesNothingThenEscEnds("S1b")
        // S1c: Return never reaches Codes Match; Esc is the faceless Cancel.
        await compare(at: 10)
        #expect(world.controller.sheetContent.screen == .compare)
        try returnDoesNothingThenEscEnds("S1c")
        #expect(!world.audits.contains(.committed) && world.items.writeCount == 0, "nothing was committed")
        // S1d, after a click on Codes Match.
        await compare(at: 20)
        world.controller.codesMatch()
        #expect(world.controller.sheetContent.screen == .paired && world.items.writeCount == 1)
        try returnDoesNothingThenEscEnds("S1d")
        // S1e, a rotation's now: Start Over is not the default either.
        world.controller.begin()
        await world.advance(to: 400)
        #expect(world.controller.sheetContent.screen == .ended(.expired) && world.controller.state.rotating)
        try returnDoesNothingThenEscEnds("S1e (rotating)")
    }

    @Test func theCountdownIsMinutesAndPaddedSeconds() {
        #expect(PairingSheetContent.countdown(secondsLeft: 300) == "Code expires in 5:00")
        #expect(PairingSheetContent.countdown(secondsLeft: 65) == "Code expires in 1:05")
        #expect(PairingSheetContent.countdown(secondsLeft: 9) == "Code expires in 0:09")
        #expect(PairingSheetContent.countdown(secondsLeft: -3) == "Code expires in 0:00")
    }

    /// The S1c variant ruling: VoiceOver's countdown is coarse — whole
    /// minutes (rounded down, never promising time), then under a minute,
    /// under 30 seconds and under 10 seconds — so it changes once a minute,
    /// then at 30 s and 10 s, never every second.
    @Test func theCountdownIsSpokenCoarsely() {
        let expected: [(Int, String)] = [
            (300, "Code expires in 5 minutes"), (299, "Code expires in 4 minutes"), (120, "Code expires in 2 minutes"),
            (119, "Code expires in 1 minute"), (60, "Code expires in 1 minute"), (59, "Code expires in under a minute"),
            (30, "Code expires in under a minute"), (29, "Code expires in under 30 seconds"),
            (10, "Code expires in under 30 seconds"), (9, "Code expires in under 10 seconds"),
            (0, "Code expires in under 10 seconds"), (-3, "Code expires in under 10 seconds"),
        ]
        for (seconds, text) in expected {
            #expect(PairingSheetContent.spokenCountdown(secondsLeft: seconds) == text, "\(seconds) s")
        }
        let changes: [Int] = (0..<300).reversed().filter {
            PairingSheetContent.spokenCountdown(secondsLeft: $0) != PairingSheetContent.spokenCountdown(secondsLeft: $0 + 1)
        }
        let marks: [Int] = [299, 239, 179, 119, 59, 29, 9]
        #expect(changes == marks, "once a minute, then at 30 s and 10 s")
    }

    // MARK: - The code (the S1c variant ruling, Variant A)

    static let code: PairingFingerprint = PairingFingerprint(lowercaseHex: "8a2c854aa45c")!

    /// The code's text is the wire's `XXXX XXXX XXXX` (what a selection
    /// copies and VoiceOver spells out); the sheet's wider gaps are
    /// kerning on the two spaces alone, and the pane's code (no gap) is
    /// plain.
    @Test func theCodeIsTheWireStringWithItsGapsKerned() {
        let gap: CGFloat = PairingSheetMetrics.codeGroupGap
        let drawn: AttributedString = PairingCodeText.drawn(Self.code, groupGap: gap)
        let text: String = String(drawn.characters)
        #expect(text == "8A2C 854A A45C" && text == Self.code.grouped)
        let texts: [String] = drawn.runs.map { String(drawn[$0.range].characters) }
        let kerns: [CGFloat?] = drawn.runs.map { $0[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] }
        let expectedTexts: [String] = ["8A2C", " ", "854A", " ", "A45C"]
        let expectedKerns: [CGFloat?] = [nil, gap, nil, gap, nil]
        #expect(texts == expectedTexts && kerns == expectedKerns, "\(texts) \(kerns)")
        let plain: AttributedString = PairingCodeText.drawn(Self.code, groupGap: 0)
        let plainText: String = String(plain.characters)
        #expect(plainText == Self.code.grouped && plain.runs.count == 1, "the pane's code is plain")
    }

    /// Variant A at the sheet's width: the large title's monospaced face,
    /// each gap about one character wider (a gap reads two spaces wide),
    /// and all twelve characters on one line inside the sheet's content
    /// width — measured with the system's own font.
    @Test func theCodeFitsOneLineWithGapsTwoSpacesWide() throws {
        let gap: CGFloat = PairingSheetMetrics.codeGroupGap
        let size: CGFloat = NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
        let face: NSFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance: CGFloat = NSAttributedString(string: " ", attributes: [.font: face]).size().width
        #expect(abs(gap - advance) <= 1, "gap \(gap) vs one character \(advance)")
        let line: NSMutableAttributedString = NSMutableAttributedString(string: Self.code.grouped, attributes: [.font: face])
        let spaces: [Int] = [4, 9]
        for offset in spaces { line.addAttribute(.kern, value: gap, range: NSRange(location: offset, length: 1)) }
        let width: CGFloat = line.size().width
        let plainWidth: CGFloat = NSAttributedString(string: Self.code.grouped, attributes: [.font: face]).size().width
        let room: CGFloat = PairingSheetMetrics.width - 2 * (PanelMetrics.loose + PanelMetrics.regular)
        #expect(width <= room, "the code (\(width) pt) fits the sheet's content width (\(room) pt) on one line, unscaled")
        #expect(abs(width - plainWidth - 2 * gap) < 0.5, "the two gaps, and only they, are wider")
    }

    /// The sheet's composition, as written: the code at the large title,
    /// with the gap; the pane's code unchanged; VoiceOver hears the wire
    /// string spelled out under the label "Code", and the countdown's
    /// coarse form, not its ticking text.
    @Test func theSheetDrawsTheCodeLargeAndSpellsItOut() throws {
        let sheet: String = MenuPanelStructureTests.flat(try MenuPanelStructureTests.code("PairingSheet.swift"))
        let panes: String = MenuPanelStructureTests.flat(try MenuPanelStructureTests.code("SettingsPanes.swift"))
        let large: String = "PairingCodeText(fingerprint: fingerprint, font: .largeTitle, groupGap: PairingSheetMetrics.codeGroupGap)"
        let code: String = "Text(Self.drawn(fingerprint, groupGap: groupGap)) .font(font.monospaced()) .lineLimit(1) "
            + ".minimumScaleFactor(0.8) .textSelection(.enabled) .accessibilityLabel(PairingSheetContent.codeLabel) "
            + ".accessibilityValue(Text(fingerprint.grouped).speechSpellsOutCharacters())"
        let countdown: String = "Text(countdown) .font(.caption) .monospacedDigit() .foregroundStyle(.secondary) "
            + ".accessibilityElement(children: .ignore) .accessibilityLabel(PairingSheetContent.spokenCountdown(secondsLeft: secondsLeft))"
        let seconds: String = "let secondsLeft: Int = pairing.state.secondsLeft(now: pairing.now.timeIntervalSince1970)"
        let shapes: [String] = [large, code, countdown, seconds]
        for shape in shapes {
            #expect(sheet.contains(shape), "the sheet lost: \(shape)")
        }
        #expect(ApprovalChannelStructureTests.count("PairingCodeText(", in: sheet) == 1, "the sheet draws the code once")
        #expect(panes.contains("PairingCodeText(fingerprint: fingerprint, font: .body)"), "the pane's code keeps its size and plain gaps")
    }

    // MARK: - Accessibility

    /// The payload is drawn and NOTHING else: no line, note, title,
    /// announcement or accessibility label of any state holds it, or any
    /// part of the nonce's encoding.
    @Test func thePayloadIsNeverSpokenOrWritten() throws {
        let payload = try #require(ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
        let encoded = String(payload.dropFirst("napcat-pair-v1:".count))
        var states: [PairingCeremonyState] = []
        var (state, _) = PairingCeremonyTests.begun()
        states.append(state)
        _ = state.apply(.visible(false))
        states.append(state)
        let (comparing, _) = try PairingCeremonyTests.comparing()
        states.append(comparing)
        var spoken: [String] = [PairingSheetContent.qrAccessibilityLabel, PairingSheetContent.codeLabel]
        for state in states {
            let sheet = Self.content(state)
            spoken += [sheet.title, sheet.status.text, PanelSeverityTint.spoken(sheet.status)] + sheet.notes
                + [sheet.subtitle, sheet.countdown].compactMap { $0 } + sheet.actions.map(\.title)
            spoken += [PairingSheetContent.announcement(from: PairingCeremonyState(), to: state, secondsBefore: 300,
                                                        secondsAfter: 299)].compactMap { $0 }
        }
        for text in spoken {
            #expect(!text.contains(payload) && !text.contains(encoded) && !text.contains("napcat-pair"), "'\(text)'")
        }
        #expect(PairingSheetContent.qrAccessibilityLabel == "Pairing code — scan it with the NapCat app on your iPhone")
    }

    /// Every transition is announced once, in its line's spoken form (the
    /// severity word first when not nominal); the code is spelled out as it
    /// appears; the countdown only at 1:00 and 0:10.
    @Test func announcementsFollowTheTransitions() throws {
        let idle = PairingCeremonyState()
        let (showing, _) = PairingCeremonyTests.begun()
        #expect(PairingSheetContent.announcement(from: idle, to: showing, secondsBefore: 0, secondsAfter: 300)
                == PairingSheetContent.waiting)
        #expect(PairingSheetContent.announcement(from: showing, to: showing, secondsBefore: 62, secondsAfter: 61) == nil)
        #expect(PairingSheetContent.announcement(from: showing, to: showing, secondsBefore: 61, secondsAfter: 60) == "Code expires in 1:00")
        #expect(PairingSheetContent.announcement(from: showing, to: showing, secondsBefore: 11, secondsAfter: 10) == "Code expires in 0:10")
        #expect(PairingSheetContent.announcement(from: showing, to: showing, secondsBefore: 10, secondsAfter: 9) == nil)
        let (comparing, candidate) = try PairingCeremonyTests.comparing()
        #expect(PairingSheetContent.announcement(from: showing, to: comparing, secondsBefore: 290, secondsAfter: 290)
                == PairingSheetContent.compareLine + " Code: " + candidate.fingerprint.spoken)
        var refused = showing
        _ = refused.apply(.tick(now: Self.start + 2.5))
        _ = refused.apply(.fetched(.found(.malformed(.wrongZone)), now: Self.start + 2.5))
        #expect(PairingSheetContent.announcement(from: showing, to: refused, secondsBefore: 290, secondsAfter: 290)
                == "Error: " + PairingSheetContent.endedLine(.refused).text)
        var closed = refused
        _ = closed.apply(.cancel)
        #expect(PairingSheetContent.announcement(from: refused, to: closed, secondsBefore: 0, secondsAfter: 0) == nil)
    }

    // MARK: - The QR as drawn

    /// The image decodes back to exactly the payload, has a white quiet zone
    /// of four modules, and is drawn at a whole number of points a module.
    @Test func theQRIsThePayloadWithAQuietZoneOnThePixelGrid() throws {
        let payload = try #require(ApprovalSigning.pairingPayload(nonce: PhoneHalf.nonce))
        let image = try #require(QRCodeView.image(payload))
        #expect(image.width == image.height)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        // Scaled up for the detector (one pixel a module is too small to read).
        let scaled = CIImage(cgImage: image).samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let decoded = detector.features(in: scaled).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(decoded == [payload], "the QR holds exactly the payload")
        // The quiet zone: four modules of white on every side.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let quiet = PairingSheetMetrics.quietModules
        for x in 0..<image.width {
            for y in 0..<image.height where x < quiet || y < quiet || x >= image.width - quiet || y >= image.height - quiet {
                let white = (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.99
                if !white { Issue.record("quiet zone pixel (\(x), \(y)) is not white"); return }
            }
        }
        let side = QRCodeView.side(modules: image.width)
        #expect(side <= PairingSheetMetrics.qrSide && side.truncatingRemainder(dividingBy: CGFloat(image.width)) == 0,
                "a whole number of points a module")
        #expect(side / CGFloat(image.width) >= 4, "at least four points a module")
        #expect(QRCodeView.side(modules: 0) == 0)
        // Drawn at the screen's pixels: every module a whole square, no
        // blended edge (only black and white), and the drawing reads back.
        let pixels = QRCodeView.pointsPerModule(modules: image.width) * QRCodeView.wholeScale(2)
        let drawn = try #require(QRCodeView.drawn(image, pixelsPerModule: pixels))
        #expect(drawn.width == image.width * pixels && drawn.height == image.height * pixels)
        let drawnBitmap = NSBitmapImageRep(cgImage: drawn)
        for x in stride(from: 0, to: drawn.width, by: 7) {
            for y in stride(from: 0, to: drawn.height, by: 7) {
                let brightness = drawnBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? -1
                if brightness > 0.01 && brightness < 0.99 { Issue.record("a blended pixel at (\(x), \(y)): \(brightness)"); return }
            }
        }
        let read = detector.features(in: CIImage(cgImage: drawn)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [payload], "the drawn QR reads back as the payload")
        #expect(QRCodeView.wholeScale(1) == 1 && QRCodeView.wholeScale(2) == 2 && QRCodeView.wholeScale(0) == 1)
    }

    // MARK: - Settings › Claude

    @Test func thePaneRowsFollowThePairingState() throws {
        let code = try #require(PairingFingerprint(lowercaseHex: "8a2c854aa45c"))
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let hint = "Pairing stores the iPhone's public key on this Mac. Nothing is armed by pairing. No prompt leaves this Mac; "
            + "while the code is up, the Mac looks for the iPhone's reply in your iCloud, and it asks iCloud to delete "
            + "that reply when the pairing ends."
        #expect(MenuStateModel.pairingRows(.notPaired) == [
            .pairingStatus(line: PanelLine(text: "Not paired — remote answers need a paired iPhone", severity: .nominal),
                           fingerprint: nil, hint: hint),
            .pairingButtons(paired: false)])
        #expect(MenuStateModel.pairingRows(.pairing) == [
            .pairingStatus(line: PanelLine(text: "Pairing — scan the code with your iPhone", severity: .nominal),
                           fingerprint: nil, hint: hint),
            .pairingButtons(paired: false)])
        #expect(MenuStateModel.pairingRows(.paired(code, since: since)) == [
            .pairingStatus(line: PanelLine(text: MenuStateModel.pairingPairedLine(since: since), severity: .nominal),
                           fingerprint: code, hint: nil),
            .pairingButtons(paired: true)])
        #expect(MenuStateModel.pairingPairedLine(since: since).hasPrefix("Paired — iPhone, since "))
        #expect(MenuStateModel.pairingRows(.rotating(code, since: since)) == [
            .pairingStatus(line: PanelLine(text: "Rotating — the current pairing keeps working until you confirm the new code",
                                           severity: .nominal), fingerprint: code, hint: nil),
            .pairingButtons(paired: true)])
        #expect([MenuStateModel.pairButtonTitle, MenuStateModel.pairNewButtonTitle, MenuStateModel.unpairButtonTitle]
                == ["Pair iPhone…", "Pair a New iPhone…", "Unpair…"])
        // #240: the confirmation says only what holds when the keychain
        // refuses the deletion.
        #expect([MenuStateModel.unpairAlertTitle, MenuStateModel.unpairAlertText, MenuStateModel.unpairAlertConfirm,
                  MenuStateModel.unpairAlertCancel] == ["Unpair iPhone?", "NapCat turns Remote approvals off and asks your "
                    + "keychain to remove this iPhone's key. If the key can't be removed, Settings tells you. Pairing again "
                    + "takes about two minutes.", "Unpair", "Cancel"])
    }

    /// #240: after the keychain refused Unpair's deletion, the pane's line
    /// is a warning — its severity word first for VoiceOver — with no code
    /// and no hint, then Try Again (spoken in full) and Pair iPhone…. Every
    /// other state's buttons are as before, with no Try Again.
    @Test func aRefusedUnpairShowsAWarningAndTryAgain() {
        let text = "Unpair failed — the iPhone's key couldn't be removed; try again in Settings › Claude"
        let line = PanelLine(text: text, severity: .warning)
        #expect(MenuStateModel.pairingStatusLine(.unpairFailed) == line)
        #expect(MenuStateModel.pairingRows(.unpairFailed) == [
            .pairingStatus(line: line, fingerprint: nil, hint: nil), .pairingButtons(paired: false, retry: true)])
        #expect(PanelSeverityTint.spoken(line) == "Warning: " + text)
        #expect(MenuStateModel.placement(ofSettingsLine: line.severity) == .topLevel, "a warning never hides in Settings")
        #expect([MenuStateModel.unpairRetryButtonTitle, MenuStateModel.unpairRetryAccessibilityLabel]
                == ["Try Again", "Try again to remove the iPhone's key"])
        let code = PairingFingerprint(lowercaseHex: "8a2c854aa45c")!
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let others: [PairingPaneState] = [.notPaired, .pairing, .paired(code, since: since), .rotating(code, since: since)]
        for pane in others {
            #expect(MenuStateModel.pairingStatusLine(pane).severity == .nominal, "\(pane)")
            #expect(MenuStateModel.pairingRows(pane).allSatisfy { row in
                if case .pairingButtons(_, let retry) = row { !retry } else { true }
            }, "\(pane): no Try Again")
        }
    }

    /// Unpair takes a deliberate click (design review M4): the alert's Unpair
    /// is marked destructive and answers no key, Cancel keeps Esc, and
    /// nothing answers Return. Unpair stays the first button (the owner's
    /// `.alertFirstButtonReturn`) wherever the alert lays it out.
    @Test @MainActor func unpairTakesADeliberateClick() throws {
        let alert = MenuContentView.unpairAlert()
        #expect(alert.messageText == MenuStateModel.unpairAlertTitle && alert.informativeText == MenuStateModel.unpairAlertText)
        #expect(alert.buttons.map(\.title) == [MenuStateModel.unpairAlertConfirm, MenuStateModel.unpairAlertCancel])
        try #require(alert.buttons.count == 2)
        let (unpair, cancel) = (alert.buttons[0], alert.buttons[1])
        #expect(unpair.hasDestructiveAction && unpair.keyEquivalent.isEmpty, "Unpair: destructive, a click and never a key")
        #expect(!cancel.hasDestructiveAction && cancel.keyEquivalent == "\u{1b}", "Esc cancels")
        #expect(!alert.buttons.contains { $0.keyEquivalent == "\r" }, "nothing answers Return")
    }

    /// The group sits in Remote approvals, after the switch and its policy
    /// line, whatever the switch says (ratified: visible while off).
    @Test func thePairingRowsCloseTheRemoteApprovalsGroup() {
        let status = PanelLine(text: "Claude: idle", severity: .nominal)
        let policy = PanelLine(text: "policy", severity: .nominal)
        for isOn in [false, true] {
            let pane = MenuStateModel.claudePane(status: status, hook: status, hookVersion: nil, awake: nil, paused: false,
                                                 approvals: (isOn: isOn, status: status, policy: policy), pairing: .notPaired)
            let rows = pane.sections.last?.rows ?? []
            #expect(pane.sections.last?.title == MenuStateModel.remoteApprovalsToggleTitle)
            #expect(Array(rows.suffix(3)) == [.line(policy)] + MenuStateModel.pairingRows(.notPaired), "isOn \(isOn)")
        }
        let without = MenuStateModel.claudePane(status: status, hook: status, hookVersion: nil, awake: nil, paused: false,
                                                approvals: (isOn: false, status: status, policy: nil))
        #expect(!(without.sections.last?.rows ?? []).contains { if case .pairingButtons = $0 { true } else { false } },
                "no controller, no rows")
    }

    // MARK: - The managed sheet seam

    @MainActor
    final class SheetLog {
        var events: [String] = []
    }

    @MainActor
    static func sheetHooks(_ log: SheetLog) -> SettingsWindowHooks {
        var hooks = SettingsWindowHooks(activate: { log.events.append("activate") }, present: { _ in log.events.append("present") },
                                        afterClose: { log.events.append("afterClose") })
        hooks.beginSheet = { _, _ in log.events.append("beginSheet") }
        hooks.endSheet = { _, _ in log.events.append("endSheet") }
        return hooks
    }

    @Test @MainActor func theWindowManagesOneSheetAndItsCloseCancels() throws {
        let suite = "com.muratalkan.napcat.tests.pairing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = DebugPowerSimulator(batteryPercent: 80, adapterConnected: true)
        let model = MenuStateModel(power: power, sleep: SleepStateController(),
                                   limiter: ChargeLimiter(power: power, isAppleSilicon: true, defaults: defaults))
        let log = SheetLog()
        let controller = SettingsWindowController(model: model, defaults: defaults, hooks: Self.sheetHooks(log))
        var closes = 0
        controller.onWillClose = { closes += 1 }
        controller.presentSheet(Text("sheet"))
        let window = try #require(controller.window)
        defer { window.delegate = nil }
        let sheet = try #require(controller.sheet)
        #expect(log.events == ["beginSheet"], "the window is built, the sheet attached — nothing activated or shown")
        #expect(sheet.contentViewController is NSHostingController<Text> && !sheet.isReleasedWhenClosed)
        controller.presentSheet(Text("another"))
        #expect(controller.sheet === sheet && log.events == ["beginSheet"], "one sheet at a time")
        controller.dismissSheet()
        #expect(controller.sheet == nil && log.events == ["beginSheet", "endSheet"])
        controller.dismissSheet()
        #expect(log.events == ["beginSheet", "endSheet"], "nothing to take off")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(closes == 1 && log.events.last == "afterClose", "the window's close reaches the ceremony first")
    }

    // MARK: - Never printed, dumped or reflected (S-PAIR-C1.5, the C1 security delta check's (b))

    /// The values that hold the code — the state machine, the event that
    /// hands the nonce in, the sheet's content and the QR view — give it away
    /// through no way of describing them (the MN1 probe built an
    /// accessibility hint from `String(describing: content)`), and reflect
    /// no part. A control: an unredacted value holding the same bytes leaks
    /// through every channel, so the probe can see a leak.
    @Test func theCodeIsNeverPrintedDumpedOrReflected() throws {
        let begin = PairingEvent.begin(nonce: PhoneHalf.nonce, rotating: false, now: Self.start)
        var state = PairingCeremonyState()
        _ = state.apply(begin)
        let content = Self.content(state)
        let payload = try #require(content.qrPayload)
        let secrets = Redaction.secrets(payload: payload, nonce: PhoneHalf.nonce)
        let values: [(String, Any)] = [("the ceremony state", state), ("the begin event", begin), ("the sheet's content", content),
                                       ("the QR view", QRCodeView(payload: payload))]
        for (name, value) in values {
            #expect(Redaction.leaks(value, secrets: secrets).isEmpty, "\(name) leaks through \(Redaction.leaks(value, secrets: secrets))")
            #expect(Mirror(reflecting: value).children.isEmpty, "\(name) reflects no part")
        }
        struct Unredacted { let payload: String; let nonce: [UInt8] }
        #expect(Redaction.leaks(Unredacted(payload: payload, nonce: PhoneHalf.nonce), secrets: secrets).count == 5,
                "vacuity: an unredacted value leaks through all five channels")
    }

    /// The owner wires the sheet to the ceremony, the window's close to its
    /// Cancel, the sheet's visibility to S1b, Unpair to its alert, and the
    /// slot's read to Settings opening, before the model's refresh.
    @Test func theOwnerWiresTheSheetToTheCeremony() throws {
        let owner = MenuPanelStructureTests.flat(try MenuPanelStructureTests.code("MenuContentView.swift"))
        for wiring in ["if showing { settingsWindow.presentSheet(PairingSheetView(pairing: pairing)) } else { settingsWindow.dismissSheet() }",
                       "settingsWindow.onSheetVisible = { [weak pairing] in pairing?.setVisible($0) }",
                       "settingsWindow.onWillClose = { [weak pairing] in pairing?.cancel() }",
                       "model.requestUnpair = { [weak self] in self?.confirmUnpair() }",
                       "pairing.announce = { Pairing" + "Announcer.post($0) }",
                       "let alert = Self.unpairAlert() guard alert.runModal() == .alertFirstButtonReturn else { return }"
                        + " pairing?.unpair() model.refresh()",
                       "pairing?.refreshPaired() model.refresh() }"] {
            #expect(owner.contains(wiring), "missing: \(wiring)")
        }
    }
}
