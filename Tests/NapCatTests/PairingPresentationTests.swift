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

/// F4 slice S-PAIR-C1 (#168): what the pairing sheet and Settings › Claude
/// show, per state, as tables over the pure mappings (the ratified spec's
/// words, exactly); the QR as drawn (decoded back to its payload, its quiet
/// zone and its pixel grid); and the Settings window's managed sheet seam
/// over recording hooks — no window on screen, nothing activated.
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
        #expect(sheet.status.text == "Compare — your iPhone shows a code too. If they match, confirm here first, then on your iPhone.")
        #expect(sheet.actions == [.theyDontMatch, .codesMatch], "Codes Match last: the default")
        #expect(sheet.actions.map(\.title) == ["They Don't Match", "Codes Match"])
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
            var state = PairingCeremonyState()
            _ = state.apply(.begin(nonce: PhoneHalf.nonce, rotating: false, now: Self.start))
            switch end {
            case .expired: _ = state.apply(.tick(now: Self.start + 300))
            case .refused:
                _ = state.apply(.tick(now: Self.start + 2.5))
                _ = state.apply(.fetched(.found(.malformed(.wrongZone)), now: Self.start + 2.5))
            case .stoppedMismatch, .saveFailed:
                _ = state.apply(.tick(now: Self.start + 2.5))
                _ = state.apply(.fetched(.found(.response(try! PhoneHalf.response())), now: Self.start + 2.5))
                if end == .stoppedMismatch {
                    _ = state.apply(.codesDiffer)
                } else {
                    _ = state.apply(.codesMatch(now: Self.start + 3))
                    _ = state.apply(.committed(false))
                }
            }
            let sheet = Self.content(state)
            #expect(sheet.screen == .ended(end) && sheet.status == line && sheet.actions == actions, "\(end)")
            #expect(sheet.title == "Not Paired" && sheet.qrPayload == nil && sheet.fingerprint == nil && sheet.countdown == nil)
        }
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

    @Test func theCountdownIsMinutesAndPaddedSeconds() {
        #expect(PairingSheetContent.countdown(secondsLeft: 300) == "Code expires in 5:00")
        #expect(PairingSheetContent.countdown(secondsLeft: 65) == "Code expires in 1:05")
        #expect(PairingSheetContent.countdown(secondsLeft: 9) == "Code expires in 0:09")
        #expect(PairingSheetContent.countdown(secondsLeft: -3) == "Code expires in 0:00")
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
        let hint = "Pairing stores the iPhone's public key on this Mac. Nothing is armed by pairing, and nothing leaves this Mac."
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
        #expect([MenuStateModel.unpairAlertTitle, MenuStateModel.unpairAlertText, MenuStateModel.unpairAlertConfirm,
                  MenuStateModel.unpairAlertCancel] == ["Unpair iPhone?", "NapCat deletes the stored key and stops remote "
                    + "approvals through the kill switch. Pairing again takes about two minutes.", "Unpair", "Cancel"])
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
                       "guard alert.runModal() == .alertFirstButtonReturn else { return } pairing?.unpair() model.refresh()",
                       "pairing?.refreshPaired() model.refresh() }"] {
            #expect(owner.contains(wiring), "missing: \(wiring)")
        }
    }
}
