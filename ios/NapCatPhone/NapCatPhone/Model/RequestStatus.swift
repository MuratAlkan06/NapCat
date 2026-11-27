import Foundation
import NapCatWire

/// Why a pending request carries a note: the last answer did not go out,
/// or may have.
enum RequestNote: Equatable, Sendable {
    /// The answer was not confirmed by the biometric match.
    case notConfirmed
    /// The paired key did not sign the answer.
    case unsigned
    /// Nothing was saved.
    case unsent
    /// iCloud did not confirm the answer named: it may have been saved, and
    /// the Mac counts the first answer saved, so it is the only answer
    /// offered again (#154).
    case unconfirmed(ApprovalWire.Verdict)
}

/// What the request screen shows: the request's phase and this phone's
/// answer, folded into one state, with its words. Only `.pending` is
/// answerable. The words never claim more than the phone knows: once an
/// answer is saved it is "Sent", never "Allowed" — what the Mac does with
/// it is the Mac's to say.
enum RequestStatus: Equatable, Sendable {
    case pending(until: Date, note: RequestNote?)
    /// The answer named is waiting for the biometric match: the line says
    /// which one the match will sign. `afterUnconfirmed`: iCloud left an
    /// answer to this request unconfirmed before (#154), so that answer may
    /// stand on the Mac already; a resend under way keeps saying so.
    case confirming(ApprovalWire.Verdict, afterUnconfirmed: Bool = false)
    /// The answer named is being saved; `afterUnconfirmed` as above.
    case sending(ApprovalWire.Verdict, afterUnconfirmed: Bool = false)
    case sent(ApprovalWire.Verdict)
    case answered
    case expired
    case withdrawn

    /// A saved answer outranks everything, and one under way stays in sight
    /// until it is done; otherwise a finished request says why it is
    /// finished, and a pending one what this phone last did. Once iCloud
    /// left an answer unconfirmed (`mayHaveLanded`, #154), a pending request
    /// says so whatever a later try came to: that answer may stand on the
    /// Mac already, and it is the only one offered again. A resend under
    /// way carries the same fact (`afterUnconfirmed`).
    init(phase: RequestPhase, answer: RequestAnswer, mayHaveLanded: ApprovalWire.Verdict?) {
        switch (answer, phase, mayHaveLanded) {
        case (.sent(let verdict), _, _): self = .sent(verdict)
        case (.answeredElsewhere, _, _): self = .answered
        case (.sending(let verdict), _, let landed): self = .sending(verdict, afterUnconfirmed: landed != nil)
        case (_, .withdrawn, _): self = .withdrawn
        case (_, .expired, _): self = .expired
        case (.confirming(let verdict), .pending, let landed): self = .confirming(verdict, afterUnconfirmed: landed != nil)
        case (_, .pending(let until), let landed?): self = .pending(until: until, note: .unconfirmed(landed))
        case (.none, .pending(let until), nil): self = .pending(until: until, note: nil)
        case (.notConfirmed, .pending(let until), nil): self = .pending(until: until, note: .notConfirmed)
        case (.unsigned, .pending(let until), nil): self = .pending(until: until, note: .unsigned)
        case (.unsent, .pending(let until), nil): self = .pending(until: until, note: .unsent)
        case (.unconfirmed(let verdict), .pending(let until), nil): self = .pending(until: until, note: .unconfirmed(verdict))
        }
    }

    /// The answers that can be on offer: Allow and Deny while pending, but
    /// once iCloud left an answer unconfirmed, that answer alone, to send
    /// again (it may have reached the Mac, which counts the first answer
    /// saved: offering the other would mislead); none while an answer is
    /// under way, nor once the request is finished.
    var answers: [ApprovalWire.Verdict] {
        switch self {
        case .pending(_, .unconfirmed(let verdict)?): return [verdict]
        case .pending: return ApprovalWire.Verdict.allCases
        case .confirming, .sending, .sent, .answered, .expired, .withdrawn: return []
        }
    }

    /// Whether any answer can be on offer.
    var isAnswerable: Bool {
        !answers.isEmpty
    }

    /// The one answer on offer, to send again, after iCloud left it
    /// unconfirmed; nil when both are on offer, or neither.
    var resend: ApprovalWire.Verdict? {
        guard case .pending(_, .unconfirmed(let verdict)?) = self else { return nil }
        return verdict
    }

    /// Whether iCloud left an answer to this request unconfirmed (#154), so
    /// it may stand on the Mac already: from the unconfirmed note on, and
    /// through a resend under way; false once the request is finished.
    var afterUnconfirmed: Bool {
        switch self {
        case .pending(_, .unconfirmed?): return true
        case .confirming(_, let after), .sending(_, let after): return after
        case .pending, .sent, .answered, .expired, .withdrawn: return false
        }
    }

    /// The state line, in the caption register: one state word, an em dash,
    /// the cause, no closing period. The last minute of a pending request
    /// is a warning (glyph, tint and "Warning:" for VoiceOver); nothing
    /// counts down. While the match is asked for, the line names the answer
    /// it will sign and `biometric`, the one this phone has (the screen
    /// passes it; without one, "the biometric match").
    func line(at now: Date, biometric: BiometryKind? = nil) -> PhoneLine {
        switch self {
        case .pending(let until, _):
            let severity: PhoneSeverity = Self.minutesLeft(until: until, now: now) >= 1 ? .nominal : .warning
            return PhoneLine(text: "Pending — " + Self.expiry(until: until, now: now), severity: severity)
        case .confirming(let verdict, _):
            let match = biometric?.name ?? "the biometric match"
            return PhoneLine(text: "Confirming — \(Self.name(verdict)), waiting for \(match)", severity: .nominal)
        case .sending(let verdict, _):
            return PhoneLine(text: "Sending — saving \(Self.name(verdict)) to iCloud", severity: .nominal)
        case .sent(let verdict):
            return PhoneLine(text: "Sent — \(Self.name(verdict)) is saved; your Mac hasn't confirmed it", severity: .nominal)
        case .answered:
            return PhoneLine(text: "Answered — an answer to this prompt was already saved", severity: .info)
        case .expired:
            return PhoneLine(text: "Expired — only your Mac can answer it now", severity: .info)
        case .withdrawn:
            return PhoneLine(text: "Withdrawn — this prompt was taken back", severity: .info)
        }
    }

    /// Why the last answer did not go out, or that one may have, over the
    /// state line; nil when there is nothing to say.
    var note: PhoneLine? {
        guard case .pending(_, let note?) = self else { return nil }
        switch note {
        case .notConfirmed:
            return PhoneLine(text: "Unverified — your answer wasn't confirmed, so nothing was sent", severity: .warning)
        case .unsigned:
            return PhoneLine(text: "Unsigned — this iPhone couldn't sign your answer, so nothing was sent; try again",
                             severity: .warning)
        case .unsent:
            return PhoneLine(text: "Unsent — couldn't save your answer to iCloud; try again", severity: .warning)
        case .unconfirmed(let verdict):
            let name: String = Self.name(verdict)
            return PhoneLine(text: "Unconfirmed — \(name) may already have reached your Mac; only \(name) can be sent again",
                             severity: .warning)
        }
    }

    /// Whole minutes left, rounded down, so the line never promises time
    /// the request does not have.
    static func expiry(until: Date, now: Date) -> String {
        let minutes = minutesLeft(until: until, now: now)
        return minutes >= 1 ? "expires in \(minutes) min" : "expires in under a minute"
    }

    static func minutesLeft(until: Date, now: Date) -> Int {
        Int((until.timeIntervalSince(now) / 60).rounded(.down))
    }

    static func name(_ verdict: ApprovalWire.Verdict) -> String {
        switch verdict {
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
}
