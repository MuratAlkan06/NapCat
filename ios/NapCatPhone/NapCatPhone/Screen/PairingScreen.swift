import SwiftUI
import UIKit

/// Pairing with the Mac, on the phone (F4 slice S-PAIR-B): scan the code
/// the Mac shows, confirm with a biometric match, then compare this
/// iPhone's code with the Mac's and confirm here too. The words never claim
/// more than the phone knows: "Paired" only after the owner's confirm
/// here, and nothing about what the Mac did. Everything visual comes from
/// the environment's `Theme`; nothing on it moves.
struct PairingScreen: View {
    nonisolated static let title = "Pair with Mac"
    nonisolated static let closeTitle = "Close"
    nonisolated static let codeHeader = "This iPhone's code"
    /// The comparison is what catches a code that isn't the owner's Mac's,
    /// so the hint says what to do either way.
    nonisolated static let compareHint = "Your Mac shows a code too. If the two match, confirm on your Mac, then here. "
        + "If they don't, cancel here and on your Mac, and nothing is paired."
    nonisolated static let privateNote = "Pair in private: the code on your Mac is a secret while it's on screen."
    nonisolated static let viewfinderLabel = "Camera viewfinder"

    nonisolated static let matchTitle = "Codes Match"
    nonisolated static let matchSymbol = "checkmark"
    nonisolated static let cancelTitle = "Cancel"
    nonisolated static let cancelSymbol = "xmark"
    nonisolated static let cameraTitle = "Allow Camera"
    nonisolated static let cameraSymbol = "camera"
    nonisolated static let settingsTitle = "Open Settings"
    nonisolated static let againTitle = "Scan Again"
    nonisolated static let scanSymbol = "qrcode.viewfinder"
    /// Beside the Paired line: a key kept, nothing more.
    nonisolated static let pairedSymbol = "checkmark.seal"

    /// The system's deep link to this app's page in Settings, where the
    /// camera is turned back on.
    nonisolated static let settingsURL = URL(string: UIApplication.openSettingsURLString)

    /// Why no scan is offered on a phone whose biometric match can't
    /// happen: the pairing needs one, so the line names the biometric and
    /// where it is set up, not a retry.
    nonisolated static func matchUnavailable(_ kind: BiometryKind?) -> PhoneLine {
        guard let kind else {
            return PhoneLine(text: "Unavailable — this iPhone can't confirm a pairing with biometrics", severity: .warning)
        }
        return PhoneLine(text: "Unavailable — pairing needs \(kind.name) turned on; set it up in Settings › \(kind.name) & Passcode",
                         severity: .warning)
    }

    /// The state line, in the caption register: one state word, an em dash,
    /// the cause, no closing period. Before the scan, a match that can't
    /// happen outranks the camera: nothing could be confirmed.
    nonisolated static func line(for phase: PairingCeremony.Phase, camera: CameraState,
                                 biometry: BiometricAvailability) -> PhoneLine {
        switch phase {
        case .scanning:
            if case .unavailable(let kind) = biometry { return matchUnavailable(kind) }
            switch camera {
            case .ready:
                return PhoneLine(text: "Scanning — point the camera at the code on your Mac", severity: .nominal)
            case .notAsked:
                return PhoneLine(text: "Needed — NapCat uses the camera only to read the code on your Mac", severity: .nominal)
            case .off:
                return PhoneLine(text: "Off — camera access is off for NapCat; turn it on in Settings to scan", severity: .warning)
            case .unsupported:
                return PhoneLine(text: "Unavailable — this iPhone can't scan codes", severity: .warning)
            }
        case .refused:
            return PhoneLine(text: "Refused — that isn't a NapCat pairing code; nothing was saved", severity: .warning)
        case .confirming:
            return PhoneLine(text: "Confirming — waiting for \(biometry.kind?.name ?? "the biometric match")", severity: .nominal)
        case .saving:
            return PhoneLine(text: "Saving — sending this iPhone's key to iCloud for your Mac", severity: .nominal)
        case .waiting:
            return PhoneLine(text: "Waiting — confirm the code on your Mac", severity: .nominal)
        case .paired:
            return PhoneLine(text: "Paired — this iPhone signs its answers with this key", severity: .nominal)
        case .failed(let failure):
            return failureLine(failure)
        case .cancelled:
            return PhoneLine(text: "Cancelled — nothing changed on this iPhone", severity: .info)
        case .expired:
            return PhoneLine(text: "Expired — the code's five minutes ran out; start again on your Mac", severity: .info)
        }
    }

    nonisolated static func failureLine(_ failure: PairingCeremony.Failure) -> PhoneLine {
        let text = switch failure {
        case .noKey: "Unavailable — this iPhone couldn't make a key; nothing was saved"
        case .notConfirmed: "Unverified — pairing wasn't confirmed, so nothing was saved"
        case .notSigned: "Unsigned — this iPhone couldn't sign with its new key, so nothing was saved"
        case .alreadyAnswered: "Refused — this code was already answered; start again on your Mac"
        case .unsent: "Unsent — couldn't save to iCloud; start again on your Mac"
        case .unconfirmed: "Unconfirmed — iCloud didn't confirm the save; start again on your Mac"
        case .notKept: "Unsaved — this iPhone couldn't keep its new key; start again on your Mac"
        }
        return PhoneLine(text: text, severity: .warning)
    }

    /// What the screen offers in each phase.
    enum Offer: Equatable, Sendable {
        /// The viewfinder (the camera is allowed).
        case viewfinder
        /// The button that asks for the camera.
        case askCamera
        /// The way to this app's page in Settings.
        case settings
        /// Codes Match and Cancel.
        case compare
        /// Scan Again: a new ceremony.
        case again
        case none
    }

    /// Before the scan, nothing while the match can't happen (the line says
    /// where to set it up; Close leaves), then by the camera.
    nonisolated static func offer(for phase: PairingCeremony.Phase, camera: CameraState,
                                  biometry: BiometricAvailability) -> Offer {
        switch phase {
        case .scanning:
            guard case .available = biometry else { return .none }
            switch camera {
            case .ready: return .viewfinder
            case .notAsked: return .askCamera
            case .off: return .settings
            case .unsupported: return .none
            }
        case .waiting: return .compare
        case .refused, .failed, .cancelled, .expired: return .again
        case .confirming, .saving, .paired: return .none
        }
    }

    /// The code, while it is to be compared and once kept.
    nonisolated static func fingerprint(in phase: PairingCeremony.Phase) -> KeyFingerprint? {
        switch phase {
        case .waiting(let fingerprint, _), .paired(let fingerprint): return fingerprint
        default: return nil
        }
    }

    /// The pair-in-private note, while a code is or may be on the Mac's
    /// screen.
    nonisolated static func showsPrivateNote(_ phase: PairingCeremony.Phase) -> Bool {
        switch phase {
        case .scanning, .confirming, .saving, .waiting: return true
        case .refused, .paired, .failed, .cancelled, .expired: return false
        }
    }

    /// What VoiceOver reads for the code: character by character.
    nonisolated static func spokenCode(_ fingerprint: KeyFingerprint) -> String {
        "\(codeHeader): \(fingerprint.spoken)"
    }

    /// What VoiceOver announces as the phase changes: the new line, once,
    /// as the code appears to compare (waiting) and as the ceremony ends
    /// (paired, or why not); nothing while it is under way, where the
    /// system's own biometric prompt speaks.
    nonisolated static func announcement(from old: PairingCeremony.Phase, to new: PairingCeremony.Phase, camera: CameraState,
                                         biometry: BiometricAvailability) -> String? {
        guard old != new else { return nil }
        switch new {
        case .waiting, .paired, .refused, .failed, .cancelled, .expired:
            return line(for: new, camera: camera, biometry: biometry).spoken
        case .scanning, .confirming, .saving:
            return nil
        }
    }

    let phase: PairingCeremony.Phase
    let camera: CameraState
    /// Whether the ceremony's biometric match can happen on this phone.
    let biometry: BiometricAvailability
    /// Whether the viewfinder is the real camera (fixtures draw its frame).
    let liveCamera: Bool
    let scanned: @MainActor (String) -> Void
    let askCamera: () -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    let again: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                if let fingerprint = Self.fingerprint(in: phase) {
                    codeCard(fingerprint, muted: phase == .paired(fingerprint))
                }
                if Self.offer(for: phase, camera: camera, biometry: biometry) == .viewfinder {
                    viewfinder
                }
                stateLine
                if case .waiting = phase {
                    Text(Self.compareHint)
                        .font(theme.detailFont)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                if Self.showsPrivateNote(phase) {
                    Text(Self.privateNote)
                        .font(theme.detailFont)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The column spans the screen in every phase: with only lines in
            // it (confirming, saving, no match possible) the scroll view
            // would otherwise hug them, narrower than the sheet.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.margin)
            .padding(.vertical, theme.rowGap)
        }
        .background(theme.ground.ignoresSafeArea())
        .tint(theme.accent)
        .onChange(of: phase) { old, new in
            guard let text = Self.announcement(from: old, to: new, camera: camera, biometry: biometry) else { return }
            var spoken = AttributedString(text)
            spoken.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// This iPhone's code, large and monospaced, in a card; once kept, the
    /// card lies flat. VoiceOver reads it character by character.
    private func codeCard(_ fingerprint: KeyFingerprint, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.innerGap) {
            Text(Self.codeHeader)
                .font(theme.sectionFont)
                .textCase(.uppercase)
                .foregroundStyle(theme.inkSecondary)
            Text(verbatim: fingerprint.grouped)
                .font(theme.titleFont)
                .foregroundStyle(muted ? theme.inkSecondary : theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard(castsShadow: !muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenCode(fingerprint))
    }

    /// A square frame as wide as the screen's column: the live camera, or
    /// (fixtures) its glyph. The square is laid out first and the camera
    /// fills it, so the frame never shrinks to its content. VoiceOver reads
    /// it as one labeled element; whether VisionKit's own guidance should
    /// reach VoiceOver through it is owed to a device check (the simulator
    /// has no scanner to inspect).
    private var viewfinder: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if liveCamera {
                    QRScannerView(scanned: scanned)
                } else {
                    Image(systemName: Self.scanSymbol)
                        .symbolVariant(theme.symbolVariant)
                        .font(theme.titleFont)
                        .foregroundStyle(theme.inkSecondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .background { ThemedSurface(fill: theme.surface, cornerRadius: theme.cornerRadius) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.viewfinderLabel)
    }

    /// The state in words. Paired is a confirmation: its glyph and its words
    /// in the ink; every other state is a caption.
    @ViewBuilder private var stateLine: some View {
        let line = Self.line(for: phase, camera: camera, biometry: biometry)
        if case .paired = phase {
            HStack(alignment: .firstTextBaseline, spacing: theme.innerGap) {
                Image(systemName: Self.pairedSymbol)
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .foregroundStyle(theme.accent)
                Text(line.text)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(theme.detailFont)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.spoken)
        } else {
            CaptionLine(line: line)
        }
    }

    @ViewBuilder private var actions: some View {
        switch Self.offer(for: phase, camera: camera, biometry: biometry) {
        case .askCamera:
            Button(action: askCamera) {
                Label(Self.cameraTitle, systemImage: Self.cameraSymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .accent))
        case .settings:
            Button {
                if let url = Self.settingsURL { openURL(url) }
            } label: {
                LinkOutLabel(title: Self.settingsTitle)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .accent))
        case .compare:
            Button(action: confirm) {
                Label(Self.matchTitle, systemImage: Self.matchSymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .accent))
            Button(action: cancel) {
                Label(Self.cancelTitle, systemImage: Self.cancelSymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .ink))
        case .again:
            Button(action: again) {
                Label(Self.againTitle, systemImage: Self.scanSymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .ink))
        case .viewfinder, .none:
            EmptyView()
        }
    }
}

/// The pairing screen over its ceremony, as a sheet with Close. Close or
/// the window's end cancels a ceremony under way (its provisional key goes;
/// the committed one stays). A swipe down does not close it while the
/// ceremony is under way (a stray swipe during the code comparison would
/// cancel it), only once it has ended; a sheet closed any other way still
/// cancels. It re-reads the camera and the biometrics as it appears and
/// as the app returns to the foreground (the owner may have turned either
/// on in Settings). Nothing animates.
struct PairingSheet: View {
    let ceremony: PairingCeremony
    let camera: any CameraAccess
    let clock: SheetClock

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraState: CameraState

    init(ceremony: PairingCeremony, camera: any CameraAccess, clock: SheetClock = .system) {
        self.ceremony = ceremony
        self.camera = camera
        self.clock = clock
        _cameraState = State(initialValue: camera.state())
    }

    /// Waits past the ceremony's deadline, then lets it end itself; returns
    /// at once when there is no deadline, or when cancelled (the sheet
    /// closed, or a new deadline).
    static func follow(_ ceremony: PairingCeremony, clock: SheetClock) async {
        guard let deadline = ceremony.deadline else { return }
        do { try await clock.sleep(PendingRequestSheet.justAfter(deadline)) } catch { return }
        ceremony.tick()
    }

    var body: some View {
        NavigationStack {
            PairingScreen(phase: ceremony.phase, camera: cameraState, biometry: ceremony.biometry, liveCamera: camera.isLive,
                          scanned: { payload in Task { await ceremony.scanned(payload) } },
                          askCamera: { Task { cameraState = await camera.request() } },
                          confirm: { ceremony.confirmCodesMatch() },
                          cancel: { ceremony.cancel() },
                          again: { ceremony.restart() })
                .navigationTitle(PairingScreen.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(PairingScreen.closeTitle) {
                            ceremony.cancel()
                            dismiss()
                        }
                    }
                }
        }
        .tint(theme.accent)
        .interactiveDismissDisabled(!ceremony.phase.isFinal)
        .onAppear { ceremony.refreshBiometry() }
        .onDisappear { ceremony.cancel() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            cameraState = camera.state()
            ceremony.refreshBiometry()
            ceremony.tick()
        }
        .task(id: ceremony.deadline) { await Self.follow(ceremony, clock: clock) }
    }
}

#Preview("Scanning") {
    PairingScreen(phase: .scanning, camera: .ready, biometry: .available(.faceID), liveCamera: false, scanned: { _ in },
                  askCamera: {}, confirm: {}, cancel: {}, again: {})
}
