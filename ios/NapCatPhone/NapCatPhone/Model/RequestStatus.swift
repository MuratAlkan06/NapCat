import Foundation
import NapCatWire

/// Why a pending request carries a note: the last answer did not go out.
enum RequestNote: Equatable, CaseIterable, Sendable {
    /// The answer was not confirmed by the biometric match.
    case notConfirmed
    /// Nothing was saved.
    case unsent
    /// iCloud did not confirm the answer.
    case unconfirmed
}

/// What the request screen shows: the request's phase and this phone's
/// answer, folded into one state, with its words. Only `.pending` is
/// answerable. The words never claim more than the phone knows: once an
/// answer is saved it is "Sent", never "Allowed" — what the Mac does with
/// it is the Mac's to say.
enum RequestStatus: Equatable, Sendable {
    case pending(until: Date, note: RequestNote?)
    case confirming
    case sending(ApprovalWire.Verdict)
    case sent(ApprovalWire.Verdict)
    case answered
    case expired
    case withdrawn

    /// A saved answer outranks everything, and one under way stays in sight
    /// until it is done; otherwise a finished request says why it is
    /// finished, and a pending one what this phone last did.
    init(phase: RequestPhase, answer: RequestAnswer) {
        switch (answer, phase) {
        case (.sent(let verdict), _): self = .sent(verdict)
        case (.answeredElsewhere, _): self = .answered
        case (.sending(let verdict), _): self = .sending(verdict)
        case (_, .withdrawn): self = .withdrawn
        case (_, .expired): self = .expired
        case (.confirming, .pending): self = .confirming
        case (.none, .pending(let until)): self = .pending(until: until, note: nil)
        case (.notConfirmed, .pending(let until)): self = .pending(until: until, note: .notConfirmed)
        case (.unsent, .pending(let until)): self = .pending(until: until, note: .unsent)
        case (.unconfirmed, .pending(let until)): self = .pending(until: until, note: .unconfirmed)
        }
    }

    /// Whether Allow and Deny can be on offer.
    var isAnswerable: Bool {
        if case .pending = self { return true }
        return false
    }

    /// The state line, in the caption register: one state word, an em dash,
    /// the cause, no closing period. The last minute of a pending request
    /// is a warning (glyph, tint and "Warning:" for VoiceOver); nothing
    /// counts down.
    func line(at now: Date) -> PhoneLine {
        switch self {
        case .pending(let until, _):
            let severity: PhoneSeverity = Self.minutesLeft(until: until, now: now) >= 1 ? .nominal : .warning
            return PhoneLine(text: "Pending — " + Self.expiry(until: until, now: now), severity: severity)
        case .confirming:
            return PhoneLine(text: "Confirming — waiting for the biometric match", severity: .nominal)
        case .sending(let verdict):
            return PhoneLine(text: "Sending — saving \(Self.name(verdict)) to iCloud", severity: .nominal)
        case .sent(let verdict):
            return PhoneLine(text: "Sent — \(Self.name(verdict)) is saved; your Mac hasn't confirmed it", severity: .nominal)
        case .answered:
            return PhoneLine(text: "Answered — an answer to this prompt was already saved", severity: .info)
        case .expired:
            return PhoneLine(text: "Expired — only your Mac can answer it now", severity: .info)
        case .withdrawn:
            return PhoneLine(text: "Withdrawn — your Mac took this prompt back", severity: .info)
        }
    }

    /// Why the last answer did not go out, over the state line; nil when
    /// there is nothing to say.
    var note: PhoneLine? {
        guard case .pending(_, let note?) = self else { return nil }
        switch note {
        case .notConfirmed:
            return PhoneLine(text: "Unverified — your answer wasn't confirmed, so nothing was sent", severity: .warning)
        case .unsent:
            return PhoneLine(text: "Unsent — couldn't save your answer to iCloud; try again", severity: .warning)
        case .unconfirmed:
            return PhoneLine(text: "Unconfirmed — iCloud didn't confirm your answer; try again", severity: .warning)
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
