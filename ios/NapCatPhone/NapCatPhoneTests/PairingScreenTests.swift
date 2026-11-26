import AVFoundation
import Foundation
@testable import NapCatPhone
import SwiftUI
import Testing
import UIKit

/// The pairing screen's words, offers and wiring (F4 slice S-PAIR-B).
/// SwiftUI composition cannot be driven headlessly, so the wiring is
/// locked over the source, each lock run against mutated copies.
@MainActor
@Suite struct PairingScreenTests {
    static let fingerprint = KeyFingerprint(publicKey: [0x04] + Array(repeating: UInt8(7), count: 64))!
    static let until = Date(timeIntervalSince1970: 1_800_000_300)

    static let everyPhase: [PairingCeremony.Phase] = [.scanning, .refused, .confirming, .saving, .waiting(fingerprint, until: until),
                                                      .paired(fingerprint), .cancelled, .expired]
        + PairingCeremony.Failure.allCases.map { .failed($0) }

    nonisolated static let faceID = BiometricAvailability.available(.faceID)
    /// Every way the match can't happen: each biometric a phone can have,
    /// and none.
    nonisolated static let everyUnavailable = BiometryKind.allCases.map { BiometricAvailability.unavailable($0) } + [.unavailable(nil)]

    static func line(_ phase: PairingCeremony.Phase, _ camera: CameraState = .ready,
                     _ biometry: BiometricAvailability = faceID) -> PhoneLine {
        PairingScreen.line(for: phase, camera: camera, biometry: biometry)
    }

    static func offer(_ phase: PairingCeremony.Phase, _ camera: CameraState = .ready,
                      _ biometry: BiometricAvailability = faceID) -> PairingScreen.Offer {
        PairingScreen.offer(for: phase, camera: camera, biometry: biometry)
    }

    /// Every phase with every camera state that can go with it, and the
    /// start on a phone whose match can't happen.
    static var everyLine: [PhoneLine] {
        CameraState.allCases.map { line(.scanning, $0) }
            + everyPhase.dropFirst().map { line($0) }
            + everyUnavailable.map { line(.scanning, .ready, $0) }
    }

    // MARK: The words

    @Test func everyLineIsInTheCaptionRegister() {
        let confirming = (BiometryKind.allCases.map { BiometricAvailability.available($0) } + Self.everyUnavailable)
            .map { Self.line(.confirming, .ready, $0) }
        for line in Self.everyLine + confirming {
            #expect(ListStateTests.captionRegisterFailures(line.text).isEmpty, "\(ListStateTests.captionRegisterFailures(line.text))")
        }
    }

    /// Every state reads differently in words alone.
    @Test func everyStateReadsDifferently() {
        #expect(Set(Self.everyLine.map(\.text)).count == Self.everyLine.count)
    }

    @Test func theLinesSayExactlyThis() {
        func text(_ phase: PairingCeremony.Phase, _ camera: CameraState = .ready) -> String {
            Self.line(phase, camera).text
        }
        #expect(text(.waiting(Self.fingerprint, until: Self.until)) == "Waiting — confirm the code on your Mac")
        #expect(text(.paired(Self.fingerprint)) == "Paired — this iPhone signs its answers with this key")
        #expect(text(.scanning) == "Scanning — point the camera at the code on your Mac")
        #expect(text(.scanning, .notAsked) == "Needed — NapCat uses the camera only to read the code on your Mac")
        #expect(text(.scanning, .off) == "Off — camera access is off for NapCat; turn it on in Settings to scan")
        #expect(text(.scanning, .unsupported) == "Unavailable — this iPhone can't scan codes")
        #expect(text(.confirming) == "Confirming — waiting for Face ID")
        #expect(Self.line(.confirming, .ready, .available(.touchID)).text == "Confirming — waiting for Touch ID")
        #expect(Self.line(.confirming, .ready, .unavailable(nil)).text == "Confirming — waiting for the biometric match")
        #expect(text(.refused) == "Refused — that isn't a NapCat pairing code; nothing was saved")
        #expect(text(.failed(.alreadyAnswered)) == "Refused — this code was already answered; start again on your Mac")
        #expect(text(.failed(.notConfirmed)) == "Unverified — pairing wasn't confirmed, so nothing was saved")
        #expect(text(.failed(.noCamera)) == "Unavailable — the camera couldn't scan; nothing was saved")
        #expect(text(.cancelled) == "Cancelled — nothing changed on this iPhone")
        #expect(text(.expired) == "Expired — the code's five minutes ran out; start again on your Mac")
        #expect(PairingScreen.privateNote == "Pair in private: the code on your Mac is a secret while it's on screen.")
        #expect(PairingCeremony.reason == "Confirm it's you to pair this iPhone with your Mac.")
        #expect(PairingScreen.matchUnavailable(.faceID).text
                == "Unavailable — pairing needs Face ID turned on; set it up in Settings › Face ID & Passcode")
        #expect(PairingScreen.matchUnavailable(.touchID).text
                == "Unavailable — pairing needs Touch ID turned on; set it up in Settings › Touch ID & Passcode")
        #expect(PairingScreen.matchUnavailable(nil).text == "Unavailable — this iPhone can't confirm a pairing with biometrics")
    }

    /// The comparison is the step that catches a code that isn't the
    /// owner's Mac's, so its hint says what to do when the codes differ as
    /// well as when they match.
    @Test func theCompareHintSaysWhatToDoEitherWay() {
        let hint: String = "Your Mac is showing a code too. If all three groups match, confirm on your Mac first — "
            + "then tap Codes Match here. If they don't match, tap Codes Don't Match here and on your Mac; nothing is paired."
        #expect(PairingScreen.compareHint == hint)
        #expect(PairingScreen.compareHint.contains("If all three groups match"), "the totality cue, as on the Mac")
        #expect(PairingScreen.compareHint.contains("confirm on your Mac first"), "the Mac confirms first")
        #expect(PairingScreen.compareHint.contains("tap \(PairingScreen.matchTitle) here"))
        #expect(PairingScreen.compareHint.contains("If they don't match, tap \(PairingScreen.mismatchTitle) here and on your Mac"))
    }

    /// The compare step's buttons say what the Mac's say, word for word,
    /// read from the Mac's own source (the S1c variant ruling: identical
    /// button labels), and so does the totality cue.
    @Test func theCompareButtonsAreTheMacs() throws {
        let titles: [String] = [PairingScreen.matchTitle, PairingScreen.mismatchTitle]
        let expected: [String] = ["Codes Match", "Codes Don't Match"]
        #expect(titles == expected)
        let mac: [CloudKitStructureTests.Source] = try CloudKitStructureTests.swiftFiles(under: "Sources/NapCat")
        let sheet: String = try #require(mac.first { $0.path == "Sources/NapCat/PairingSheet.swift" }).text
        let macMatch: String = "case .codesMatch: return \"\(PairingScreen.matchTitle)\""
        let macMismatch: String = "case .theyDontMatch: return \"\(PairingScreen.mismatchTitle)\""
        #expect(sheet.contains(macMatch) && sheet.contains(macMismatch), "the Mac's labels drifted from the phone's")
        #expect(sheet.contains("If all three groups match, confirm here first, then on your iPhone."))
    }

    // MARK: The code (the S1c variant ruling's phone mirror)

    /// The code's text is the Mac's `XXXX XXXX XXXX`; the wide gaps are
    /// kerning on the two spaces alone.
    @Test func theCodeIsTheMacsStringWithItsGapsKerned() {
        let gap: CGFloat = PairingScreen.codeGroupGap
        let drawn: AttributedString = PairingScreen.drawnCode(Self.fingerprint, groupGap: gap)
        let groups: [String] = Self.fingerprint.groups
        #expect(String(drawn.characters) == Self.fingerprint.grouped && Self.fingerprint.grouped == groups.joined(separator: " "))
        let texts: [String] = drawn.runs.map { String(drawn[$0.range].characters) }
        let kerns: [CGFloat?] = drawn.runs.map { $0[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] }
        let expectedTexts: [String] = [groups[0], " ", groups[1], " ", groups[2]]
        let expectedKerns: [CGFloat?] = [nil, gap, nil, gap, nil]
        #expect(texts == expectedTexts && kerns == expectedKerns, "\(texts) \(kerns)")
    }

    /// The Mac's face (the system's monospaced, regular — not the title's
    /// bold), each gap about one character wider (the Mac's ratio: a gap
    /// reads two spaces wide), and one line inside the card at the default
    /// text size on the narrowest iPhone (375 pt) — measured with the
    /// system's own font.
    @Test func theCodeFitsOneLineWithTheMacsFaceAndGapRatio() {
        let theme: Theme = ThemeID.fallback.theme
        let macFace: Font = .system(.title, design: .monospaced)
        #expect(theme.codeFont == macFace, "the Mac's face, at the phone's title size")
        let traits: UITraitCollection = UITraitCollection(preferredContentSizeCategory: .large)
        let size: CGFloat = UIFont.preferredFont(forTextStyle: .title1, compatibleWith: traits).pointSize
        let face: UIFont = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance: CGFloat = NSAttributedString(string: " ", attributes: [.font: face]).size().width
        let gap: CGFloat = PairingScreen.codeGroupGap
        #expect(abs(gap - advance) <= 1, "gap \(gap) vs one character \(advance)")
        let line: NSMutableAttributedString = NSMutableAttributedString(string: Self.fingerprint.grouped, attributes: [.font: face])
        let spaces: [Int] = [4, 9]
        for offset in spaces { line.addAttribute(.kern, value: gap, range: NSRange(location: offset, length: 1)) }
        let width: CGFloat = line.size().width
        let room: CGFloat = 375 - 2 * theme.margin - 2 * theme.rowPadding
        #expect(width <= room, "the code (\(width) pt) fits the card (\(room) pt) on one line")
    }

    /// The card's composition, as written: the code in its face and its
    /// gaps (scaled with the text size), one line while it fits and broken
    /// only between groups past that, the Codes Don't Match label on the
    /// cancel, and VoiceOver hearing the code's own text spelled out under
    /// the card's header. Each canary is caught.
    static func codeFailures(screen: String) -> [String] {
        let flat: String = SettingsReachabilityTests.flat(CloudKitStructureTests.codeOnly(screen))
        guard flat.contains("struct PairingScreen: View {") else { return ["the screen moved (the lock would be vacuous)"] }
        let fits: String = "ViewThatFits(in: .horizontal) { codeText(fingerprint).lineLimit(1) "
            + "codeText(fingerprint).fixedSize(horizontal: false, vertical: true) }"
        let spoken: String = ".themedCard(castsShadow: !muted) .accessibilityElement(children: .ignore) .accessibilityLabel(Self.codeHeader) "
            + ".accessibilityValue(Text(verbatim: fingerprint.grouped).speechSpellsOutCharacters())"
        let drawn: String = "Text(Self.drawnCode(fingerprint, groupGap: codeGap)).font(theme.codeFont)"
        let scaled: String = "@ScaledMetric(relativeTo: .title) private var codeGap: CGFloat = PairingScreen.codeGroupGap"
        let deny: String = "Button(action: cancel) { Label(Self.mismatchTitle, systemImage: Self.cancelSymbol) }"
        let shapes: [String] = [fits, spoken, drawn, scaled, deny]
        return shapes.filter { !flat.contains($0) }.map { "the pairing screen lost '\($0)'" }
    }

    @Test func theCodeIsDrawnAndSpokenAsOnTheMac() throws {
        let app: [CloudKitStructureTests.Source] = try CloudKitStructureTests.swiftFiles(under: Self.appDir)
        let screen: String = try #require(app.first { $0.path == Self.screenFile }).text
        #expect(Self.codeFailures(screen: screen).isEmpty, "\(Self.codeFailures(screen: screen))")
        let mutants: [(String, String)] = [
            ("the title's bold face", screen.replacingOccurrences(of: ".font(theme.codeFont)", with: ".font(theme.titleFont)")),
            ("the code wraps at any size", screen.replacingOccurrences(of: "codeText(fingerprint).lineLimit(1)", with: "codeText(fingerprint)")),
            ("spoken as a word", screen.replacingOccurrences(of: ".speechSpellsOutCharacters())", with: ")")),
            ("the deny back to Cancel", screen.replacingOccurrences(of: "Label(Self.mismatchTitle,", with: "Label(\"Cancel\",")),
            ("fixed gaps", screen.replacingOccurrences(of: "@ScaledMetric(relativeTo: .title) private var codeGap",
                                                       with: "private var codeGap")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != screen, "canary '\(name)' did not apply")
            #expect(!Self.codeFailures(screen: mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    /// On a phone whose biometric match can't happen, the start names the
    /// cause and where to set it up, offers no scan (so no ceremony ends in
    /// "Unverified" with only Scan Again), and outranks the camera: whatever
    /// the camera says, nothing could be confirmed. Only the biometric this
    /// phone has is named.
    @Test(arguments: everyUnavailable)
    func noMatchNoScanAndTheCauseIsNamed(_ biometry: BiometricAvailability) {
        for camera in CameraState.allCases {
            #expect(Self.line(.scanning, camera, biometry) == PairingScreen.matchUnavailable(biometry.kind), "\(camera)")
            #expect(Self.offer(.scanning, camera, biometry) == PairingScreen.Offer.none, "\(camera)")
        }
        let line = PairingScreen.matchUnavailable(biometry.kind)
        #expect(line.severity == .warning)
        #expect(line.text.hasPrefix("Unavailable — "))
        #expect(!line.text.contains("Unverified") && !line.text.contains("Scan Again"))
        for kind in BiometryKind.allCases {
            #expect(line.text.contains(kind.name) == (kind == biometry.kind), "'\(line.text)' and \(kind.name)")
        }
        if let kind = biometry.kind {
            #expect(line.text.contains("Settings › \(kind.name) & Passcode"), "the line points to the setup")
        }
        // Only the start depends on it: the phases after the scan say what
        // they said.
        for phase in Self.everyPhase.dropFirst() where phase != .confirming {
            #expect(Self.line(phase, .ready, biometry) == Self.line(phase), "\(phase)")
            #expect(Self.offer(phase, .ready, biometry) == Self.offer(phase), "\(phase)")
        }
    }

    /// "Paired" is said in the paired phase alone, and no line claims what
    /// the Mac did: the phone knows only its own half.
    @Test func onlyThePairedPhaseSaysPaired() {
        for phase in Self.everyPhase {
            let line = Self.line(phase).text
            if case .paired = phase {
                #expect(line.hasPrefix("Paired — "))
            } else {
                #expect(!line.contains("Paired") && !line.contains("paired"), "'\(line)' says paired before the confirm")
            }
            for claim in ["Mac paired", "Mac accepted", "Mac confirmed", "Mac stored", "Allowed", "Approved"] {
                #expect(!line.contains(claim), "'\(line)' claims what the Mac did")
            }
        }
    }

    /// Failures are warnings; a cancel or the window's end is said quietly.
    @Test func severitiesMatchWhatHappened() {
        for failure in PairingCeremony.Failure.allCases {
            #expect(PairingScreen.failureLine(failure).severity == .warning)
        }
        #expect(Self.line(.cancelled).severity == .info)
        #expect(Self.line(.expired).severity == .info)
        #expect(Self.line(.scanning, .off).severity == .warning)
        #expect(Self.line(.waiting(Self.fingerprint, until: Self.until)).severity == .nominal)
        #expect(Self.everyUnavailable.allSatisfy { Self.line(.scanning, .ready, $0).severity == .warning })
    }

    // MARK: The offers

    @Test func eachPhaseOffersWhatItCan() {
        #expect(Self.offer(.scanning, .ready) == .viewfinder)
        #expect(Self.offer(.scanning, .notAsked) == .askCamera)
        #expect(Self.offer(.scanning, .off) == .settings)
        #expect(Self.offer(.scanning, .unsupported) == PairingScreen.Offer.none)
        #expect(Self.offer(.waiting(Self.fingerprint, until: Self.until)) == .compare)
        for phase in [PairingCeremony.Phase.confirming, .saving, .paired(Self.fingerprint)] {
            #expect(Self.offer(phase) == PairingScreen.Offer.none, "\(phase)")
        }
        for phase in [PairingCeremony.Phase.refused, .cancelled, .expired] + PairingCeremony.Failure.allCases.map({ .failed($0) }) {
            #expect(Self.offer(phase) == .again, "\(phase)")
        }
        // The camera matters while scanning only.
        #expect(Self.offer(.waiting(Self.fingerprint, until: Self.until), .off) == .compare)
    }

    // MARK: The camera's reading

    /// VisionKit's support, the camera's authorization, VisionKit's
    /// availability, and what the live camera reads as: every combination.
    typealias CameraReading = (supported: Bool, authorization: AVAuthorizationStatus, available: Bool, reads: CameraState)
    static let cameraReadings: [CameraReading] = [
        (true, .authorized, true, .ready), (true, .authorized, false, .unsupported),
        (true, .notDetermined, true, .notAsked), (true, .notDetermined, false, .notAsked),
        (true, .denied, true, .off), (true, .denied, false, .off),
        (true, .restricted, true, .off), (true, .restricted, false, .off),
        (false, .authorized, true, .unsupported), (false, .authorized, false, .unsupported),
        (false, .notDetermined, true, .unsupported), (false, .notDetermined, false, .unsupported),
        (false, .denied, true, .unsupported), (false, .denied, false, .unsupported),
        (false, .restricted, true, .unsupported), (false, .restricted, false, .unsupported),
    ]

    /// The live camera's reading (the S-PAIR-C1.6 design review, M2): a
    /// camera NapCat may use that VisionKit still can't scan with reads as
    /// unsupported, so its line never says access is off and nothing sends
    /// the owner to Settings; only a refusal or a restriction reads as off.
    @Test func anAllowedCameraIsNeverSaidToBeOff() {
        for row in Self.cameraReadings {
            let reads = LiveCameraAccess.state(supported: row.supported, authorization: row.authorization, available: row.available)
            #expect(reads == row.reads, "\(row)")
        }
        let allowed = LiveCameraAccess.state(supported: true, authorization: .authorized, available: false)
        #expect(Self.line(.scanning, allowed).text == "Unavailable — this iPhone can't scan codes")
        #expect(Self.offer(.scanning, allowed) == PairingScreen.Offer.none)
    }

    // MARK: What VoiceOver hears

    /// The code appearing and every end are announced, once, in their own
    /// line's words (a failure as a warning); the steps under way are not
    /// (the system's biometric prompt speaks for itself), and nothing is
    /// announced without a change.
    @Test func theCodeAndEveryEndAreAnnounced() {
        let waiting = PairingCeremony.Phase.waiting(Self.fingerprint, until: Self.until)
        func announced(_ old: PairingCeremony.Phase, _ new: PairingCeremony.Phase) -> String? {
            PairingScreen.announcement(from: old, to: new, camera: .ready, biometry: Self.faceID)
        }
        #expect(announced(.saving, waiting) == "Waiting — confirm the code on your Mac")
        #expect(announced(waiting, .paired(Self.fingerprint)) == "Paired — this iPhone signs its answers with this key")
        #expect(announced(.confirming, .failed(.notConfirmed))
                == "Warning: Unverified — pairing wasn't confirmed, so nothing was saved")
        #expect(announced(.scanning, .refused) == "Warning: Refused — that isn't a NapCat pairing code; nothing was saved")
        for old in Self.everyPhase {
            for new in Self.everyPhase {
                let spoken = announced(old, new)
                switch new {
                case _ where old == new:
                    #expect(spoken == nil, "\(old) → \(new) is announced without a change")
                case .waiting, .paired, .refused, .failed, .cancelled, .expired:
                    #expect(spoken == Self.line(new).spoken, "\(old) → \(new)")
                case .scanning, .confirming, .saving:
                    #expect(spoken == nil, "\(old) → \(new) is announced")
                }
            }
        }
    }

    /// The code is shown while it is compared and once kept, never before
    /// the response is saved, and never after a failure.
    @Test func theCodeIsShownOnlyWhenItIsThePhonesOwnAndSaved() {
        for phase in Self.everyPhase {
            let shown = PairingScreen.fingerprint(in: phase)
            switch phase {
            case .waiting, .paired: #expect(shown == Self.fingerprint)
            default: #expect(shown == nil, "\(phase)")
            }
        }
        #expect(String(PairingScreen.drawnCode(Self.fingerprint, groupGap: PairingScreen.codeGroupGap).characters)
                == Self.fingerprint.grouped)
    }

    @Test func theNoteIsSaidWhileACodeMayBeOnScreen() {
        for phase in Self.everyPhase {
            let expected: Bool = switch phase {
            case .scanning, .confirming, .saving, .waiting: true
            default: false
            }
            #expect(PairingScreen.showsPrivateNote(phase) == expected, "\(phase)")
        }
    }

    @Test func theGlyphsAreSystemSymbols() {
        for name in [PairingScreen.matchSymbol, PairingScreen.cancelSymbol, PairingScreen.cameraSymbol, PairingScreen.scanSymbol,
                     PairingScreen.pairedSymbol] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
        #expect(PairingScreen.settingsURL?.absoluteString == UIApplication.openSettingsURLString)
    }

    // MARK: The launch argument

    @Test func thePairingArgumentOpensAFixturePairingAndNothingElse() {
        for state in FixturePairingState.allCases {
            let options = LaunchOptions { $0 == LaunchOptions.pairingKey ? state.rawValue : nil }
            var expected = LaunchOptions()
            expected.pairing = state
            #expect(options == expected)
            #expect(options.fixtureRequested == false && options.request == nil)
        }
        #expect(LaunchOptions { $0 == LaunchOptions.pairingKey ? "paired" : nil } == LaunchOptions())
        #expect(LaunchOptions().pairing == nil)
        #expect(LaunchOptions { $0 == LaunchOptions.pairingKey ? "noCamera" : nil }.pairing == .noCamera, "the README's spelling (#175)")
        for state in [FixtureRequestState.unpaired, .changed] {
            #expect(LaunchOptions { $0 == LaunchOptions.requestKey ? state.rawValue : nil }.request == state)
        }
    }

    // MARK: The wiring (source locks)

    static let appDir = CloudKitStructureTests.appDir
    static let screenFile = "\(appDir)/Screen/PairingScreen.swift"
    static let rootFile = "\(appDir)/NapCatPhoneApp.swift"

    /// The screen hands everything to its closures and reaches nothing
    /// itself (no keyring, writer, gate or ceremony call); the live scanner
    /// is drawn only for a live camera and only while the offer is the
    /// viewfinder (which a match that can't happen withholds); Codes Match
    /// and Cancel are offered together, only while comparing; the code and
    /// every end are announced at high priority. The sheet routes each
    /// closure to its ceremony call, hands the screen the ceremony's own
    /// reading of the biometrics and re-reads them as it appears and on
    /// every return; Close, the window's end or a sheet closed any other way
    /// cancel, and a swipe down can't close it while the ceremony is under
    /// way. The root opens it for the fixture launch only, in the palette.
    static func wiringFailures(screen: String, root: String) -> [String] {
        let flat = SettingsReachabilityTests.flat(screen)
        var failures: [String] = []
        guard let screenBody = CloudKitStructureTests.body(after: "struct PairingScreen: View {", in: CloudKitStructureTests.codeOnly(screen))
        else { return ["the screen moved (the lock would be vacuous)"] }
        for token in ["keyring", "writer", "BiometricGate", "confirm(reason", "ceremony", "commitProvisional", "PhoneKeyring"]
        where screenBody.contains(token) {
            failures.append("'\(token)' in the screen — it only hands its answers to its closures")
        }
        for shape in ["} .frame(maxWidth: .infinity, alignment: .leading) .padding(.horizontal, theme.margin)",
                      "if Self.offer(for: phase, camera: camera, biometry: biometry) == .viewfinder { viewfinder }",
                      "if liveCamera { QRScannerView(scanned: scanned, failed: scanFailed) } else {",
                      "case .compare: Button(action: confirm) { Label(Self.matchTitle, systemImage: Self.matchSymbol) } "
                        + ".buttonStyle(RequestButtonStyle(emphasis: .accent)) Button(action: cancel) {",
                      ".onChange(of: phase) { old, new in "
                        + "guard let text = Self.announcement(from: old, to: new, camera: camera, biometry: biometry) else { return } "
                        + "var spoken = AttributedString(text) spoken.accessibilitySpeechAnnouncementPriority = .high "
                        + "AccessibilityNotification.Announcement(spoken).post() }",
                      "PairingScreen(phase: ceremony.phase, camera: cameraState, biometry: ceremony.biometry,",
                      "scanned: { code in Task { await ceremony.scanned(code) } }",
                      "confirm: { ceremony.confirmCodesMatch() }", "cancel: { ceremony.cancel() }", "again: { ceremony.restart() }",
                      "Button(PairingScreen.closeTitle) { ceremony.cancel() dismiss() }",
                      ".interactiveDismissDisabled(!ceremony.phase.isFinal) .onAppear { ceremony.refreshBiometry() } "
                        + ".onDisappear { ceremony.cancel() }",
                      "guard phase == .active else { return } cameraState = camera.state() ceremony.refreshBiometry() ceremony.tick()",
                      ".task(id: ceremony.deadline) { await Self.follow(ceremony, clock: clock) }"]
        where !flat.contains(shape) {
            failures.append("the pairing screen lost '\(shape)'")
        }
        if CloudKitStructureTests.occurrences(of: "QRScannerView(", in: flat) != 1 {
            failures.append("the live scanner is drawn in one place")
        }
        let rootFlat = SettingsReachabilityTests.flat(root)
        let sheet = ".sheet(isPresented: $showsPairing) { if let pairing { PairingSheet(ceremony: pairing.ceremony, camera: pairing.camera) } }"
        if let sheetRange = rootFlat.range(of: sheet), let palette = rootFlat.range(of: SettingsReachabilityTests.palette) {
            if palette.lowerBound < sheetRange.upperBound { failures.append("the pairing sheet must be drawn in the palette") }
        } else {
            failures.append("the root lost the pairing sheet, or the palette")
        }
        for shape in ["private let pairing = FixturePairing.make(options: LaunchOptions.fromLaunchArguments())",
                      "_showsPairing = State(initialValue: pairing != nil && !opensSettings)"]
        where !rootFlat.contains(shape) {
            failures.append("the root lost '\(shape)'")
        }
        if CloudKitStructureTests.occurrences(of: "PairingSheet(", in: rootFlat) != 1 {
            failures.append("the pairing sheet opens in one place")
        }
        return failures
    }

    @Test func thePairingScreenIsWiredThroughItsCeremonyOnly() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.appDir)
        let screen = try #require(app.first { $0.path == Self.screenFile }).text
        let root = try #require(app.first { $0.path == Self.rootFile }).text
        #expect(Self.wiringFailures(screen: screen, root: root).isEmpty, "\(Self.wiringFailures(screen: screen, root: root))")
        let mutants: [(String, String, String)] = [
            ("the live camera always", screen.replacingOccurrences(of: "if liveCamera {", with: "if true {"), root),
            ("the viewfinder in every phase", screen.replacingOccurrences(
                of: "if Self.offer(for: phase, camera: camera, biometry: biometry) == .viewfinder {", with: "if true {"), root),
            ("the viewfinder with no match possible", screen.replacingOccurrences(
                of: "if Self.offer(for: phase, camera: camera, biometry: biometry) == .viewfinder {",
                with: "if Self.offer(for: phase, camera: camera, biometry: .available(.faceID)) == .viewfinder {"), root),
            ("the screen told Face ID is on", screen.replacingOccurrences(of: "biometry: ceremony.biometry,",
                                                                          with: "biometry: .available(.faceID),"), root),
            ("the biometrics read once", screen.replacingOccurrences(of: "            ceremony.refreshBiometry()\n", with: ""), root),
            ("a swipe closes a ceremony under way", screen.replacingOccurrences(
                of: "        .interactiveDismissDisabled(!ceremony.phase.isFinal)\n", with: ""), root),
            ("no swipe even once it ended", screen.replacingOccurrences(
                of: ".interactiveDismissDisabled(!ceremony.phase.isFinal)", with: ".interactiveDismissDisabled()"), root),
            ("a column that hugs its lines", screen.replacingOccurrences(
                of: "            .frame(maxWidth: .infinity, alignment: .leading)\n            .padding(.horizontal, theme.margin)\n",
                with: "            .padding(.horizontal, theme.margin)\n"), root),
            ("the code not announced", screen.replacingOccurrences(of: "AccessibilityNotification.Announcement(spoken).post()",
                                                                   with: ""), root),
            ("Codes Match wired to Cancel", screen.replacingOccurrences(of: "confirm: { ceremony.confirmCodesMatch() }",
                                                                       with: "confirm: { ceremony.cancel() }"), root),
            ("the screen commits the key", screen.replacingOccurrences(of: "    @Environment(\\.openURL) private var openURL\n",
                                                                      with: "    @Environment(\\.openURL) private var openURL\n    let keyring: PhoneKeyring\n"), root),
            ("Close keeps the ceremony", screen.replacingOccurrences(of: "                            ceremony.cancel()\n                            dismiss()",
                                                                    with: "                            dismiss()"), root),
            ("a swipe keeps the ceremony", screen.replacingOccurrences(of: ".onDisappear { ceremony.cancel() }", with: ""), root),
            ("no window clock", screen.replacingOccurrences(of: "        .task(id: ceremony.deadline) { await Self.follow(ceremony, clock: clock) }\n",
                                                           with: ""), root),
            ("the pairing sheet outside the palette", screen, root.replacingOccurrences(
                of: "        .environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n", with: "")
                .replacingOccurrences(of: "        .sheet(isPresented: $showsPairing) {",
                                      with: "        .environment(\\.theme, ThemeID.fallback.theme(palette: palette))\n        .sheet(isPresented: $showsPairing) {")),
            ("a pairing for every launch", screen, root.replacingOccurrences(of: "_showsPairing = State(initialValue: pairing != nil && !opensSettings)",
                                                                            with: "_showsPairing = State(initialValue: true)")),
        ]
        for (name, mutantScreen, mutantRoot) in mutants {
            #expect(mutantScreen != screen || mutantRoot != root, "canary '\(name)' did not apply")
            #expect(!Self.wiringFailures(screen: mutantScreen, root: mutantRoot).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: A scanner that won't start, or stops mid-scan

    static let scannerFile = "\(appDir)/Live/QRScanner.swift"
    /// The scanner's start, whole: VisionKit's refusal is reported on the
    /// next turn, never dropped and never inside the view update.
    static let startHead = "func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {"
    static let startBody: String = "guard !context.coordinator.handedOn, !scanner.isScanning else { return } "
        + "do { try scanner.startScanning() } catch { Task { failed() } }"
    static let scannerHandOn = "if liveCamera { QRScannerView(scanned: scanned, failed: scanFailed) } else {"
    /// AMENDED (#175): and the `noCamera` fixture launch, which opens on
    /// that ending: its own fixture ceremony, on its one line.
    static let fixtureEnding: String = "if state == .noCamera { ceremony.scannerFailed() }"
    static let scanFailureSites = CloudKitStructureTests.appSites([
        "Model/PairingCeremony.swift": ["func scannerFailed() {": 1],
        "Screen/PairingScreen.swift": ["scanFailed: { ceremony.scannerFailed() },": 1],
        "Fixtures/FixturePairing.swift": [fixtureEnding: 1],
    ])
    /// AMENDED (#175, the C1.6 design review's ledger): VisionKit stopping
    /// the scanner mid-scan is reported by the same closure, the same way
    /// (on the next turn, never dropped), and only before the hand-on. The
    /// coordinator is built with the screen's failure and keeps it as
    /// handed; its callback is pinned whole.
    static let coordinatorShape: String = "func makeCoordinator() -> Coordinator { " + PairingEntryStructureTests.coordinatorBuilt + " }"
    static let coordinatorInitShape: String = PairingEntryStructureTests.coordinatorInit + " self.scanned = scanned self.failed = failed }"
    static let stoppedHead: String = "func dataScanner(_: DataScannerViewController, becameUnavailableWithError _: "
        + "DataScannerViewController.ScanningUnavailable) {"
    static let stoppedBody: String = "guard !handedOn else { return } Task { failed() }"

    /// The S-PAIR-C1.6 design review's M2: a scanner VisionKit won't start
    /// ends the ceremony at its start (its failure line, Scan Again, Close),
    /// never a dark viewfinder under "Scanning". The scanner reports it, the
    /// screen hands it on, and the sheet alone routes it to the ceremony.
    /// AMENDED (#175): and so does a scanner VisionKit stops mid-scan.
    static func scanFailureFailures(_ app: [CloudKitStructureTests.Source]) -> [String] {
        var failures: [String] = []
        let scanner = CloudKitStructureTests.codeOnly(app.first { $0.path == scannerFile }?.text ?? "")
        if CloudKitStructureTests.body(after: startHead, in: scanner).map(SettingsReachabilityTests.flat) != startBody {
            failures.append("the scanner reports a start VisionKit refuses, on the next turn — exactly as pinned")
        }
        if CloudKitStructureTests.body(after: stoppedHead, in: scanner).map(SettingsReachabilityTests.flat) != stoppedBody {
            failures.append("the scanner reports VisionKit stopping it before the hand-on, on the next turn — exactly as pinned")
        }
        let scannerFlat: String = SettingsReachabilityTests.flat(scanner)
        let coordinatorShapes: [String] = [coordinatorShape, coordinatorInitShape]
        for shape in coordinatorShapes where !scannerFlat.contains(shape) {
            failures.append("the scanner's coordinator lost '\(shape)'")
        }
        if CloudKitStructureTests.hits(#"\btry\?"#, in: scanner) {
            failures.append("the scanner drops a failure (try?)")
        }
        if !SettingsReachabilityTests.flat(app.first { $0.path == screenFile }?.text ?? "").contains(scannerHandOn) {
            failures.append("the screen hands the live scanner its failure")
        }
        let stripped: [CloudKitStructureTests.Source] = app.map { ($0.path, CloudKitStructureTests.codeOnly($0.text)) }
        failures += CloudKitStructureTests.appSiteFailures(#"\bscannerFailed\b"#, in: stripped, allowed: scanFailureSites,
                                                           rule: "a scanner that won't start ends the ceremony from the sheet alone "
                                                               + "(and the fixture that opens on that ending)")
        return failures
    }

    @Test func aScannerThatWontStartIsSaidNotLeftDark() throws {
        let app = try CloudKitStructureTests.swiftFiles(under: Self.appDir)
        #expect(app.contains { $0.path == Self.scannerFile }, "vacuity: the scanner is where the lock looks")
        #expect(Self.scanFailureFailures(app).isEmpty, "\(Self.scanFailureFailures(app))")
        let scanner = Self.scannerFile
        let screen = Self.screenFile
        let mutants: [(String, [CloudKitStructureTests.Source])] = [
            ("the failure dropped", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: "            Task { failed() }\n", with: "") }),
            ("the failure reported inside the update", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: "Task { failed() }", with: "failed()") }),
            ("the start tried silently", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: "try scanner.startScanning()", with: "try? scanner.startScanning()") }),
            ("the scanner handed no failure", PairingEntryStructureTests.mutate(app, screen) {
                $0.replacingOccurrences(of: "failed: scanFailed)", with: "failed: {})") }),
            ("the failure routed to Cancel", PairingEntryStructureTests.mutate(app, screen) {
                $0.replacingOccurrences(of: "scanFailed: { ceremony.scannerFailed() },", with: "scanFailed: { ceremony.cancel() },") }),
            ("the failure ends a ceremony elsewhere", PairingEntryStructureTests.mutate(app, Self.rootFile) {
                $0 + "\nfunc spare(c: PairingCeremony) { c.scannerFailed() }" }),
            // #175: the mid-scan stop, held as the start is.
            ("the mid-scan stop dropped", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: Self.stopReport, with: "            guard !handedOn else { return }\n") }),
            ("the mid-scan stop reported inside VisionKit's callback", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: Self.stopReport, with: "            guard !handedOn else { return }\n            failed()\n") }),
            ("a stop reported after the hand-on", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: Self.stopReport, with: "            Task { failed() }\n") }),
            ("the stop no longer VisionKit's callback", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: "func dataScanner(_: DataScannerViewController, becameUnavailableWithError",
                                        with: "func spare(_: DataScannerViewController, becameUnavailableWithError") }),
            ("the coordinator handed no failure", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: PairingEntryStructureTests.coordinatorBuilt, with: "Coordinator(scanned: scanned, failed: {})") }),
            ("the coordinator keeps another failure", PairingEntryStructureTests.mutate(app, scanner) {
                $0.replacingOccurrences(of: "            self.failed = failed\n", with: "            self.failed = {}\n") }),
            // #175: the fixture's ending, for its own value only.
            ("the fixture's ending on every fixture launch", PairingEntryStructureTests.mutate(app, "\(Self.appDir)/Fixtures/FixturePairing.swift") {
                $0.replacingOccurrences(of: Self.fixtureEnding, with: "ceremony.scannerFailed()") }),
        ]
        for (name, mutant) in mutants {
            #expect(mutant.map { $0.text } != app.map { $0.text }, "canary '\(name)' did not apply")
            #expect(!Self.scanFailureFailures(mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
        // Over-match control: a doc comment may name what the lock bans.
        #expect(Self.scanFailureFailures(PairingEntryStructureTests.mutate(app, scanner) {
            $0 + "\n/// never try? scanner.startScanning(), never scannerFailed() elsewhere"
        }).isEmpty)
    }

    /// The mid-scan report's two lines, as written (the canaries' anchor).
    /// (Its behaviour is run in `LivePairingTests`: this file touches
    /// nothing live, `PairingCeremonyTests.theTestsTouchNothingLive`.)
    static let stopReport: String = "            guard !handedOn else { return }\n            Task { failed() }\n"

    // MARK: The window's clock

    /// The sheet waits just past the deadline, then lets the ceremony end
    /// itself; with no deadline it waits for nothing.
    @Test func theSheetEndsTheCeremonyAtItsWindow() async {
        let clock = TestClock()
        let keys = PhoneKeyringTests.World()
        let ceremony = PairingCeremony(keyring: keys.keyring, biometrics: ScriptedBiometricGate(), writer: RecordingPairingWriter(),
                                       clock: { clock.now })
        let waits = Notes<Date>()
        let sheetClock = SheetClock(now: { clock.now }) { moment in
            waits.note(moment)
            clock.set(moment)
        }
        await PairingSheet.follow(ceremony, clock: sheetClock)
        #expect(waits.all.isEmpty, "no scan, no deadline, no wait")
        await ceremony.scanned(PairingCeremonyTests.code)
        let deadline = clock.now.addingTimeInterval(PairingCeremony.window)
        await PairingSheet.follow(ceremony, clock: sheetClock)
        #expect(waits.all == [PendingRequestSheet.justAfter(deadline)])
        #expect(ceremony.phase == .expired)
        #expect(keys.provisional() == nil)
    }
}
