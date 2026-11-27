import NapCatWire
import SwiftUI

/// One forwarded permission prompt, answered on the phone (F4, slice S3):
/// the tool and project, the input exactly as the Mac's gate read it, the
/// request's state in words and, only while it is answerable, Allow and Deny,
/// each after a biometric match (CL-3, and the owner's uniform-signing
/// ruling: every answer is signed); after iCloud left an answer unconfirmed,
/// that answer alone, sent again (#154). An expired or withdrawn request
/// says why and offers no answer; so does a read-only inbox, whose answers
/// would go nowhere (#194: the live inbox, until the answer path is armed),
/// and its line already says where to answer, so it drops the footnote.
/// Everything visual comes from the environment's `Theme`; nothing on it
/// moves.
struct PendingRequestScreen: View {
    nonisolated static let title = "Permission prompt"
    nonisolated static let inputHeader = "Input"
    nonisolated static let closeTitle = "Close"
    nonisolated static let footnote = "The dialog on your Mac stays open, and you can answer it there instead."
    /// The footnote once iCloud left an answer unconfirmed (#154): that
    /// answer may have reached the Mac, whose dialog then closed.
    nonisolated static let unconfirmedFootnote = "If the dialog on your Mac is still open, you can answer it there instead."
    /// Under the input when it is taller than its box.
    nonisolated static let longInput = PhoneLine(text: "Long — the input scrolls inside its box", severity: .nominal)
    /// Beside the Sent line: the answer went out, nothing more.
    nonisolated static let sentSymbol = "paperplane"

    /// Why no answer is on offer while answers from here go nowhere (#194):
    /// the prompt is shown as a preview, to be answered on the Mac.
    nonisolated static let readOnlyLine = PhoneLine(text: "Preview — answering from iPhone isn't on yet; answer on your Mac",
                                                    severity: .info)

    /// Why no answer is on offer, naming the biometric this phone has.
    nonisolated static func answersUnavailable(_ kind: BiometryKind?) -> PhoneLine {
        guard let kind else {
            return PhoneLine(text: "Unavailable — this phone can't confirm answers with biometrics; answer on your Mac",
                             severity: .warning)
        }
        return PhoneLine(text: "Unavailable — answering needs \(kind.name) turned on; answer on your Mac", severity: .warning)
    }

    /// Why no answer is on offer on an unpaired phone: every answer is
    /// signed by the paired key, and there is none. Names the biometric
    /// when it is what changed.
    nonisolated static func unpaired(_ reason: PhoneKeyring.UnpairedReason, _ kind: BiometryKind?) -> PhoneLine {
        switch reason {
        case .neverPaired:
            return PhoneLine(text: "Unpaired — pair this iPhone with your Mac to answer here; answer on your Mac", severity: .warning)
        case .enrollmentChanged:
            let what = kind.map { "\($0.name) changed" } ?? "your biometrics changed"
            return PhoneLine(text: "Unpaired — \(what), so this iPhone's key stopped working; pair again with your Mac",
                             severity: .warning)
        case .unreadable:
            return PhoneLine(text: "Unpaired — this iPhone couldn't read its key; answer on your Mac", severity: .warning)
        }
    }

    /// Over the answers while the pairing still stands but the enrolled
    /// biometrics changed since it was made: the answers stay (the key
    /// decides), and the owner learns why one may fail.
    nonisolated static func enrollmentChanged(_ kind: BiometryKind) -> PhoneLine {
        PhoneLine(text: "Changed — \(kind.name) changed since pairing; if answering fails, pair again with your Mac",
                  severity: .warning)
    }

    /// What the answers say and show. Both name the biometric they ask for,
    /// and carry its glyph: neither answer goes out without it.
    nonisolated static func allowTitle(_ kind: BiometryKind) -> String { "Allow with \(kind.name)" }
    nonisolated static func denyTitle(_ kind: BiometryKind) -> String { "Deny with \(kind.name)" }
    nonisolated static func answerHint(_ kind: BiometryKind) -> String { "Asks for \(kind.name) first." }
    /// The one answer on offer after iCloud left it unconfirmed (#154): the
    /// same answer, sent again, asking for the biometric again.
    nonisolated static func againTitle(_ verdict: ApprovalWire.Verdict, _ kind: BiometryKind) -> String {
        "Send \(RequestStatus.name(verdict)) again with \(kind.name)"
    }

    /// What `verdict`'s answer says in `offer`: sent again when it is the
    /// one answer offered again, otherwise its own title.
    nonisolated static func title(_ verdict: ApprovalWire.Verdict, _ kind: BiometryKind, in offer: Offer) -> String {
        if offer.again == verdict { return againTitle(verdict, kind) }
        switch verdict {
        case .allow: return allowTitle(kind)
        case .deny: return denyTitle(kind)
        }
    }

    /// The tool's glyph: one per tool the Mac's gate has a row for (only
    /// Bash can be forwarded since #231), and a neutral tool mark for a name
    /// it does not know. Each has the filled
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
    /// as an answer goes out; the unconfirmed note, once, as it first
    /// appears, so the owner learns only one answer is left to send (#154;
    /// back from a resend under way it is not announced again); nothing
    /// otherwise.
    nonisolated static func announcement(from old: RequestStatus, to new: RequestStatus, at now: Date) -> String? {
        guard old != new else { return nil }
        if case .sent = new { return new.line(at: now).spoken }
        guard case .pending(_, .unconfirmed?) = new, !old.afterUnconfirmed else { return nil }
        return new.note?.spoken
    }

    /// Which answers the screen offers: both, or after iCloud left an
    /// answer unconfirmed that one alone, sent again (#154), or neither.
    /// Each asks for the same match.
    struct Offer: Equatable, Sendable {
        /// The biometric the answers on offer ask for; nil when none is on
        /// offer.
        let answers: BiometryKind?
        /// The one answer on offer, to send again, after iCloud left it
        /// unconfirmed; nil when both are on offer, or neither.
        let again: ApprovalWire.Verdict?
        /// Said where the answers go: why there are none.
        let caption: PhoneLine?

        init(answers: BiometryKind?, again: ApprovalWire.Verdict? = nil, caption: PhoneLine?) {
            self.answers = answers
            self.again = again
            self.caption = caption
        }

        static let none = Offer(answers: nil, caption: nil)

        /// Whether `verdict`'s answer is on offer.
        func offers(_ verdict: ApprovalWire.Verdict) -> Bool {
            answers != nil && (again == nil || again == verdict)
        }
    }

    /// Nothing unless the request is answerable; then nothing but the
    /// reason while the inbox is read only (#194: no answer would go out),
    /// or on an unpaired phone (no key signs); the answers on offer (both,
    /// or the one sent again) where a biometric match is possible, and
    /// otherwise the reason there are none. A changed enrollment keeps the
    /// answers and says so over them.
    nonisolated static func offer(for status: RequestStatus, biometry: BiometricAvailability,
                                  key: PhoneKeyring.Health, readOnly: Bool = false) -> Offer {
        guard status.isAnswerable else { return .none }
        if readOnly { return Offer(answers: nil, caption: readOnlyLine) }
        if case .unpaired(let reason) = key { return Offer(answers: nil, caption: unpaired(reason, biometry.kind)) }
        guard case .available(let kind) = biometry else { return Offer(answers: nil, caption: answersUnavailable(biometry.kind)) }
        return Offer(answers: kind, again: status.resend, caption: key == .enrollmentChanged ? enrollmentChanged(kind) : nil)
    }

    /// The footnote is true only while an answer from here can still go
    /// out: a withdrawn prompt may already be closed on the Mac, and an
    /// expired one says so in its own line. A read-only inbox's prompt has
    /// none: no answer goes out from here, and its line already says to
    /// answer on the Mac (#194).
    nonisolated static func showsFootnote(_ status: RequestStatus, readOnly: Bool = false) -> Bool {
        if readOnly { return false }
        switch status {
        case .pending, .confirming, .sending: return true
        case .sent, .answered, .expired, .withdrawn: return false
        }
    }

    /// The footnote's words: once iCloud left an answer unconfirmed, and
    /// through any resend under way, it no longer says the dialog stays
    /// open (#154).
    nonisolated static func footnoteText(_ status: RequestStatus) -> String {
        status.afterUnconfirmed ? unconfirmedFootnote : footnote
    }

    /// What VoiceOver reads for the prompt card.
    nonisolated static func spoken(_ request: PendingRequest) -> String {
        "\(request.toolName) permission prompt, project \(request.projectLabel). \(inputHeader): \(request.inputPreview)"
    }

    let request: PendingRequest
    let status: RequestStatus
    let now: Date
    let biometry: BiometricAvailability
    /// Where this phone's pairing stands.
    let key: PhoneKeyring.Health
    /// Whether answers from here go nowhere (`RequestInbox.isReadOnly`).
    let readOnly: Bool
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
                if Self.showsFootnote(status, readOnly: readOnly) {
                    Text(Self.footnoteText(status))
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
    /// in the ink; every other state is a caption. While the match is asked
    /// for, the line names the answer and this phone's biometric.
    @ViewBuilder private var stateLine: some View {
        let line = status.line(at: now, biometric: biometry.kind)
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

    /// Allow in the accent, Deny in the ink, each with the biometric's
    /// glyph and words, each only while on offer (after iCloud left an
    /// answer unconfirmed, that one alone, sent again); or the reason there
    /// are none.
    @ViewBuilder private var answers: some View {
        let offer = Self.offer(for: status, biometry: biometry, key: key, readOnly: readOnly)
        if let caption = offer.caption {
            CaptionLine(line: caption)
        }
        if let kind = offer.answers {
            if offer.offers(.allow) {
                Button(action: allow) {
                    Label(Self.title(.allow, kind, in: offer), systemImage: kind.symbol)
                }
                .buttonStyle(RequestButtonStyle(emphasis: .accent))
                .accessibilityHint(Self.answerHint(kind))
            }
            if offer.offers(.deny) {
                Button(action: deny) {
                    Label(Self.title(.deny, kind, in: offer), systemImage: kind.symbol)
                }
                .buttonStyle(RequestButtonStyle(emphasis: .ink))
                .accessibilityHint(Self.answerHint(kind))
            }
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
                         biometry: .available(.faceID), key: .paired, readOnly: false, allow: {}, deny: {})
}

#Preview("Expired") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-660)),
                         status: .expired, now: now, biometry: .available(.faceID), key: .paired, readOnly: false,
                         allow: {}, deny: {})
}

#Preview("Withdrawn") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-120)),
                         status: .withdrawn, now: now, biometry: .available(.faceID), key: .paired, readOnly: false,
                         allow: {}, deny: {})
}

#Preview("Unconfirmed") {
    let now: Date = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-60)),
                         status: .pending(until: now.addingTimeInterval(540), note: .unconfirmed(.allow)), now: now,
                         biometry: .available(.faceID), key: .paired, readOnly: false, allow: {}, deny: {})
}

#Preview("Unpaired") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-60)),
                         status: .pending(until: now.addingTimeInterval(540), note: nil), now: now,
                         biometry: .available(.faceID), key: .unpaired(.enrollmentChanged), readOnly: false, allow: {},
                         deny: {})
}

/// The live inbox until the answer path is armed (#194): no answer offered,
/// no footnote.
#Preview("Read only") {
    let now = Date.now
    PendingRequestScreen(request: FixtureRequests.request(createdAt: now.addingTimeInterval(-60)),
                         status: .pending(until: now.addingTimeInterval(540), note: nil), now: now,
                         biometry: .available(.faceID), key: .paired, readOnly: true, allow: {}, deny: {})
}
