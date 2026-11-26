import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing
import UIKit

/// The request screen's words, offers, redraw schedule and wiring (F4,
/// slice S3). SwiftUI composition cannot be driven headlessly, so the
/// composition is locked over the source, and each lock is run against
/// mutated copies so it can fail.
@MainActor
@Suite struct PendingRequestScreenTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let everyStatus: [RequestStatus] = [
        .pending(until: now.addingTimeInterval(540), note: nil),
        .pending(until: now.addingTimeInterval(540), note: .notConfirmed),
        .pending(until: now.addingTimeInterval(540), note: .unsent),
        .pending(until: now.addingTimeInterval(540), note: .unconfirmed(.allow)),
        .pending(until: now.addingTimeInterval(540), note: .unconfirmed(.deny)),
        .pending(until: now.addingTimeInterval(540), note: .unsigned),
        .confirming(.allow), .confirming(.deny), .sending(.allow), .sending(.deny), .sent(.allow), .sent(.deny), .answered, .expired,
        .withdrawn,
    ]

    /// A resend under way after iCloud left an answer unconfirmed (#154):
    /// each reads as its twin in `everyStatus` but for the footnote.
    static let everyResend: [RequestStatus] = [
        .confirming(.allow, afterUnconfirmed: true), .confirming(.deny, afterUnconfirmed: true),
        .sending(.allow, afterUnconfirmed: true), .sending(.deny, afterUnconfirmed: true),
    ]

    // MARK: The words

    /// Every line the screen can show is in the caption register: one state
    /// word, an em dash, the cause, no closing period.
    static let everyUnavailableLine = (BiometryKind.allCases.map { Optional($0) } + [nil])
        .map(PendingRequestScreen.answersUnavailable)
    /// Every pairing line: unpaired for each reason, and changed.
    static let everyPairingLine = [PhoneKeyring.UnpairedReason.neverPaired, .enrollmentChanged, .unreadable]
        .flatMap { reason in (BiometryKind.allCases.map { Optional($0) } + [nil]).map { PendingRequestScreen.unpaired(reason, $0) } }
        + BiometryKind.allCases.map(PendingRequestScreen.enrollmentChanged)

    @Test func everyLineIsInTheCaptionRegister() {
        var lines = Self.everyStatus.map { $0.line(at: Self.now) } + Self.everyStatus.compactMap(\.note)
        lines += Self.everyUnavailableLine + Self.everyPairingLine
        lines += Self.everyStatus.flatMap { status in BiometryKind.allCases.map { status.line(at: Self.now, biometric: $0) } }
        lines.append(RequestStatus.pending(until: Self.now.addingTimeInterval(30), note: nil).line(at: Self.now))
        lines.append(PendingRequestScreen.longInput)
        for line in lines {
            #expect(ListStateTests.captionRegisterFailures(line.text).isEmpty,
                    "\(ListStateTests.captionRegisterFailures(line.text))")
        }
    }

    @Test func theLinesSayExactlyThis() {
        func text(_ status: RequestStatus) -> String { status.line(at: Self.now).text }
        #expect(text(.pending(until: Self.now.addingTimeInterval(540), note: nil)) == "Pending — expires in 9 min")
        #expect(RequestStatus.confirming(.allow).line(at: Self.now, biometric: .faceID).text
                == "Confirming — Allow, waiting for Face ID")
        #expect(RequestStatus.confirming(.deny).line(at: Self.now, biometric: .faceID).text
                == "Confirming — Deny, waiting for Face ID")
        #expect(RequestStatus.confirming(.deny).line(at: Self.now, biometric: .touchID).text
                == "Confirming — Deny, waiting for Touch ID")
        #expect(text(.confirming(.allow)) == "Confirming — Allow, waiting for the biometric match")
        #expect(text(.sending(.allow)) == "Sending — saving Allow to iCloud")
        #expect(text(.sent(.allow)) == "Sent — Allow is saved; your Mac hasn't confirmed it")
        #expect(text(.sent(.deny)) == "Sent — Deny is saved; your Mac hasn't confirmed it")
        #expect(text(.answered) == "Answered — an answer to this prompt was already saved")
        #expect(text(.expired) == "Expired — only your Mac can answer it now")
        #expect(text(.withdrawn) == "Withdrawn — your Mac took this prompt back")
        #expect(PendingRequestScreen.allowTitle(.faceID) == "Allow with Face ID")
        #expect(PendingRequestScreen.allowTitle(.touchID) == "Allow with Touch ID")
        #expect(PendingRequestScreen.denyTitle(.faceID) == "Deny with Face ID")
        #expect(PendingRequestScreen.denyTitle(.opticID) == "Deny with Optic ID")
        #expect(PendingRequestScreen.answerHint(.faceID) == "Asks for Face ID first.")
        #expect(PendingRequestScreen.againTitle(.allow, .faceID) == "Send Allow again with Face ID")
        #expect(PendingRequestScreen.againTitle(.deny, .touchID) == "Send Deny again with Touch ID")
        #expect(PendingRequestScreen.answersUnavailable(.faceID).text
                == "Unavailable — answering needs Face ID turned on; answer on your Mac")
        #expect(PendingRequestScreen.answersUnavailable(nil).text
                == "Unavailable — this phone can't confirm answers with biometrics; answer on your Mac")
        #expect(RequestStatus.pending(until: Self.now, note: .notConfirmed).note?.text
                == "Unverified — your answer wasn't confirmed, so nothing was sent")
        #expect(RequestStatus.pending(until: Self.now, note: .unsigned).note?.text
                == "Unsigned — this iPhone couldn't sign your answer, so nothing was sent; try again")
        #expect(RequestStatus.pending(until: Self.now, note: .unconfirmed(.allow)).note?.text
                == "Unconfirmed — Allow may already have reached your Mac; only Allow can be sent again")
        #expect(RequestStatus.pending(until: Self.now, note: .unconfirmed(.deny)).note?.text
                == "Unconfirmed — Deny may already have reached your Mac; only Deny can be sent again")
        #expect(PendingRequestScreen.unpaired(.neverPaired, .faceID).text
                == "Unpaired — pair this iPhone with your Mac to answer here; answer on your Mac")
        #expect(PendingRequestScreen.unpaired(.enrollmentChanged, .faceID).text
                == "Unpaired — Face ID changed, so this iPhone's key stopped working; pair again with your Mac")
        #expect(PendingRequestScreen.unpaired(.enrollmentChanged, nil).text
                == "Unpaired — your biometrics changed, so this iPhone's key stopped working; pair again with your Mac")
        #expect(PendingRequestScreen.unpaired(.unreadable, .faceID).text
                == "Unpaired — this iPhone couldn't read its key; answer on your Mac")
        #expect(PendingRequestScreen.enrollmentChanged(.faceID).text
                == "Changed — Face ID changed since pairing; if answering fails, pair again with your Mac")
        #expect(PendingRequestScreen.longInput.text == "Long — the input scrolls inside its box")
    }

    /// The unavailable line names the biometric this phone has, and no
    /// other: never "Face ID or Touch ID".
    @Test(arguments: BiometryKind.allCases)
    func theUnavailableLineNamesThePhonesBiometric(_ kind: BiometryKind) {
        let text = PendingRequestScreen.answersUnavailable(kind).text
        #expect(text.contains(kind.name))
        for other in BiometryKind.allCases where other != kind {
            #expect(!text.contains(other.name), "'\(text)' names \(other.name)")
        }
        let unnamed = PendingRequestScreen.answersUnavailable(nil).text
        #expect(!unnamed.contains(kind.name), "'\(unnamed)' names \(kind.name) on a phone without it")
    }

    /// While the biometric prompt is up, the line says which answer the
    /// match will sign, and the biometric it waits for: Allow and Deny never
    /// read alike, and only this phone's biometric is named. The wait is
    /// nominal (nothing is wrong yet), and like every state word it claims
    /// nothing of the Mac.
    @Test(arguments: BiometryKind.allCases)
    func theConfirmingLineNamesTheAnswerBeingSigned(_ kind: BiometryKind) {
        let allow = RequestStatus.confirming(.allow).line(at: Self.now, biometric: kind)
        let deny = RequestStatus.confirming(.deny).line(at: Self.now, biometric: kind)
        #expect(allow.text != deny.text)
        for (line, named, other) in [(allow, "Allow", "Deny"), (deny, "Deny", "Allow")] {
            #expect(line.text.hasPrefix("Confirming — \(named), "), "\(line.text)")
            #expect(!line.text.contains(other), "\(line.text)")
            #expect(line.text.hasSuffix("waiting for \(kind.name)"), "\(line.text)")
            for elsewhere in BiometryKind.allCases where elsewhere != kind {
                #expect(!line.text.contains(elsewhere.name), "'\(line.text)' names \(elsewhere.name)")
            }
            #expect(line.severity == .nominal)
            #expect(line.spoken == line.text, "VoiceOver reads the line as it is")
        }
        // The biometric changes only the confirming line.
        for status in Self.everyStatus {
            if case .confirming = status { continue }
            #expect(status.line(at: Self.now, biometric: kind) == status.line(at: Self.now), "\(status)")
        }
    }

    /// Never "Allowed" or "Approved": a saved answer is sent, and only the
    /// Mac can say what it did with it.
    @Test func noLineClaimsTheMacActed() {
        let lines = Self.everyStatus.map { $0.line(at: Self.now).text } + Self.everyStatus.compactMap(\.note?.text)
        for line in lines {
            for claim in ["Allowed", "Approved", "Denied", "Resolved", "Done"] {
                #expect(!line.contains(claim), "'\(line)' claims the Mac acted")
            }
        }
    }

    /// Every state reads differently in words alone.
    @Test func everyStateReadsDifferentlyWithoutColor() {
        let words = Self.everyStatus.map { [$0.note?.text ?? "", $0.line(at: Self.now).text].joined(separator: "|") }
        #expect(Set(words).count == Self.everyStatus.count)
    }

    /// Whole minutes, rounded down; under a minute is said as such.
    @Test(arguments: [(600.0, "expires in 10 min"), (599, "expires in 9 min"), (61, "expires in 1 min"),
                      (60, "expires in 1 min"), (59, "expires in under a minute"), (1, "expires in under a minute")])
    func theExpiryLineNeverOverstates(_ seconds: TimeInterval, _ words: String) {
        #expect(RequestStatus.expiry(until: Self.now.addingTimeInterval(seconds), now: Self.now) == words)
    }

    /// Warnings carry a glyph and are spoken as such; quiet states are not.
    @Test func severitiesMatchWhatHappened() {
        #expect(RequestStatus.pending(until: Self.now, note: .unsent).note?.severity == .warning)
        #expect(RequestStatus.pending(until: Self.now, note: .notConfirmed).note?.severity == .warning)
        #expect(RequestStatus.pending(until: Self.now, note: .unconfirmed(.allow)).note?.severity == .warning)
        #expect(RequestStatus.expired.line(at: Self.now).severity == .info)
        #expect(RequestStatus.withdrawn.line(at: Self.now).severity == .info)
        #expect(RequestStatus.sent(.allow).line(at: Self.now).severity == .nominal)
        #expect(Self.everyUnavailableLine.allSatisfy { $0.severity == .warning })
    }

    /// The last minute reads as a warning (the theme's warning glyph and
    /// tint, and "Warning:" for VoiceOver), so "under a minute" never looks
    /// like "8 min". The line changes only at the minute marks the sheet
    /// already redraws at: nothing counts down.
    @Test(arguments: [(600.0, PhoneSeverity.nominal), (61, .nominal), (60, .nominal), (59, .warning), (1, .warning)])
    func theLastMinuteIsAWarning(_ seconds: TimeInterval, _ severity: PhoneSeverity) {
        let until = Self.now.addingTimeInterval(seconds)
        let line = RequestStatus.pending(until: until, note: nil).line(at: Self.now)
        #expect(line.severity == severity)
        if severity == .warning {
            #expect(line.spoken == "Warning: Pending — expires in under a minute")
            #expect(PendingRequestSheet.schedule(now: until.addingTimeInterval(-90), until: until).contains(until.addingTimeInterval(-60)),
                    "the sheet redraws when the last minute starts")
        }
        // The same reading with a note keeps its warning.
        #expect(RequestStatus.pending(until: until, note: .unsent).line(at: Self.now).severity == severity)
    }

    // MARK: The offer

    /// Only an answerable request offers anything; then its answers where
    /// a biometric match is possible (each asks for one: the owner's
    /// uniform-signing ruling): both, or after an unconfirmed answer that
    /// one alone (#154); and neither where it is not, with the reason said
    /// instead. Deny is never on offer without the match.
    @Test func answersAreOfferedOnlyWhileAnswerable() {
        for status in Self.everyStatus {
            let offer = PendingRequestScreen.offer(for: status, biometry: .available(.faceID), key: .paired)
            if status.isAnswerable {
                #expect(offer == PendingRequestScreen.Offer(answers: .faceID, again: status.resend, caption: nil), "\(status)")
                let offered: [ApprovalWire.Verdict] = ApprovalWire.Verdict.allCases.filter(offer.offers)
                #expect(offered == status.answers, "\(status)")
                for unavailable in [BiometricAvailability.unavailable(.faceID), .unavailable(nil)] {
                    #expect(PendingRequestScreen.offer(for: status, biometry: unavailable, key: .paired)
                            == PendingRequestScreen.Offer(answers: nil,
                                                          caption: PendingRequestScreen.answersUnavailable(unavailable.kind)),
                            "\(status)")
                }
            } else {
                #expect(offer == .none, "\(status)")
                #expect(PendingRequestScreen.offer(for: status, biometry: .unavailable(.faceID), key: .paired) == .none, "\(status)")
                #expect(PendingRequestScreen.offer(for: status, biometry: .available(.faceID), key: .unpaired(.neverPaired)) == .none)
            }
        }
        #expect(!RequestStatus.expired.isAnswerable && !RequestStatus.withdrawn.isAnswerable)
    }

    /// Every answer is signed by the paired key, so an unpaired phone
    /// offers none (and says why, whatever its biometrics); a changed
    /// enrollment keeps both answers (the key decides) and says so.
    @Test func thePairingDecidesTheOffer() {
        let pending = RequestStatus.pending(until: Self.now.addingTimeInterval(540), note: nil)
        for reason in [PhoneKeyring.UnpairedReason.neverPaired, .enrollmentChanged, .unreadable] {
            for biometry in [BiometricAvailability.available(.faceID), .unavailable(.touchID), .unavailable(nil)] {
                #expect(PendingRequestScreen.offer(for: pending, biometry: biometry, key: .unpaired(reason))
                        == PendingRequestScreen.Offer(answers: nil, caption: PendingRequestScreen.unpaired(reason, biometry.kind)))
            }
        }
        #expect(PendingRequestScreen.offer(for: pending, biometry: .available(.opticID), key: .enrollmentChanged)
                == PendingRequestScreen.Offer(answers: .opticID, caption: PendingRequestScreen.enrollmentChanged(.opticID)))
        #expect(PendingRequestScreen.offer(for: pending, biometry: .unavailable(.faceID), key: .enrollmentChanged)
                == PendingRequestScreen.Offer(answers: nil, caption: PendingRequestScreen.answersUnavailable(.faceID)))
    }

    /// After iCloud left an answer unconfirmed, that answer alone is on
    /// offer, titled as sent again, with the biometric and the same hint;
    /// the other is not on offer at all (#154). Any other note keeps both
    /// answers under their own titles. A phone that cannot answer still
    /// offers none, and says why.
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func afterAnUnconfirmedAnswerOnlyThatAnswerIsOfferedAgain(_ verdict: ApprovalWire.Verdict) {
        let other: ApprovalWire.Verdict = RequestAnsweringTests.other(verdict)
        let until: Date = Self.now.addingTimeInterval(540)
        let status: RequestStatus = .pending(until: until, note: .unconfirmed(verdict))
        for kind in BiometryKind.allCases {
            let offer: PendingRequestScreen.Offer = PendingRequestScreen.offer(for: status, biometry: .available(kind), key: .paired)
            #expect(offer == PendingRequestScreen.Offer(answers: kind, again: verdict, caption: nil))
            #expect(offer.offers(verdict) && !offer.offers(other))
            let title: String = PendingRequestScreen.title(verdict, kind, in: offer)
            #expect(title == "Send \(RequestStatus.name(verdict)) again with \(kind.name)")
        }
        let changed: PendingRequestScreen.Offer = PendingRequestScreen.offer(for: status, biometry: .available(.faceID),
                                                                             key: .enrollmentChanged)
        #expect(changed == PendingRequestScreen.Offer(answers: .faceID, again: verdict,
                                                      caption: PendingRequestScreen.enrollmentChanged(.faceID)))
        #expect(PendingRequestScreen.offer(for: status, biometry: .unavailable(.faceID), key: .paired)
                == PendingRequestScreen.Offer(answers: nil, caption: PendingRequestScreen.answersUnavailable(.faceID)))
        #expect(PendingRequestScreen.offer(for: status, biometry: .available(.faceID), key: .unpaired(.neverPaired))
                == PendingRequestScreen.Offer(answers: nil, caption: PendingRequestScreen.unpaired(.neverPaired, .faceID)))
        let notes: [RequestNote?] = [nil, .notConfirmed, .unsigned, .unsent]
        for note in notes {
            let both: PendingRequestScreen.Offer = PendingRequestScreen.offer(for: .pending(until: until, note: note),
                                                                              biometry: .available(.faceID), key: .paired)
            #expect(both == PendingRequestScreen.Offer(answers: .faceID, caption: nil), "\(String(describing: note))")
            #expect(both.offers(.allow) && both.offers(.deny))
            #expect(PendingRequestScreen.title(.allow, .faceID, in: both) == "Allow with Face ID")
            #expect(PendingRequestScreen.title(.deny, .faceID, in: both) == "Deny with Face ID")
        }
        #expect(!PendingRequestScreen.Offer.none.offers(.allow) && !PendingRequestScreen.Offer.none.offers(.deny))
    }

    /// "The dialog on your Mac stays open" is said only while an answer from
    /// here can still go out: never for a withdrawn prompt (the Mac may have
    /// closed it), nor once the phone's part is over.
    @Test func theFootnoteIsSaidOnlyWhileItIsTrue() {
        for status in Self.everyStatus {
            let expected: Bool = switch status {
            case .pending, .confirming, .sending: true
            case .sent, .answered, .expired, .withdrawn: false
            }
            #expect(PendingRequestScreen.showsFootnote(status) == expected, "\(status)")
        }
    }

    /// After iCloud left an answer unconfirmed it may have reached the Mac,
    /// whose dialog then closed: from the note on, and through a resend
    /// under way, the footnote says "if it is still open" (#154). Every
    /// other state that has a footnote keeps the usual words.
    @Test func afterAnUnconfirmedAnswerTheFootnoteNoLongerSaysTheDialogStaysOpen() {
        #expect(PendingRequestScreen.footnote == "The dialog on your Mac stays open, and you can answer it there instead.")
        #expect(PendingRequestScreen.unconfirmedFootnote
                == "If the dialog on your Mac is still open, you can answer it there instead.")
        let states: [RequestStatus] = Self.everyStatus + Self.everyResend
        var unconfirmed: Int = 0
        for status in states where PendingRequestScreen.showsFootnote(status) {
            let expected: String
            switch status {
            case .pending(_, .unconfirmed?), .confirming(_, afterUnconfirmed: true), .sending(_, afterUnconfirmed: true):
                expected = PendingRequestScreen.unconfirmedFootnote
                unconfirmed += 1
            case .pending, .confirming, .sending, .sent, .answered, .expired, .withdrawn:
                expected = PendingRequestScreen.footnote
            }
            #expect(PendingRequestScreen.footnoteText(status) == expected, "\(status)")
        }
        #expect(unconfirmed == 6, "both unconfirmed notes and the four resends under way")
    }

    /// A resend under way reads as any answer under way (the same line, no
    /// note, nothing on offer, the card live); only the footnote differs.
    @Test func aResendUnderWayReadsAsItsTwinButForTheFootnote() {
        let twins: [RequestStatus] = [.confirming(.allow), .confirming(.deny), .sending(.allow), .sending(.deny)]
        for (resend, twin) in zip(Self.everyResend, twins) {
            #expect(resend != twin && resend.afterUnconfirmed && !twin.afterUnconfirmed, "\(resend)")
            #expect(resend.line(at: Self.now, biometric: .faceID) == twin.line(at: Self.now, biometric: .faceID))
            #expect(resend.note == nil && resend.answers.isEmpty && resend.resend == nil, "\(resend)")
            #expect(PendingRequestScreen.offer(for: resend, biometry: .available(.faceID), key: .paired) == .none)
            #expect(!PendingRequestScreen.mutesCard(resend) && PendingRequestScreen.showsFootnote(resend), "\(resend)")
            #expect(PendingRequestScreen.footnoteText(twin) == PendingRequestScreen.footnote, "\(twin)")
        }
    }

    /// Over the inbox's own states: the first answer under way keeps the
    /// usual footnote; once iCloud left it unconfirmed, the footnote says
    /// "if it is still open" and keeps saying so while the answer is sent
    /// again (its match asked for, its save under way) and after that
    /// resend comes back unconfirmed too. VoiceOver hears the note once,
    /// as it first appears, and nothing else on the way (#154).
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func aResendUnderWayKeepsTheUnconfirmedFootnote(_ verdict: ApprovalWire.Verdict) async {
        let clock: TestClock = TestClock()
        let gate: ScriptedBiometricGate = ScriptedBiometricGate()
        let writer: PeekingDecisionWriter = PeekingDecisionWriter(.unconfirmed)
        let inbox: RequestInbox = RequestInbox(writer: writer, biometrics: gate, keyring: RequestFixtures.pairedKeyring(),
                                               clock: { clock.now })
        let request: PendingRequest = RequestFixtures.request(1, createdAt: clock.now)
        inbox.receive([request])
        var seen: [RequestStatus] = []
        let look: () -> Void = { if let status = inbox.status(of: request.id) { seen.append(status) } }
        gate.during = look
        writer.during = look
        look()
        for _ in 0..<2 {
            switch verdict {
            case .allow: await inbox.allow(request.id)
            case .deny: await inbox.deny(request.id)
            }
            look()
        }
        let until: Date = request.expiresAt
        let unconfirmed: RequestStatus = .pending(until: until, note: .unconfirmed(verdict))
        let expected: [RequestStatus] = [
            .pending(until: until, note: nil), .confirming(verdict), .sending(verdict), unconfirmed,
            .confirming(verdict, afterUnconfirmed: true), .sending(verdict, afterUnconfirmed: true), unconfirmed,
        ]
        #expect(seen == expected)
        let usual: String = PendingRequestScreen.footnote
        let ifOpen: String = PendingRequestScreen.unconfirmedFootnote
        let footnotes: [String] = seen.map(PendingRequestScreen.footnoteText)
        #expect(footnotes == [usual, usual, usual, ifOpen, ifOpen, ifOpen, ifOpen])
        let spoken: [String?] = zip(seen, seen.dropFirst()).map { PendingRequestScreen.announcement(from: $0, to: $1, at: clock.now) }
        let note: String? = unconfirmed.note?.spoken
        #expect(spoken == [nil, nil, note, nil, nil, nil])
    }

    /// The glyphs exist in the system's set.
    @Test func theGlyphsAreSystemSymbols() {
        let tools = ApprovalTool.allCases.map { PendingRequestScreen.toolSymbol($0.rawValue) }
        for name in BiometryKind.allCases.map(\.symbol) + tools + [PendingRequestScreen.sentSymbol,
                                                                    PendingRequestScreen.toolSymbol("Other")] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
    }

    /// Every tool the Mac's gate can forward has a glyph of its own; a name
    /// it does not know gets the neutral tool mark, never a question mark
    /// (which reads as suspicion of an ordinary Edit or Write).
    @Test func eachForwardableToolHasItsOwnGlyph() {
        let symbols = ApprovalTool.allCases.map { PendingRequestScreen.toolSymbol($0.rawValue) }
        #expect(PendingRequestScreen.toolSymbol("Bash") == "terminal")
        #expect(!symbols.contains(PendingRequestScreen.otherToolSymbol))
        #expect(Set(symbols).count == ApprovalTool.allCases.count, "\(symbols)")
        for name in ["Other", "", "bash", "WebFetch"] {
            #expect(PendingRequestScreen.toolSymbol(name) == PendingRequestScreen.otherToolSymbol, "\(name)")
        }
        for symbol in symbols + [PendingRequestScreen.otherToolSymbol] {
            #expect(!symbol.contains("questionmark") && !symbol.contains("exclamationmark"), "\(symbol)")
        }
    }

    /// Every tool glyph has the filled form the theme draws, so none reads
    /// as a thin outline beside a filled one (an outline-only symbol keeps
    /// its outline under the fill variant).
    @Test(arguments: ThemeID.allCases)
    func everyToolGlyphHasTheThemesFilledForm(_ id: ThemeID) {
        #expect(id.theme.symbolVariant == .fill)
        let symbols = ApprovalTool.allCases.map { PendingRequestScreen.toolSymbol($0.rawValue) }
        for symbol in symbols + [PendingRequestScreen.otherToolSymbol] {
            #expect(UIImage(systemName: symbol + ".fill") != nil, "\(symbol) has no filled form")
        }
        // Not vacuous: the outlines the review saw have none.
        for outline in ["square.and.pencil", "pencil"] {
            #expect(UIImage(systemName: outline + ".fill") == nil, "\(outline)")
        }
    }

    // MARK: Sent, and the finished card

    /// Sent is a confirmation: its own glyph (a paper plane: it went out,
    /// nothing more) beside the words; no other state carries one.
    @Test func onlySentIsAConfirmation() {
        for status in Self.everyStatus {
            let expected: String? = if case .sent = status { "paperplane" } else { nil }
            #expect(PendingRequestScreen.confirmationSymbol(status) == expected, "\(status)")
        }
    }

    /// VoiceOver hears "Sent" once, as an answer goes out, Allow or Deny,
    /// in the Sent line's own words; no other change is announced, and no
    /// announcement claims the Mac acted. AMENDED (the #154 design review):
    /// but for the unconfirmed note as it first appears, in its own words
    /// (`theUnconfirmedNoteIsAnnouncedOnce`); a resend under way is a state
    /// like any other here.
    @Test func theSentStateIsAnnouncedOnce() {
        #expect(PendingRequestScreen.announcement(from: .sending(.allow), to: .sent(.allow), at: Self.now)
                == "Sent — Allow is saved; your Mac hasn't confirmed it")
        #expect(PendingRequestScreen.announcement(from: .sending(.deny), to: .sent(.deny), at: Self.now)
                == "Sent — Deny is saved; your Mac hasn't confirmed it")
        let states: [RequestStatus] = Self.everyStatus + Self.everyResend
        for old in states {
            for new in states {
                let spoken = PendingRequestScreen.announcement(from: old, to: new, at: Self.now)
                if case .sent = new, old != new {
                    #expect(spoken?.hasPrefix("Sent — ") == true, "\(old) → \(new)")
                    for claim in ["Allowed", "Approved", "Denied", "Done"] {
                        #expect(spoken?.contains(claim) == false, "\(old) → \(new) claims the Mac acted")
                    }
                } else if case .pending(_, .unconfirmed?) = new, old != new, !old.afterUnconfirmed {
                    #expect(spoken != nil && spoken == new.note?.spoken, "\(old) → \(new)")
                    for claim in ["Allowed", "Approved", "Denied", "Done"] {
                        #expect(spoken?.contains(claim) == false, "\(old) → \(new) claims the Mac acted")
                    }
                } else {
                    #expect(spoken == nil, "\(old) → \(new) is announced")
                }
            }
        }
    }

    /// VoiceOver hears the unconfirmed note once, as it first appears (the
    /// screen posts it at high priority, as it does Sent), so the owner
    /// learns only one answer is left to send. Back from a resend under way
    /// (its match not given, or its save unconfirmed again) it is not
    /// announced again, nor is anything that keeps the note (#154).
    @Test(arguments: ApprovalWire.Verdict.allCases)
    func theUnconfirmedNoteIsAnnouncedOnce(_ verdict: ApprovalWire.Verdict) {
        let until: Date = Self.now.addingTimeInterval(540)
        let unconfirmed: RequestStatus = .pending(until: until, note: .unconfirmed(verdict))
        let name: String = RequestStatus.name(verdict)
        let words: String = "Warning: Unconfirmed — \(name) may already have reached your Mac; only \(name) can be sent again"
        let firsts: [RequestStatus] = [.sending(verdict), .confirming(verdict), .pending(until: until, note: nil),
                                       .pending(until: until, note: .unsent)]
        for first in firsts {
            #expect(PendingRequestScreen.announcement(from: first, to: unconfirmed, at: Self.now) == words, "\(first)")
        }
        let backs: [RequestStatus] = [.sending(verdict, afterUnconfirmed: true), .confirming(verdict, afterUnconfirmed: true),
                                      unconfirmed]
        for back in backs {
            #expect(PendingRequestScreen.announcement(from: back, to: unconfirmed, at: Self.now) == nil, "\(back)")
        }
        let nexts: [RequestStatus] = [.confirming(verdict, afterUnconfirmed: true), .sending(verdict, afterUnconfirmed: true),
                                      .answered, .expired, .withdrawn]
        for next in nexts {
            #expect(PendingRequestScreen.announcement(from: unconfirmed, to: next, at: Self.now) == nil, "\(next)")
        }
    }

    /// Once no answer can go out, the card lies flat in the secondary ink;
    /// while one can, it is live. The same states drop the footnote.
    @Test func aFinishedCardLiesFlat() {
        for status in Self.everyStatus {
            let expected: Bool = switch status {
            case .pending, .confirming, .sending: false
            case .sent, .answered, .expired, .withdrawn: true
            }
            #expect(PendingRequestScreen.mutesCard(status) == expected, "\(status)")
            #expect(PendingRequestScreen.mutesCard(status) == !PendingRequestScreen.showsFootnote(status), "\(status)")
        }
    }

    // MARK: The input's box

    /// The box is as tall as the input up to a third of the screen; a
    /// taller input scrolls inside it (and says so), so the state line and
    /// the answers below it are never pushed past two thirds of the screen
    /// by the input.
    @Test func theInputBoxStopsAtItsShareOfTheScreen() {
        let screen: CGFloat = 690
        let cap = screen * PendingRequestScreen.inputShare
        #expect(PendingRequestScreen.inputShare > 0 && PendingRequestScreen.inputShare <= 0.4)
        #expect(PendingRequestScreen.inputBoxHeight(input: 66, screen: screen) == 66)
        #expect(PendingRequestScreen.inputBoxHeight(input: cap, screen: screen) == cap)
        #expect(PendingRequestScreen.inputBoxHeight(input: 30_000, screen: screen) == cap)
        #expect(!PendingRequestScreen.inputScrolls(input: 66, screen: screen))
        #expect(!PendingRequestScreen.inputScrolls(input: cap, screen: screen))
        #expect(PendingRequestScreen.inputScrolls(input: cap + 1, screen: screen))
        // Before the first layout: no frame yet, and nothing said.
        #expect(PendingRequestScreen.inputBoxHeight(input: nil, screen: screen) == nil)
        #expect(!PendingRequestScreen.inputScrolls(input: nil, screen: screen))
        #expect(PendingRequestScreen.inputBoxHeight(input: 500, screen: nil) == 500)
        for height in stride(from: 0, through: 40_000, by: 250) {
            let box = PendingRequestScreen.inputBoxHeight(input: CGFloat(height), screen: screen) ?? .infinity
            #expect(box <= screen * PendingRequestScreen.inputShare, "\(height)")
        }
    }

    /// VoiceOver hears the tool, the project and the input, verbatim.
    @Test func theCardIsSpokenInFull() {
        let request = FixtureRequests.request(createdAt: Self.now)
        #expect(PendingRequestScreen.spoken(request)
                == #"Bash permission prompt, project napcat. Input: {"command":"git status --short"}"#)
    }

    // MARK: The redraw schedule

    @Test func theScreenRedrawsEachMinuteAndAtTheClose() {
        let until = Self.now.addingTimeInterval(150)
        #expect(PendingRequestSheet.schedule(now: Self.now, until: until)
                == [Self.now, until.addingTimeInterval(-120), until.addingTimeInterval(-60), until])
        #expect(PendingRequestSheet.schedule(now: Self.now, until: Self.now.addingTimeInterval(30))
                == [Self.now, Self.now.addingTimeInterval(30)])
        #expect(PendingRequestSheet.schedule(now: Self.now, until: Self.now) == [Self.now])
        #expect(PendingRequestSheet.schedule(now: Self.now, until: nil) == [Self.now])
        // Opened exactly on a whole minute: its reading changes just after
        // now, so now is a mark too.
        #expect(PendingRequestSheet.schedule(now: Self.now, until: Self.now.addingTimeInterval(120))
                == [Self.now, Self.now, Self.now.addingTimeInterval(60), Self.now.addingTimeInterval(120)])
    }

    // MARK: The sheet's clock

    /// A sheet clock on `clock`: each wait is noted, `during` runs in it,
    /// and it ends exactly on the moment waited for (the hard case: a
    /// reading holds through its mark). A clock still waiting after
    /// `stuck` waits is cut off (no window has more than eleven marks).
    static func sheetClock(_ clock: TestClock, waits: Notes<Date>, stuck: Int = 32,
                           during: (@Sendable (Date) async -> Void)? = nil) -> SheetClock {
        SheetClock(now: { clock.now }) { moment in
            waits.note(moment)
            if waits.all.count > stuck { throw CancellationError() }
            await during?(moment)
            clock.set(moment)
        }
    }

    /// What the open screen shows: its state line and the answers it offers.
    struct Reading: Equatable {
        let line: PhoneLine
        let offer: PendingRequestScreen.Offer
    }

    static func reading(_ inbox: RequestInbox, _ id: PromptID, at moment: Date) -> Reading? {
        guard let status = inbox.status(of: id, at: moment) else { return nil }
        return Reading(line: status.line(at: moment),
                       offer: PendingRequestScreen.offer(for: status, biometry: inbox.biometry, key: inbox.keyHealth))
    }

    /// Runs the open sheet's clock for `id` to its end, as the sheet does:
    /// the moments drawn and the waits in between.
    static func follow(_ inbox: RequestInbox, _ id: PromptID, on clock: SheetClock) async -> [Date] {
        var drawn: [Date] = []
        await PendingRequestSheet.follow(clock: clock, closes: { PendingRequestSheet.closes(inbox, id, at: $0) },
                                         redraw: { drawn.append($0) })
        return drawn
    }

    static let answerable = PendingRequestScreen.Offer(answers: .faceID, caption: nil)

    /// The review's case: opened with 70 s left, the screen reads "1 min",
    /// turns into the under-a-minute warning as the last minute starts, and
    /// flips to Expired with its answers gone as the window closes; then its
    /// clock stops. Nothing is touched, nothing reopens.
    @Test func anOpenScreenWarnsAndExpiresOnItsOwn() async throws {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = RequestFixtures.request(1, createdAt: clock.now, window: 70)
        inbox.receive([request])
        let until = clock.now.addingTimeInterval(70)
        let waits = Notes<Date>()
        let drawn = await Self.follow(inbox, request.id, on: Self.sheetClock(clock, waits: waits))
        #expect(waits.all == [until.addingTimeInterval(-60), until])
        try #require(drawn.count == 3)
        let readings = drawn.map { Self.reading(inbox, request.id, at: $0) }
        #expect(readings.map(\.?.line) == [
            PhoneLine(text: "Pending — expires in 1 min", severity: .nominal),
            PhoneLine(text: "Pending — expires in under a minute", severity: .warning),
            PhoneLine(text: "Expired — only your Mac can answer it now", severity: .info),
        ])
        #expect(readings.map(\.?.offer) == [Self.answerable, Self.answerable, PendingRequestScreen.Offer.none])
        // Each change is drawn as it happens, not a moment later.
        #expect(drawn[1] > until.addingTimeInterval(-60) && drawn[1] < until.addingTimeInterval(-59.999))
        #expect(drawn[2] > until && drawn[2] < until.addingTimeInterval(0.001))
    }

    /// Any window: the clock wakes exactly at the schedule's marks, every
    /// wake changes what is drawn, what is drawn holds until the next wake
    /// (never a stale minute, never a live answer past the close), and the
    /// last drawing is Expired, with no answers, after which it stops.
    @Test(arguments: [600.0, 599.5, 150, 120, 70, 60, 59.5, 1, 0.25])
    func theScreenFollowsTheWindowToItsClose(_ window: TimeInterval) async throws {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = RequestFixtures.request(1, createdAt: clock.now, window: window)
        inbox.receive([request])
        let open = clock.now
        let waits = Notes<Date>()
        let drawn = await Self.follow(inbox, request.id, on: Self.sheetClock(clock, waits: waits))
        #expect(waits.all == Array(PendingRequestSheet.schedule(now: open, until: open.addingTimeInterval(window)).dropFirst()))
        try #require(drawn.count == waits.all.count + 1)
        let readings = try drawn.map { try #require(Self.reading(inbox, request.id, at: $0)) }
        for (index, wake) in waits.all.enumerated() {
            let justBefore = Date(timeIntervalSinceReferenceDate: wake.timeIntervalSinceReferenceDate.nextDown)
            if justBefore >= drawn[index] {
                #expect(Self.reading(inbox, request.id, at: justBefore) == readings[index], "stale before \(wake)")
            }
            #expect(readings[index + 1] != readings[index], "a wake at \(wake) changed nothing")
        }
        #expect(readings.dropLast().allSatisfy { $0.offer == Self.answerable })
        #expect(readings.last == Reading(line: RequestStatus.expired.line(at: open), offer: .none))
    }

    /// A final state never changes again, so its screen keeps no clock:
    /// Sent, Answered, Expired and Withdrawn are drawn once and nothing waits.
    @Test func aFinalScreenKeepsNoClock() async {
        let clock = TestClock()
        let sent = RequestFixtures.inbox(clock)
        let answered = RequestInbox(writer: RecordingDecisionWriter(.alreadyAnswered), biometrics: ScriptedBiometricGate(),
                                    keyring: RequestFixtures.pairedKeyring(), clock: { clock.now })
        let request = RequestFixtures.request(1, createdAt: clock.now)
        for inbox in [sent, answered] {
            inbox.receive([request])
            await inbox.deny(request.id)
        }
        let withdrawn = RequestFixtures.inbox(clock)
        withdrawn.receive([request])
        withdrawn.withdraw(request.id)
        let expired = RequestFixtures.inbox(clock)
        expired.receive([RequestFixtures.request(1, createdAt: clock.now, window: 0.5)])
        clock.advance(1)
        let expected: [RequestStatus] = [.sent(.deny), .answered, .withdrawn, .expired]
        for (inbox, status) in zip([sent, answered, withdrawn, expired], expected) {
            #expect(inbox.status(of: request.id, at: clock.now) == status)
            let waits = Notes<Date>()
            let drawn = await Self.follow(inbox, request.id, on: Self.sheetClock(clock, waits: waits))
            #expect(drawn == [clock.now], "\(status)")
            #expect(waits.all.isEmpty, "\(status) keeps a clock")
        }
    }

    /// An answer sent while the clock waits ends it at that wake: the Sent
    /// screen is drawn, and nothing waits after it.
    @Test func aScreenAnsweredWhileWaitingStopsItsClock() async throws {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = RequestFixtures.request(1, createdAt: clock.now)
        inbox.receive([request])
        let waits = Notes<Date>()
        let answering = Self.sheetClock(clock, waits: waits) { _ in await inbox.deny(request.id) }
        let drawn = await Self.follow(inbox, request.id, on: answering)
        #expect(waits.all.count == 1)
        #expect(drawn.count == 2)
        #expect(Self.reading(inbox, request.id, at: try #require(drawn.last))?.line.text
                == "Sent — Deny is saved; your Mac hasn't confirmed it")
    }

    /// Closing the sheet cancels its clock: the wait under way ends at once
    /// and nothing is drawn after it.
    @Test func closingTheSheetStopsItsClock() async {
        let clock = TestClock()
        let inbox = RequestFixtures.inbox(clock)
        let request = RequestFixtures.request(1, createdAt: clock.now)
        inbox.receive([request])
        let waits = Notes<Date>()
        let drawn = Notes<Date>()
        let waiting = SheetClock(now: { clock.now }) { moment in
            waits.note(moment)
            try await Task.sleep(for: .seconds(3_600))
        }
        let open = Task {
            await PendingRequestSheet.follow(clock: waiting, closes: { PendingRequestSheet.closes(inbox, request.id, at: $0) },
                                             redraw: { drawn.note($0) })
        }
        for _ in 0..<10_000 where waits.all.isEmpty { await Task.yield() }
        #expect(waits.all.count == 1, "the clock is waiting")
        open.cancel()
        await open.value
        #expect(drawn.all.count == 1)
        #expect(waits.all.count == 1)
    }

    /// The sheet draws at the moment its clock keeps (never a moment of its
    /// own), keeps that clock in a task (which SwiftUI cancels as the sheet
    /// closes) and no longer leans on a timeline view.
    static func clockFailures(sheet: String) -> [String] {
        let code = SettingsReachabilityTests.flat(sheet)
        var failures: [String] = []
        for shape in [".task { await Self.follow(clock: clock, closes: { Self.closes(inbox, id, at: $0) }, redraw: { now = $0 }) }",
                      "inbox.status(of: id, at: now)", "status: status, now: now,", "@State private var now: Date",
                      "_now = State(initialValue: clock.now())"]
        where !code.contains(shape) {
            failures.append("the sheet lost '\(shape)'")
        }
        for token in ["TimelineView", "Date()", "Date.now", "withAnimation"] where code.contains(token) {
            failures.append("'\(token)' in the sheet — it draws at its clock's moment, at once")
        }
        return failures
    }

    @Test func theSheetDrawsAtItsClocksMoment() throws {
        let sheet = try Self.code(Self.sheetFile)
        #expect(Self.clockFailures(sheet: sheet).isEmpty, "\(Self.clockFailures(sheet: sheet))")
        let mutants: [(String, String)] = [
            ("no clock", sheet.replacingOccurrences(of: "        .task { await Self.follow(", with: "        .onAppear { _ = (")),
            ("its own moment", sheet.replacingOccurrences(of: "inbox.status(of: id, at: now)", with: "inbox.status(of: id, at: Date())")),
            ("a timeline again", sheet.replacingOccurrences(of: "            ZStack {", with: "            TimelineView(.everyMinute) { _ in")),
        ]
        for (name, mutant) in mutants {
            #expect(mutant != sheet, "canary '\(name)' did not apply")
            #expect(!Self.clockFailures(sheet: mutant).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    // MARK: The launch argument

    @Test func theRequestArgumentOpensAFixturePromptAndNothingElse() {
        for state in FixtureRequestState.allCases {
            let options = LaunchOptions { $0 == LaunchOptions.requestKey ? state.rawValue : nil }
            #expect(options.request == state)
            #expect(options.fixtureRequested == false, "it leaves the alert list's source alone")
            var expected = LaunchOptions()
            expected.request = state
            #expect(options == expected)
        }
        #expect(LaunchOptions { $0 == LaunchOptions.requestKey ? "approved" : nil } == LaunchOptions())
        #expect(LaunchOptions().request == nil)
    }

    /// Each fixture state is the state it names, and answers go nowhere.
    @Test(arguments: FixtureRequestState.allCases)
    func eachFixtureInboxIsInItsState(_ state: FixtureRequestState) {
        let inbox = FixtureRequests.inbox(state, now: Self.now, biometrics: ScriptedBiometricGate(),
                                          clock: { Self.now })
        let status = inbox.status(of: FixtureRequests.id)
        switch state {
        case .pending:
            #expect(status?.isAnswerable == true)
            #expect(inbox.keyHealth == .paired)
        case .expired: #expect(status == .expired)
        case .withdrawn: #expect(status == .withdrawn)
        case .unpaired:
            #expect(status?.isAnswerable == true)
            #expect(inbox.keyHealth == .unpaired(.neverPaired))
        case .changed:
            #expect(status?.isAnswerable == true)
            #expect(inbox.keyHealth == .enrollmentChanged)
        }
    }

    // MARK: The wiring (source locks)

    static let appDir = CloudKitStructureTests.appDir
    static let screenFile = "\(appDir)/Screen/PendingRequestScreen.swift"
    static let sheetFile = "\(appDir)/Screen/PendingRequestSheet.swift"

    static func code(_ path: String) throws -> String {
        let app = try CloudKitStructureTests.swiftFiles(under: appDir)
        return try #require(app.first { $0.path == path }).text
    }

    /// The screen offers answers only through `offer(for:biometry:)`, both
    /// or neither (each asks for the match), hands them to its two closures
    /// and never reaches the inbox, the writer or the gate itself; the sheet
    /// routes Allow to `inbox.allow` and Deny to `inbox.deny`, nothing else.
    /// AMENDED (#154): each answer is drawn only while the offer holds it
    /// (`offers(_:)`), so after iCloud left an answer unconfirmed the other
    /// is not drawn at all.
    static func wiringFailures(screen: String, sheet: String) -> [String] {
        let screenCode = SettingsReachabilityTests.flat(screen)
        let sheetCode = SettingsReachabilityTests.flat(sheet)
        var failures: [String] = []
        for token in ["inbox", "DecisionWriter", "writer", "BiometricGate", "confirm(", "LocalAuthentication"]
        where screenCode.contains(token) {
            failures.append("'\(token)' in the screen — it only hands answers to its closures")
        }
        let shapes: [String] = [allowOfferShape, denyOfferShape]
        for shape in shapes where !screenCode.contains(shape) {
            failures.append("the screen lost '\(shape)'")
        }
        if CloudKitStructureTests.occurrences(of: "Button(action:", in: screenCode) != 2 {
            failures.append("the screen must hold exactly the two answers")
        }
        for shape in ["allow: { Task { await inbox.allow(id) } }", "deny: { Task { await inbox.deny(id) } }"]
        where !sheetCode.contains(shape) {
            failures.append("the sheet lost '\(shape)'")
        }
        for token in ["writer", "confirm(", "DecisionWriter"] where sheetCode.contains(token) {
            failures.append("'\(token)' in the sheet — answers go through the inbox only")
        }
        return failures
    }

    /// Each answer drawn only while the offer holds it (#154).
    static let allowOfferShape: String = "let offer = Self.offer(for: status, biometry: biometry, key: key) "
        + "if let caption = offer.caption { CaptionLine(line: caption) } "
        + "if let kind = offer.answers { if offer.offers(.allow) { Button(action: allow)"
    static let denyOfferShape: String = ".accessibilityHint(Self.answerHint(kind)) } if offer.offers(.deny) { Button(action: deny)"

    @Test func theAnswersGoThroughTheInboxOnly() throws {
        let screen = try Self.code(Self.screenFile)
        let sheet = try Self.code(Self.sheetFile)
        #expect(Self.wiringFailures(screen: screen, sheet: sheet).isEmpty, "\(Self.wiringFailures(screen: screen, sheet: sheet))")
        let mutants: [(String, String, String)] = [
            ("Allow wired to Deny", screen, sheet.replacingOccurrences(of: "allow: { Task { await inbox.allow(id) } }",
                                                                      with: "allow: { Task { await inbox.deny(id) } }")),
            ("the screen writes", screen + "\nlet w: (any DecisionWriter)? = nil", sheet),
            ("answers offered always", screen.replacingOccurrences(of: "if let kind = offer.answers {",
                                                                   with: "if let kind = Optional(BiometryKind.faceID) {"), sheet),
            ("Deny outside the offer", screen.replacingOccurrences(
                of: "            }\n            if offer.offers(.deny) {\n                Button(action: deny) {",
                with: "            }\n        }\n        if true {\n            if offer.offers(.deny) {\n                Button(action: deny) {"),
             sheet),
            ("a third button", screen + "\nlet b = Button(action: {}) { Text(\"x\") }", sheet),
            // #154: each answer drawn only while the offer holds it.
            ("Deny drawn whatever the offer", screen.replacingOccurrences(of: "if offer.offers(.deny) {", with: "if true {"), sheet),
            ("Allow drawn whatever the offer", screen.replacingOccurrences(of: "if offer.offers(.allow) {", with: "if true {"), sheet),
            ("Deny drawn on Allow's offer", screen.replacingOccurrences(of: "if offer.offers(.deny) {", with: "if offer.offers(.allow) {"),
             sheet),
        ]
        for (name, mutantScreen, mutantSheet) in mutants {
            #expect(mutantScreen != screen || mutantSheet != sheet, "canary '\(name)' did not apply")
            #expect(!Self.wiringFailures(screen: mutantScreen, sheet: mutantSheet).isEmpty, "canary '\(name)' was NOT caught")
        }
    }

    static let buttonStyleFile = "\(appDir)/Screen/RequestButtonStyle.swift"

    /// The footnote in the words its state calls for (#154).
    static let footnoteShape: String = "if Self.showsFootnote(status) { Text(Self.footnoteText(status))"

    /// What the review asked of the screen, as its source says it:
    ///
    /// - the input is drawn once, marked (`VisibleWhitespace`) and in
    ///   chunks (one text holding all of a long input draws blank at large
    ///   sizes), in a lazy stack that redraws only when the input or its
    ///   tone changes, never as bare text; VoiceOver still reads it verbatim
    ///   from the card's label;
    /// - it sits in its own scroll box, framed to `inputBoxHeight`, with the
    ///   long-input line under it, and nothing else in the box: the state
    ///   line and the answers follow the card in the screen's stack, so a
    ///   long input never pushes them out of reach;
    /// - a finished card lies flat (no shadow) with its glyph in the
    ///   secondary ink;
    /// - the tool's glyph is drawn over the layout, on the tool name's
    ///   baseline, so a tall glyph never moves the name;
    /// - Sent gets its confirmation glyph, and the change to Sent is
    ///   announced to VoiceOver at high priority;
    /// - both answers carry the biometric's glyph and name (each asks for
    ///   the match), and the unavailable line names this phone's biometric;
    ///   AMENDED (#154): each is titled through `title(_:_:in:)`, so the
    ///   one answer offered again after an unconfirmed save says so;
    /// - the answers' height comes from the theme's touch target;
    /// - AMENDED (the #154 design review): the footnote's words come from
    ///   `footnoteText(_:)`, so after an unconfirmed save it no longer says
    ///   the dialog on the Mac stays open.
    static let compositionShapes = [
        "VStack(alignment: .leading, spacing: theme.rowGap) { promptCard if let note = status.note { CaptionLine(line: note) } "
            + "stateLine answers if Self.showsFootnote(status) {",
        "ScrollView { InputDrawing(input: request.inputPreview, muted: muted) .equatable() "
            + ".onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 } } "
            + ".frame(height: Self.inputBoxHeight(input: inputHeight, screen: screenHeight)) .scrollBounceBehavior(.basedOnSize) "
            + "if Self.inputScrolls(input: inputHeight, screen: screenHeight) { CaptionLine(line: Self.longInput) }",
        // The drawing: a lazy stack (a 32 KB input's marks are thousands of
        // color runs; only the chunks in sight are built), redrawn only when
        // the input or its tone changes.
        "lhs.input == rhs.input && lhs.muted == rhs.muted",
        "let chunks = VisibleWhitespace.chunks(input) LazyVStack(alignment: .leading, spacing: 0) { "
            + "ForEach(chunks.indices, id: \\.self) { index in "
            + "Text(VisibleWhitespace.attributed(chunks[index], mark: theme.inkSecondary)) "
            + ".fixedSize(horizontal: false, vertical: true) .frame(maxWidth: .infinity, alignment: .leading) } } "
            + ".font(theme.bodyFont.monospaced()) .foregroundStyle(muted ? theme.inkSecondary : theme.ink)",
        ".onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }",
        ".themedCard(castsShadow: !muted) .accessibilityElement(children: .ignore) .accessibilityLabel(Self.spoken(request))",
        "let muted = Self.mutesCard(status)",
        ".padding(.leading, glyphColumn + theme.innerGap * 2) "
            + ".overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) { "
            + "Image(systemName: Self.toolSymbol(request.toolName))",
        ".foregroundStyle(muted ? theme.inkSecondary : theme.accent)",
        "let line = status.line(at: now, biometric: biometry.kind) if let symbol = Self.confirmationSymbol(status) {",
        "} else { CaptionLine(line: line) }",
        ".onChange(of: status) { old, new in guard let text = Self.announcement(from: old, to: new, at: now) else { return } "
            + "var spoken = AttributedString(text) spoken.accessibilitySpeechAnnouncementPriority = .high "
            + "AccessibilityNotification.Announcement(spoken).post() }",
        "Label(Self.title(.allow, kind, in: offer), systemImage: kind.symbol)",
        "Label(Self.title(.deny, kind, in: offer), systemImage: kind.symbol) } .buttonStyle(RequestButtonStyle(emphasis: .ink))",
        "guard case .available(let kind) = biometry else { return Offer(answers: nil, caption: answersUnavailable(biometry.kind)) }",
        footnoteShape,
    ]

    static func compositionFailures(screen: String, buttonStyle: String) -> [String] {
        let code = SettingsReachabilityTests.flat(screen)
        var failures = compositionShapes.filter { !code.contains($0) }.map { "the screen lost '\($0)'" }
        if code.contains("Text(verbatim: request.inputPreview)")
            || CloudKitStructureTests.occurrences(of: "VisibleWhitespace.attributed(", in: code) != 1 {
            failures.append("the input must be drawn once, with its whitespace marked")
        }
        if let box = CloudKitStructureTests.body(after: "@ViewBuilder private func inputBox(muted: Bool) -> some View {",
                                                 in: CloudKitStructureTests.codeOnly(screen)) {
            for token in ["Button(", "answers", "stateLine", "status.line", "footnote"] where box.contains(token) {
                failures.append("'\(token)' inside the input's box — it scrolls away with the input")
            }
        } else {
            failures.append("the input's box moved (the lock would be vacuous)")
        }
        let style = SettingsReachabilityTests.flat(buttonStyle)
        if !style.contains(".frame(maxWidth: .infinity, minHeight: theme.minTouchTarget)")
            || style.range(of: #"minHeight:\s*[0-9]"#, options: .regularExpression) != nil {
            failures.append("the answers' height must come from the theme's touch target")
        }
        return failures
    }

    @Test func theScreenKeepsTheReviewedComposition() throws {
        let screen = try Self.code(Self.screenFile)
        let style = try Self.code(Self.buttonStyleFile)
        #expect(Self.compositionFailures(screen: screen, buttonStyle: style).isEmpty,
                "\(Self.compositionFailures(screen: screen, buttonStyle: style))")
        let mutants: [(String, String, String)] = [
            ("the input drawn bare", screen.replacingOccurrences(
                of: "Text(VisibleWhitespace.attributed(chunks[index], mark: theme.inkSecondary))",
                with: "Text(verbatim: request.inputPreview)"), style),
            ("the input as one text", screen.replacingOccurrences(
                of: "let chunks = VisibleWhitespace.chunks(input)",
                with: "let chunks = [VisibleWhitespace.segments(input)]"), style),
            ("every chunk built at once", screen.replacingOccurrences(
                of: "LazyVStack(alignment: .leading, spacing: 0)", with: "VStack(alignment: .leading, spacing: 0)"), style),
            ("the tone not compared", screen.replacingOccurrences(
                of: "lhs.input == rhs.input && lhs.muted == rhs.muted", with: "lhs.input == rhs.input"), style),
            ("redrawn on every pass", screen.replacingOccurrences(
                of: "InputDrawing(input: request.inputPreview, muted: muted)\n                .equatable()\n",
                with: "InputDrawing(input: request.inputPreview, muted: muted)\n"), style),
            ("the box uncapped", screen.replacingOccurrences(
                of: ".frame(height: Self.inputBoxHeight(input: inputHeight, screen: screenHeight))", with: ""), style),
            ("the answers in the box", screen.replacingOccurrences(
                of: "        .scrollBounceBehavior(.basedOnSize)\n",
                with: "        .scrollBounceBehavior(.basedOnSize)\n        answers\n"), style),
            ("the answers before the state", screen.replacingOccurrences(
                of: "                stateLine\n                answers\n", with: "                answers\n                stateLine\n"), style),
            ("the glyph off the name's baseline", screen.replacingOccurrences(
                of: ".overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline))",
                with: ".overlay(alignment: .topLeading)"), style),
            ("the name drawn under the glyph", screen.replacingOccurrences(
                of: "            .padding(.leading, glyphColumn + theme.innerGap * 2)\n", with: ""), style),
            ("a finished card still raised", screen.replacingOccurrences(
                of: ".themedCard(castsShadow: !muted)", with: ".themedCard()"), style),
            ("the confirming line without the biometric", screen.replacingOccurrences(
                of: "let line = status.line(at: now, biometric: biometry.kind)", with: "let line = status.line(at: now)"), style),
            ("Sent as a plain caption", screen.replacingOccurrences(
                of: "if let symbol = Self.confirmationSymbol(status) {", with: "if let symbol = Optional<String>.none {"), style),
            ("Sent not announced", screen.replacingOccurrences(
                of: "AccessibilityNotification.Announcement(spoken).post()", with: ""), style),
            ("the unavailable line unnamed", screen.replacingOccurrences(
                of: "answersUnavailable(biometry.kind)) }", with: "answersUnavailable(nil)) }"), style),
            ("Deny without the biometric's glyph", screen.replacingOccurrences(
                of: "Label(Self.title(.deny, kind, in: offer), systemImage: kind.symbol)",
                with: "Label(Self.title(.deny, kind, in: offer), systemImage: \"xmark\")"), style),
            // #154: an answer sent again says so.
            ("a resend titled as a fresh answer", screen.replacingOccurrences(
                of: "Label(Self.title(.allow, kind, in: offer), systemImage: kind.symbol)",
                with: "Label(Self.allowTitle(kind), systemImage: kind.symbol)"), style),
            // #154 design review: the footnote's words follow the state.
            ("the footnote says the dialog stays open in every state", screen.replacingOccurrences(
                of: "Text(Self.footnoteText(status))", with: "Text(Self.footnote)"), style),
            ("a hard-coded touch target", screen, style.replacingOccurrences(
                of: "minHeight: theme.minTouchTarget", with: "minHeight: 44")),
        ]
        for (name, mutantScreen, mutantStyle) in mutants {
            #expect(mutantScreen != screen || mutantStyle != style, "canary '\(name)' did not apply")
            #expect(!Self.compositionFailures(screen: mutantScreen, buttonStyle: mutantStyle).isEmpty,
                    "canary '\(name)' was NOT caught")
        }
    }

    /// The request sheet hangs off the main screen, before the palette is
    /// applied, so it is drawn in the owner's palette like Settings.
    @Test func theRequestSheetIsDrawnInThePalette() throws {
        let root = SettingsReachabilityTests.flat(try SettingsReachabilityTests.rootCode())
        let sheet = ".sheet(item: $shownRequest) { request in PendingRequestSheet(inbox: inbox, id: request.id) }"
        let sheetRange = try #require(root.range(of: sheet))
        let palette = try #require(root.range(of: SettingsReachabilityTests.palette))
        #expect(sheetRange.upperBound < palette.lowerBound)
        #expect(root.contains("_shownRequest = State(initialValue: opensSettings ? nil : inbox.requests.first)"))
    }
}

/// A decision writer that answers every write with `outcome` and runs
/// `during` as each write begins (on the main actor, where the inbox
/// lives), so a test can read the request while its save is under way.
/// Nothing is written anywhere.
@MainActor
final class PeekingDecisionWriter: DecisionWriter {
    private let outcome: DecisionWriteOutcome
    var during: (() -> Void)?

    init(_ outcome: DecisionWriteOutcome) {
        self.outcome = outcome
    }

    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {
        during?()
        return outcome
    }
}

/// What a test notes down, from any thread.
final class Notes<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func note(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}
