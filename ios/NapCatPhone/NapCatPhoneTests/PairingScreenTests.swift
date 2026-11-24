import Foundation
@testable import NapCatPhone
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

    /// Every phase with every camera state that can go with it.
    static var everyLine: [PhoneLine] {
        CameraState.allCases.map { PairingScreen.line(for: .scanning, camera: $0) }
            + everyPhase.dropFirst().map { PairingScreen.line(for: $0, camera: .ready) }
    }

    // MARK: The words

    @Test func everyLineIsInTheCaptionRegister() {
        for line in Self.everyLine {
            #expect(ListStateTests.captionRegisterFailures(line.text).isEmpty, "\(ListStateTests.captionRegisterFailures(line.text))")
        }
    }

    /// Every state reads differently in words alone.
    @Test func everyStateReadsDifferently() {
        #expect(Set(Self.everyLine.map(\.text)).count == Self.everyLine.count)
    }

    @Test func theLinesSayExactlyThis() {
        func text(_ phase: PairingCeremony.Phase, _ camera: CameraState = .ready) -> String {
            PairingScreen.line(for: phase, camera: camera).text
        }
        #expect(text(.waiting(Self.fingerprint, until: Self.until)) == "Waiting — confirm the code on your Mac")
        #expect(text(.paired(Self.fingerprint)) == "Paired — this iPhone signs its answers with this key")
        #expect(text(.scanning) == "Scanning — point the camera at the code on your Mac")
        #expect(text(.scanning, .notAsked) == "Needed — NapCat uses the camera only to read the code on your Mac")
        #expect(text(.scanning, .off) == "Off — camera access is off for NapCat; turn it on in Settings to scan")
        #expect(text(.scanning, .unsupported) == "Unavailable — this iPhone can't scan codes")
        #expect(text(.refused) == "Refused — that isn't a NapCat pairing code; nothing was saved")
        #expect(text(.failed(.alreadyAnswered)) == "Refused — this code was already answered; start again on your Mac")
        #expect(text(.cancelled) == "Cancelled — nothing changed on this iPhone")
        #expect(text(.expired) == "Expired — the code's five minutes ran out; start again on your Mac")
        #expect(PairingScreen.privateNote == "Pair in private: the code on your Mac is a secret while it's on screen.")
        #expect(PairingCeremony.reason == "Confirm it's you to pair this iPhone with your Mac.")
    }

    /// "Paired" is said in the paired phase alone, and no line claims what
    /// the Mac did: the phone knows only its own half.
    @Test func onlyThePairedPhaseSaysPaired() {
        for phase in Self.everyPhase {
            let line = PairingScreen.line(for: phase, camera: .ready).text
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
        #expect(PairingScreen.line(for: .cancelled, camera: .ready).severity == .info)
        #expect(PairingScreen.line(for: .expired, camera: .ready).severity == .info)
        #expect(PairingScreen.line(for: .scanning, camera: .off).severity == .warning)
        #expect(PairingScreen.line(for: .waiting(Self.fingerprint, until: Self.until), camera: .ready).severity == .nominal)
    }

    // MARK: The offers

    @Test func eachPhaseOffersWhatItCan() {
        #expect(PairingScreen.offer(for: .scanning, camera: .ready) == .viewfinder)
        #expect(PairingScreen.offer(for: .scanning, camera: .notAsked) == .askCamera)
        #expect(PairingScreen.offer(for: .scanning, camera: .off) == .settings)
        #expect(PairingScreen.offer(for: .scanning, camera: .unsupported) == PairingScreen.Offer.none)
        #expect(PairingScreen.offer(for: .waiting(Self.fingerprint, until: Self.until), camera: .ready) == .compare)
        for phase in [PairingCeremony.Phase.confirming, .saving, .paired(Self.fingerprint)] {
            #expect(PairingScreen.offer(for: phase, camera: .ready) == PairingScreen.Offer.none, "\(phase)")
        }
        for phase in [PairingCeremony.Phase.refused, .cancelled, .expired] + PairingCeremony.Failure.allCases.map({ .failed($0) }) {
            #expect(PairingScreen.offer(for: phase, camera: .ready) == .again, "\(phase)")
        }
        // The camera matters while scanning only.
        #expect(PairingScreen.offer(for: .waiting(Self.fingerprint, until: Self.until), camera: .off) == .compare)
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
        #expect(PairingScreen.spokenCode(Self.fingerprint) == "This iPhone's code: \(Self.fingerprint.spoken)")
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
    /// viewfinder; Codes Match and Cancel are offered together, only while
    /// comparing. The sheet routes each closure to its ceremony call, and
    /// Close, a swipe down or the window's end cancel. The root opens it
    /// for the fixture launch only, in the palette.
    static func wiringFailures(screen: String, root: String) -> [String] {
        let flat = SettingsReachabilityTests.flat(screen)
        var failures: [String] = []
        guard let screenBody = CloudKitStructureTests.body(after: "struct PairingScreen: View {", in: CloudKitStructureTests.codeOnly(screen))
        else { return ["the screen moved (the lock would be vacuous)"] }
        for token in ["keyring", "writer", "BiometricGate", "confirm(reason", "ceremony", "commitProvisional", "PhoneKeyring"]
        where screenBody.contains(token) {
            failures.append("'\(token)' in the screen — it only hands its answers to its closures")
        }
        for shape in ["if Self.offer(for: phase, camera: camera) == .viewfinder { viewfinder }",
                      "if liveCamera { QRScannerView(scanned: scanned) } else {",
                      "case .compare: Button(action: confirm) { Label(Self.matchTitle, systemImage: Self.matchSymbol) } "
                        + ".buttonStyle(RequestButtonStyle(emphasis: .accent)) Button(action: cancel) {",
                      "scanned: { payload in Task { await ceremony.scanned(payload) } }",
                      "confirm: { ceremony.confirmCodesMatch() }", "cancel: { ceremony.cancel() }", "again: { ceremony.restart() }",
                      "Button(PairingScreen.closeTitle) { ceremony.cancel() dismiss() }", ".onDisappear { ceremony.cancel() }",
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
            ("the viewfinder in every phase", screen.replacingOccurrences(of: "if Self.offer(for: phase, camera: camera) == .viewfinder {",
                                                                          with: "if true {"), root),
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
        await ceremony.scanned(PairingCeremonyTests.payload)
        let deadline = clock.now.addingTimeInterval(PairingCeremony.window)
        await PairingSheet.follow(ceremony, clock: sheetClock)
        #expect(waits.all == [PendingRequestSheet.justAfter(deadline)])
        #expect(ceremony.phase == .expired)
        #expect(keys.provisional() == nil)
    }
}
