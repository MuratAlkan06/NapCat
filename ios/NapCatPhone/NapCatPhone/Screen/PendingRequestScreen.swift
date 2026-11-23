import NapCatWire
import SwiftUI

/// One forwarded permission prompt, answered on the phone (F4, slice S3):
/// the tool and project, the input exactly as the Mac's gate read it, the
/// request's state in words and, only while it is answerable, Allow (after a
/// biometric match, CL-3) and Deny. An expired or withdrawn request says why
/// and offers no answer. Everything visual comes from the environment's
/// `Theme`; nothing on it moves.
struct PendingRequestScreen: View {
    nonisolated static let title = "Permission prompt"
    nonisolated static let inputHeader = "Input"
    nonisolated static let denyTitle = "Deny"
    nonisolated static let denySymbol = "xmark"
    nonisolated static let closeTitle = "Close"
    nonisolated static let footnote = "The dialog on your Mac stays open, and you can answer it there instead."
    nonisolated static let allowUnavailable = PhoneLine(
        text: "Unavailable — Allow needs Face ID or Touch ID turned on; Deny still works", severity: .warning)

    /// What the answers say and show. Allow names the biometric it asks for.
    nonisolated static func allowTitle(_ kind: BiometryKind) -> String { "Allow with \(kind.name)" }
    nonisolated static func allowHint(_ kind: BiometryKind) -> String { "Asks for \(kind.name) first." }

    /// The tool's glyph: a terminal for Bash, a plain mark for anything else.
    nonisolated static func toolSymbol(_ toolName: String) -> String {
        toolName == "Bash" ? "terminal" : "questionmark.square"
    }

    /// Which answers the screen offers.
    struct Offer: Equatable, Sendable {
        /// Allow, with the biometric it asks for; nil when not on offer.
        let allow: BiometryKind?
        let deny: Bool

        static let none = Offer(allow: nil, deny: false)
    }

    /// Nothing unless the request is answerable; then Deny, and Allow only
    /// where a biometric match is possible.
    nonisolated static func offer(for status: RequestStatus, biometry: BiometricAvailability) -> Offer {
        guard status.isAnswerable else { return .none }
        guard case .available(let kind) = biometry else { return Offer(allow: nil, deny: true) }
        return Offer(allow: kind, deny: true)
    }

    /// The footnote is true only while an answer from here can still go
    /// out: a withdrawn prompt may already be closed on the Mac, and an
    /// expired one says so in its own line.
    nonisolated static func showsFootnote(_ status: RequestStatus) -> Bool {
        switch status {
        case .pending, .confirming, .sending: return true
        case .sent, .answered, .expired, .withdrawn: return false
        }
    }

    /// What VoiceOver reads for the prompt card.
    nonisolated static func spoken(_ request: PendingRequest) -> String {
        "\(request.toolName) permission prompt, project \(request.projectLabel). \(inputHeader): \(request.inputPreview)"
    }

    let request: PendingRequest
    let status: RequestStatus
    let now: Date
    let biometry: BiometricAvailability
    let allow: () -> Void
    let deny: () -> Void

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                promptCard
                if let note = status.note {
                    CaptionLine(line: note)
                }
                CaptionLine(line: status.line(at: now))
                answers
                if Self.showsFootnote(status) {
                    Text(Self.footnote)
                        .font(theme.detailFont)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, theme.margin)
            .padding(.vertical, theme.rowGap)
        }
        .background(theme.ground.ignoresSafeArea())
        .tint(theme.accent)
    }

    /// The tool, the project and the input, shown verbatim: the phone never
    /// reformats what it asks the owner to allow.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: theme.innerGap * 2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.innerGap * 2) {
                Image(systemName: Self.toolSymbol(request.toolName))
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .font(theme.metaFont)
                    .foregroundStyle(theme.accent)
                    .frame(width: glyphColumn)
                VStack(alignment: .leading, spacing: theme.innerGap) {
                    Text(verbatim: request.toolName)
                        .font(theme.metaFont)
                        .foregroundStyle(theme.ink)
                    Text(verbatim: request.projectLabel)
                        .font(theme.detailFont)
                        .foregroundStyle(theme.inkSecondary)
                }
            }
            Text(Self.inputHeader)
                .font(theme.sectionFont)
                .textCase(.uppercase)
                .foregroundStyle(theme.inkSecondary)
            Text(verbatim: request.inputPreview)
                .font(theme.bodyFont.monospaced())
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(request))
    }

    @ViewBuilder private var answers: some View {
        let offer = Self.offer(for: status, biometry: biometry)
        if offer.deny {
            if let kind = offer.allow {
                Button(action: allow) {
                    Label(Self.allowTitle(kind), systemImage: kind.symbol)
                }
                .buttonStyle(RequestButtonStyle(emphasis: .accent))
                .accessibilityHint(Self.allowHint(kind))
            } else {
                CaptionLine(line: Self.allowUnavailable)
            }
            Button(action: deny) {
                Label(Self.denyTitle, systemImage: Self.denySymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .ink))
        }
    }
}

#Preview("Pending") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-60)),
                         status: .pending(until: now.addingTimeInterval(540), note: nil), now: now,
                         biometry: .available(.faceID), allow: {}, deny: {})
}

#Preview("Expired") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-660)),
                         status: .expired, now: now, biometry: .available(.faceID), allow: {}, deny: {})
}

#Preview("Withdrawn") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-120)),
                         status: .withdrawn, now: now, biometry: .available(.faceID), allow: {}, deny: {})
}
