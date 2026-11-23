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
    /// Under the input when it is taller than its box.
    nonisolated static let longInput = PhoneLine(text: "Long — the input scrolls inside its box", severity: .nominal)
    /// Beside the Sent line: the answer went out, nothing more.
    nonisolated static let sentSymbol = "paperplane"

    /// Why Allow is not on offer, naming the biometric this phone has.
    nonisolated static func allowUnavailable(_ kind: BiometryKind?) -> PhoneLine {
        guard let kind else {
            return PhoneLine(text: "Unavailable — this phone can't confirm Allow with biometrics; Deny still works",
                             severity: .warning)
        }
        return PhoneLine(text: "Unavailable — Allow needs \(kind.name) turned on; Deny still works", severity: .warning)
    }

    /// What the answers say and show. Allow names the biometric it asks for.
    nonisolated static func allowTitle(_ kind: BiometryKind) -> String { "Allow with \(kind.name)" }
    nonisolated static func allowHint(_ kind: BiometryKind) -> String { "Asks for \(kind.name) first." }

    /// The tool's glyph: one per tool the Mac's gate can forward, and a
    /// neutral tool mark for a name it does not know. Each has the filled
    /// form the theme draws, so none reads thinner than another.
    nonisolated static let otherToolSymbol = "wrench.and.screwdriver"
    nonisolated static func toolSymbol(_ toolName: String) -> String {
        switch toolName {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "arrow.down.doc"
        case "Edit": return "pencil.circle"
        case "NotebookEdit": return "book"
        default: return otherToolSymbol
        }
    }

    /// The input's box takes at most this share of the screen's height;
    /// past it the input scrolls inside the box, so the state line and the
    /// answers stay in reach below it.
    nonisolated static let inputShare: CGFloat = 1.0 / 3.0

    /// The box's height: the input's own, up to the share. nil until the
    /// input has been laid out once.
    nonisolated static func inputBoxHeight(input: CGFloat?, screen: CGFloat?) -> CGFloat? {
        guard let input else { return nil }
        guard let screen, screen > 0 else { return input }
        return min(input, screen * inputShare)
    }

    /// Whether the input is taller than its box (and so scrolls in it).
    nonisolated static func inputScrolls(input: CGFloat?, screen: CGFloat?) -> Bool {
        guard let input, let box = inputBoxHeight(input: input, screen: screen) else { return false }
        return input > box
    }

    /// Whether the prompt card is drawn as finished: flat, in the secondary
    /// ink. True once no answer from here can go out, so a card that can
    /// no longer be answered never looks like one that can.
    nonisolated static func mutesCard(_ status: RequestStatus) -> Bool {
        switch status {
        case .pending, .confirming, .sending: return false
        case .sent, .answered, .expired, .withdrawn: return true
        }
    }

    /// The glyph the state line carries beside its words when it is a
    /// confirmation (Sent); nil for every other state, whose line is a
    /// caption.
    nonisolated static func confirmationSymbol(_ status: RequestStatus) -> String? {
        if case .sent = status { return sentSymbol }
        return nil
    }

    /// What VoiceOver announces as the state changes: the Sent line, once,
    /// as an answer goes out; nothing otherwise.
    nonisolated static func announcement(from old: RequestStatus, to new: RequestStatus, at now: Date) -> String? {
        guard case .sent = new, old != new else { return nil }
        return new.line(at: now).spoken
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
    /// The input's full height and the screen's, as last laid out.
    @State private var inputHeight: CGFloat?
    @State private var screenHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.rowGap) {
                promptCard
                if let note = status.note {
                    CaptionLine(line: note)
                }
                stateLine
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        .background(theme.ground.ignoresSafeArea())
        .tint(theme.accent)
        .onChange(of: status) { old, new in
            guard let text = Self.announcement(from: old, to: new, at: now) else { return }
            var spoken = AttributedString(text)
            spoken.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// The tool, the project and the input, shown verbatim: the phone never
    /// reformats what it asks the owner to allow. Once no answer can go out
    /// the card lies flat in the secondary ink. The tool's glyph sits on the
    /// tool name's baseline, over the layout: a tall glyph never moves the
    /// name, so every tool's name sits at the same height.
    private var promptCard: some View {
        let muted = Self.mutesCard(status)
        return VStack(alignment: .leading, spacing: theme.innerGap * 2) {
            VStack(alignment: .leading, spacing: theme.innerGap) {
                Text(verbatim: request.toolName)
                    .font(theme.metaFont)
                    .foregroundStyle(muted ? theme.inkSecondary : theme.ink)
                Text(verbatim: request.projectLabel)
                    .font(theme.detailFont)
                    .foregroundStyle(theme.inkSecondary)
            }
            .padding(.leading, glyphColumn + theme.innerGap * 2)
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                Image(systemName: Self.toolSymbol(request.toolName))
                    .symbolVariant(theme.symbolVariant)
                    .fontWeight(theme.symbolWeight)
                    .font(theme.metaFont)
                    .foregroundStyle(muted ? theme.inkSecondary : theme.accent)
                    .frame(width: glyphColumn)
            }
            Text(Self.inputHeader)
                .font(theme.sectionFont)
                .textCase(.uppercase)
                .foregroundStyle(theme.inkSecondary)
            inputBox(muted: muted)
        }
        .themedCard(castsShadow: !muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(request))
    }

    /// The input with its whitespace marked (`VisibleWhitespace`), chunk
    /// under chunk, in a box as tall as the input up to `inputShare` of the
    /// screen; a longer input scrolls inside the box, all of it, and says so
    /// under it.
    @ViewBuilder private func inputBox(muted: Bool) -> some View {
        ScrollView {
            InputDrawing(input: request.inputPreview, muted: muted)
                .equatable()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
        }
        .frame(height: Self.inputBoxHeight(input: inputHeight, screen: screenHeight))
        .scrollBounceBehavior(.basedOnSize)
        if Self.inputScrolls(input: inputHeight, screen: screenHeight) {
            CaptionLine(line: Self.longInput)
        }
    }

    /// The state in words. Sent is a confirmation: its glyph and its words
    /// in the ink; every other state is a caption.
    @ViewBuilder private var stateLine: some View {
        let line = status.line(at: now)
        if let symbol = Self.confirmationSymbol(status) {
            HStack(alignment: .firstTextBaseline, spacing: theme.innerGap) {
                Image(systemName: symbol)
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
                CaptionLine(line: Self.allowUnavailable(biometry.kind))
            }
            Button(action: deny) {
                Label(Self.denyTitle, systemImage: Self.denySymbol)
            }
            .buttonStyle(RequestButtonStyle(emphasis: .ink))
        }
    }
}

/// The input's drawing: its chunks stacked, each a text, whitespace marked
/// (`VisibleWhitespace`). Lazily, so only the chunks in sight are built (a
/// 32 KB input's marks are thousands of color runs); equal while its input
/// and its tone are, so the screen's other redraws (its clock, its
/// measuring) leave it as drawn. The box's height stays right: a short
/// input's chunks are all in sight, and a long one's in sight already fill
/// the box. Not private: `VisibleWhitespaceTests` lays it out.
struct InputDrawing: View, Equatable {
    let input: String
    let muted: Bool

    @Environment(\.theme) private var theme

    nonisolated static func == (lhs: InputDrawing, rhs: InputDrawing) -> Bool {
        lhs.input == rhs.input && lhs.muted == rhs.muted
    }

    var body: some View {
        let chunks = VisibleWhitespace.chunks(input)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(chunks.indices, id: \.self) { index in
                Text(VisibleWhitespace.attributed(chunks[index], mark: theme.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(theme.bodyFont.monospaced())
        .foregroundStyle(muted ? theme.inkSecondary : theme.ink)
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
