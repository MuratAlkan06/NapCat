import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import NapCatWire
import SwiftUI

// F4 slice S-PAIR-C1 (#168): the pairing sheet, off the Settings window (its
// managed sheet, `SettingsWindowController.presentSheet`). Its states are the
// ratified UX spec's S1a–S1e; WHAT each says is `PairingSheetContent.make`,
// a pure mapping of the ceremony's state (table-tested headlessly), and the
// views below only arrange it.
//
// Binding rules kept here: the QR payload is drawn and nothing else — never
// an accessibility attribute, a tooltip, a log or the pasteboard; the code is
// spoken one character at a time with a pause between groups; focus lands on
// each new state's title; Esc always cancels and nothing answers Return (the
// pairing is committed by a click on Codes Match alone); severity is never
// color only; no motion beyond the Settings press (`SettingsPressButtonStyle`);
// the QR's fixed white tile is the one fixed fill, drawn inside its image.

/// What the sheet shows in one state of the ceremony.
struct PairingSheetContent: Equatable, Sendable {
    /// The spec's sheet states.
    enum Screen: Equatable, Sendable {
        /// S1a: the code, waiting for the iPhone.
        case code
        /// S1b: the code hidden while the sheet is not key or is occluded.
        case hidden
        /// S1c: the frozen response's code, to compare.
        case compare
        /// S1d.
        case paired
        /// S1e, one of four causes.
        case ended(PairingEnd)
    }

    enum Action: String, CaseIterable, Sendable {
        case cancel, theyDontMatch, codesMatch, done, startOver, close

        var title: String {
            switch self {
            case .cancel: return "Cancel"
            case .theyDontMatch: return "Codes Don't Match"
            case .codesMatch: return "Codes Match"
            case .done: return "Done"
            case .startOver: return "Start Over"
            case .close: return "Close"
            }
        }

        /// Esc's kind of button: it only ends the sheet (all three are the
        /// ceremony's Cancel), deciding nothing.
        var isEscape: Bool { [.cancel, .done, .close].contains(self) }
    }

    let screen: Screen
    let title: String
    /// The rotation note, while a paired phone's key keeps working.
    let subtitle: String?
    /// S1a only: what the QR encodes. Drawn, never spoken or copied.
    let qrPayload: String?
    /// S1c and S1d: the code to compare.
    let fingerprint: PairingFingerprint?
    /// The state-word-first line.
    let status: PanelLine
    /// Secondary lines under the status (the privacy note, the iPhone's
    /// half).
    let notes: [String]
    /// "Code expires in 4:58", while the window bounds the ceremony.
    let countdown: String?
    /// In order. None is the default: nothing answers Return.
    let actions: [Action]
    /// False while the confirmed key is being written.
    let actionsEnabled: Bool

    /// What Esc presses: the state's Cancel, Done or Close — or, in S1c,
    /// whose two buttons each decide something, a Cancel with no button of
    /// its own.
    var escape: Action { actions.first(where: \.isEscape) ?? .cancel }

    // MARK: Copy (the ratified spec's words)

    static let qrAccessibilityLabel = "Pairing code — scan it with the NapCat app on your iPhone"
    static let rotationNote = "Your current pairing keeps working until you confirm the new code."
    /// A rotation's end: nothing new was saved, so the old key still stands.
    static let rotationEndedNote = "Your current pairing keeps working."
    static let privacyNote = "Pair in private — anyone who can see this code could try to pair while it is up."
    static let waiting = "Waiting — scan this code with the NapCat app on your iPhone"
    static let waitingOffline = "Waiting — iCloud is unreachable; still trying"
    static let hiddenLine = "Hidden — bring this window to the front to show the code"
    /// S1c's body (the S1c variant ruling): the totality cue ("all three
    /// groups") and the Mac-first order.
    static let compareLine = "Your iPhone is showing a code too. If all three groups match, confirm here first, then on your iPhone."
    static let pairedLine = "Paired — finish on your iPhone: tap Codes Match there."
    static let pairedNote = "The iPhone completes its half after you."
    static let codeLabel = "Code"

    static func endedLine(_ end: PairingEnd) -> PanelLine {
        switch end {
        case .expired:
            return PanelLine(text: "Expired — the code timed out; nothing changed. Start over for a new code.", severity: .warning)
        case .refused:
            return PanelLine(text: "Refused — the reply didn't check out; nothing was saved. Start over with a new code.",
                             severity: .error)
        case .stoppedMismatch:
            return PanelLine(text: "Stopped — the codes don't match, so nothing was saved. Cancel on your iPhone too, "
                             + "and pair again later, in private.", severity: .warning)
        case .saveFailed:
            return PanelLine(text: "Failed — the key could not be saved; nothing changed. Start over to try again.", severity: .error)
        }
    }

    static func title(_ screen: Screen, rotating: Bool) -> String {
        switch screen {
        case .code, .hidden: return rotating ? "Pair a New iPhone" : "Pair iPhone"
        case .compare: return "Compare the Codes"
        case .paired: return "iPhone Paired"
        // A rotation that ends leaves the current pairing standing: never
        // "Not Paired" while the old key still works.
        case .ended: return rotating ? "Pair a New iPhone" : "Not Paired"
        }
    }

    /// `Code expires in 4:58`.
    static func countdown(secondsLeft: Int) -> String {
        let seconds = max(0, secondsLeft)
        return "Code expires in \(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }

    /// What VoiceOver reads for the countdown: coarse, so it never ticks
    /// every second — whole minutes, rounded down so it never promises
    /// time, then under a minute, under 30 seconds and under 10 seconds.
    static func spokenCountdown(secondsLeft: Int) -> String {
        let seconds: Int = max(0, secondsLeft)
        switch seconds {
        case 120...: return "Code expires in \(seconds / 60) minutes"
        case 60...: return "Code expires in 1 minute"
        case 30...: return "Code expires in under a minute"
        case 10...: return "Code expires in under 30 seconds"
        default: return "Code expires in under 10 seconds"
        }
    }

    // MARK: The mapping

    /// The sheet for `state` at `now` (unix seconds). With no ceremony up
    /// the sheet is closed; `.idle` maps to a plain Close, never shown.
    static func make(_ state: PairingCeremonyState, now: TimeInterval) -> PairingSheetContent {
        let countdown = countdown(secondsLeft: state.secondsLeft(now: now))
        let rotation = state.rotating ? rotationNote : nil
        switch state.phase {
        case .idle:
            return PairingSheetContent(screen: .ended(.expired), title: title(.ended(.expired), rotating: false), subtitle: nil,
                                       qrPayload: nil, fingerprint: nil, status: endedLine(.expired), notes: [], countdown: nil,
                                       actions: [.close], actionsEnabled: true)
        case .showing(let offline):
            let status = offline ? PanelLine(text: waitingOffline, severity: .warning) : PanelLine(text: waiting, severity: .nominal)
            guard let payload = state.qrPayload else {
                return PairingSheetContent(screen: .hidden, title: title(.hidden, rotating: state.rotating), subtitle: rotation,
                                           qrPayload: nil, fingerprint: nil, status: PanelLine(text: hiddenLine, severity: .info),
                                           notes: [], countdown: countdown, actions: [.cancel], actionsEnabled: true)
            }
            return PairingSheetContent(screen: .code, title: title(.code, rotating: state.rotating), subtitle: rotation,
                                       qrPayload: payload, fingerprint: nil, status: status, notes: [privacyNote],
                                       countdown: countdown, actions: [.cancel], actionsEnabled: true)
        case .comparing(let candidate), .committing(let candidate):
            let enabled = if case .comparing = state.phase { true } else { false }
            return PairingSheetContent(screen: .compare, title: title(.compare, rotating: state.rotating), subtitle: rotation,
                                       qrPayload: nil, fingerprint: candidate.fingerprint,
                                       status: PanelLine(text: compareLine, severity: .nominal), notes: [],
                                       countdown: countdown, actions: [.theyDontMatch, .codesMatch], actionsEnabled: enabled)
        case .paired(let fingerprint):
            return PairingSheetContent(screen: .paired, title: title(.paired, rotating: false), subtitle: nil, qrPayload: nil,
                                       fingerprint: fingerprint, status: PanelLine(text: pairedLine, severity: .nominal),
                                       notes: [pairedNote], countdown: nil, actions: [.done], actionsEnabled: true)
        case .ended(let end):
            return PairingSheetContent(screen: .ended(end), title: title(.ended(end), rotating: state.rotating),
                                       subtitle: state.rotating ? rotationEndedNote : nil,
                                       qrPayload: nil, fingerprint: nil, status: endedLine(end), notes: [], countdown: nil,
                                       actions: end == .stoppedMismatch ? [.close] : [.close, .startOver], actionsEnabled: true)
        }
    }

    /// What VoiceOver hears as the ceremony moves: the new state's line
    /// (with the code, spelled out, as it appears to compare), once per
    /// change of screen or line; and, while the window runs, its last minute
    /// and its last ten seconds — never every second. Nothing as the sheet
    /// closes.
    static func announcement(from old: PairingCeremonyState, to new: PairingCeremonyState,
                             secondsBefore: Int, secondsAfter: Int) -> String? {
        guard new.phase != .idle else { return nil }
        let before = make(old, now: 0)
        let after = make(new, now: 0)
        if old.phase == .idle || before.screen != after.screen || before.status != after.status {
            let line = PanelSeverityTint.spoken(after.status)
            guard after.screen == .compare, let code = after.fingerprint else { return line }
            return line + " " + codeLabel + ": " + code.spoken
        }
        guard new.phase.isLive else { return nil }
        for mark in [60, 10] where secondsBefore > mark && secondsAfter <= mark {
            return countdown(secondsLeft: mark)
        }
        return nil
    }
}

enum PairingSheetMetrics {
    /// The sheet's fixed content width.
    static let width: CGFloat = 380
    /// The QR's largest side; the drawn side is the largest whole number
    /// of points per module that fits.
    static let qrSide: CGFloat = 220
    /// The quiet zone around the code, in modules (the QR standard's four).
    static let quietModules = 4
    /// The extra width of each gap between the code's groups (the S1c
    /// variant ruling, Variant A): about one more character of the large
    /// title's monospaced face, so a gap reads two spaces wide.
    static let codeGroupGap: CGFloat = PanelMetrics.loose + PanelMetrics.tight
}

/// The sheet: the ceremony's current content, arranged.
struct PairingSheetView: View {
    @ObservedObject var pairing: PairingController
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        let content = pairing.sheetContent
        let secondsLeft: Int = pairing.state.secondsLeft(now: pairing.now.timeIntervalSince1970)
        VStack(alignment: .leading, spacing: PanelMetrics.loose) {
            VStack(alignment: .leading, spacing: PanelMetrics.tight) {
                Text(content.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let payload = content.qrPayload {
                QRCodeView(payload: payload)
                    .frame(maxWidth: .infinity)
            }
            if let fingerprint = content.fingerprint {
                PairingCodeText(fingerprint: fingerprint, font: .largeTitle, groupGap: PairingSheetMetrics.codeGroupGap)
                    .frame(maxWidth: .infinity)
            }
            // The order instruction reads before the buttons.
            PanelCaptionLine(line: content.status, font: .body)
            ForEach(content.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let countdown = content.countdown {
                Text(countdown)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PairingSheetContent.spokenCountdown(secondsLeft: secondsLeft))
            }
            HStack(spacing: PanelMetrics.regular) {
                Spacer(minLength: 0)
                ForEach(content.actions, id: \.self) { action in
                    actionButton(action, isEscape: action == content.escape)
                }
            }
            .background {
                // S1c: neither button is Esc's, yet Esc still cancels there —
                // a Cancel with no face of its own (and no layout space).
                if !content.actions.contains(content.escape) {
                    Button(content.escape.title) { perform(content.escape) }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .disabled(!content.actionsEnabled)
        }
        .padding(PanelMetrics.loose + PanelMetrics.regular)
        .frame(width: PairingSheetMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        // Esc's own route is the `.cancelAction` button above (it needs no
        // focus); this is a backup for a focused control that takes Esc.
        .onExitCommand { pairing.cancel() }
        .onAppear { titleFocused = true }
        .onChange(of: content.screen) { titleFocused = true }
    }

    /// Esc presses the state's Cancel, Done or Close. No button is the
    /// default: nothing answers Return, so the pairing is committed by a
    /// deliberate click on Codes Match and never by a key meant for another
    /// screen.
    @ViewBuilder
    private func actionButton(_ action: PairingSheetContent.Action, isEscape: Bool) -> some View {
        let button = Button(action.title) { perform(action) }
            .buttonStyle(SettingsPressButtonStyle(look: .bezel))
        if isEscape {
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    private func perform(_ action: PairingSheetContent.Action) {
        switch action {
        case .cancel, .done, .close: pairing.cancel()
        case .theyDontMatch: pairing.codesDiffer()
        case .codesMatch: pairing.codesMatch()
        case .startOver: pairing.begin()
        }
    }
}

/// The code, monospaced, on one line: it never wraps, and at a size where
/// it would not fit it scales down a step first. `groupGap` widens the gaps
/// between the groups as kerning on their spaces, so the text itself stays
/// the wire's `XXXX XXXX XXXX` — what a selection copies and what VoiceOver
/// spells out, one character at a time, pausing at the groups.
struct PairingCodeText: View {
    let fingerprint: PairingFingerprint
    let font: Font
    var groupGap: CGFloat = 0

    var body: some View {
        Text(Self.drawn(fingerprint, groupGap: groupGap))
            .font(font.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .textSelection(.enabled)
            .accessibilityLabel(PairingSheetContent.codeLabel)
            .accessibilityValue(Text(fingerprint.grouped).speechSpellsOutCharacters())
    }

    /// `fingerprint.grouped`, each space between the groups kerned
    /// `groupGap` wider (none when it is 0).
    static func drawn(_ fingerprint: PairingFingerprint, groupGap: CGFloat) -> AttributedString {
        var gap: AttributedString = AttributedString(" ")
        if groupGap > 0 { gap[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] = groupGap }
        var drawn: AttributedString = AttributedString()
        for (index, group) in fingerprint.groups.enumerated() {
            if index > 0 { drawn += gap }
            drawn += AttributedString(group)
        }
        return drawn
    }
}

/// The pairing QR: CoreImage's QR generator, black modules on a fixed white
/// tile with a four-module quiet zone, drawn at a whole number of points per
/// module and rendered at the screen's own pixel size with nearest-neighbour
/// sampling — nothing scales it afterwards, so every module lands on the
/// pixel grid. It is one image to accessibility, labelled in fixed words.
struct QRCodeView: View {
    let payload: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let modules = Self.image(payload),
           let drawn = Self.drawn(modules, pixelsPerModule: Self.pointsPerModule(modules: modules.width) * Self.wholeScale(displayScale)) {
            Image(drawn, scale: CGFloat(Self.wholeScale(displayScale)), label: Text(PairingSheetContent.qrAccessibilityLabel))
        }
    }

    /// The most whole points per module that fit `PairingSheetMetrics.qrSide`
    /// (at least one).
    static func pointsPerModule(modules: Int) -> Int {
        guard modules > 0 else { return 0 }
        return max(1, Int(PairingSheetMetrics.qrSide) / modules)
    }

    /// The drawn side in points for `modules` modules.
    static func side(modules: Int) -> CGFloat {
        CGFloat(modules * pointsPerModule(modules: modules))
    }

    /// The display's scale as a whole number of pixels per point (2 on a
    /// Retina display, at least 1).
    static func wholeScale(_ scale: CGFloat) -> Int {
        max(1, Int(scale.rounded()))
    }

    /// One pixel per module, the quiet zone included; nil if CoreImage made
    /// nothing.
    static func image(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let quiet = CGFloat(PairingSheetMetrics.quietModules)
        let tile = code.extent.insetBy(dx: -quiet, dy: -quiet)
        let drawn = code.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: tile))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(drawn, from: tile)
    }

    /// `modules` scaled up by a whole factor, nearest-neighbour: every module
    /// a square of `pixelsPerModule` pixels, no edge blended.
    static func drawn(_ modules: CGImage, pixelsPerModule: Int) -> CGImage? {
        guard pixelsPerModule > 0 else { return nil }
        let factor = CGFloat(pixelsPerModule)
        let scaled = CIImage(cgImage: modules).samplingNearest().transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent)
    }
}

/// VoiceOver announcements for the ceremony (`PairingSheetContent.announcement`).
enum PairingAnnouncer {
    @MainActor
    static func post(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - Never printed, dumped or reflected (S-PAIR-C1.5, the C1 security delta check's (b))

/// The QR payload is drawn and nothing else (PairingStructureTests locks 2
/// and 7): the sheet's content and the QR view print, debug-print, dump and
/// reflect as their type's name and nothing more — the conformance is the
/// type's own, so no spelling (`String(describing:)`, an interpolation, an
/// accessibility string built from one, `dump`, a `Mirror`) and no file gets
/// the payload out of them.
extension PairingSheetContent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PairingSheetContent(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension QRCodeView: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "QR code (redacted)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
