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
        .pending(until: now.addingTimeInterval(540), note: .unconfirmed),
        .confirming, .sending(.allow), .sending(.deny), .sent(.allow), .sent(.deny), .answered, .expired, .withdrawn,
    ]

    // MARK: The words

    /// Every line the screen can show is in the caption register: one state
    /// word, an em dash, the cause, no closing period.
    @Test func everyLineIsInTheCaptionRegister() {
        var lines = Self.everyStatus.map { $0.line(at: Self.now) } + Self.everyStatus.compactMap(\.note)
        lines.append(PendingRequestScreen.allowUnavailable)
        for line in lines {
            #expect(ListStateTests.captionRegisterFailures(line.text).isEmpty,
                    "\(ListStateTests.captionRegisterFailures(line.text))")
        }
    }

    @Test func theLinesSayExactlyThis() {
        func text(_ status: RequestStatus) -> String { status.line(at: Self.now).text }
        #expect(text(.pending(until: Self.now.addingTimeInterval(540), note: nil)) == "Pending — expires in 9 min")
        #expect(text(.confirming) == "Confirming — waiting for the biometric match")
        #expect(text(.sending(.allow)) == "Sending — saving Allow to iCloud")
        #expect(text(.sent(.allow)) == "Sent — Allow is saved; your Mac hasn't confirmed it")
        #expect(text(.sent(.deny)) == "Sent — Deny is saved; your Mac hasn't confirmed it")
        #expect(text(.answered) == "Answered — an answer to this prompt was already saved")
        #expect(text(.expired) == "Expired — only your Mac can answer it now")
        #expect(text(.withdrawn) == "Withdrawn — your Mac took this prompt back")
        #expect(PendingRequestScreen.allowTitle(.faceID) == "Allow with Face ID")
        #expect(PendingRequestScreen.allowTitle(.touchID) == "Allow with Touch ID")
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
        #expect(RequestStatus.expired.line(at: Self.now).severity == .info)
        #expect(RequestStatus.withdrawn.line(at: Self.now).severity == .info)
        #expect(RequestStatus.sent(.allow).line(at: Self.now).severity == .nominal)
        #expect(PendingRequestScreen.allowUnavailable.severity == .warning)
    }

    // MARK: The offer

    /// Only an answerable request offers anything; Allow only where a
    /// biometric match is possible; Deny whenever the request is answerable.
    @Test func answersAreOfferedOnlyWhileAnswerable() {
        for status in Self.everyStatus {
            let offer = PendingRequestScreen.offer(for: status, biometry: .available(.faceID))
            if status.isAnswerable {
                #expect(offer == PendingRequestScreen.Offer(allow: .faceID, deny: true), "\(status)")
                #expect(PendingRequestScreen.offer(for: status, biometry: .unavailable)
                        == PendingRequestScreen.Offer(allow: nil, deny: true), "\(status)")
            } else {
                #expect(offer == .none, "\(status)")
            }
        }
        #expect(!RequestStatus.expired.isAnswerable && !RequestStatus.withdrawn.isAnswerable)
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

    /// The glyphs exist in the system's set.
    @Test func theGlyphsAreSystemSymbols() {
        for name in BiometryKind.allCases.map(\.symbol) + [PendingRequestScreen.denySymbol,
                                                            PendingRequestScreen.toolSymbol("Bash"),
                                                            PendingRequestScreen.toolSymbol("Other")] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
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
        case .pending: #expect(status?.isAnswerable == true)
        case .expired: #expect(status == .expired)
        case .withdrawn: #expect(status == .withdrawn)
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

    /// The screen offers answers only through `offer(for:biometry:)`, hands
    /// them to its two closures and never reaches the inbox, the writer or
    /// the gate itself; the sheet routes Allow to `inbox.allow` and Deny to
    /// `inbox.deny`, nothing else.
    static func wiringFailures(screen: String, sheet: String) -> [String] {
        let screenCode = SettingsReachabilityTests.flat(screen)
        let sheetCode = SettingsReachabilityTests.flat(sheet)
        var failures: [String] = []
        for token in ["inbox", "DecisionWriter", "writer", "BiometricGate", "confirm(", "LocalAuthentication"]
        where screenCode.contains(token) {
            failures.append("'\(token)' in the screen — it only hands answers to its closures")
        }
        for shape in ["let offer = Self.offer(for: status, biometry: biometry) if offer.deny {",
                      "if let kind = offer.allow { Button(action: allow)", "Button(action: deny)"]
        where !screenCode.contains(shape) {
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

    @Test func theAnswersGoThroughTheInboxOnly() throws {
        let screen = try Self.code(Self.screenFile)
        let sheet = try Self.code(Self.sheetFile)
        #expect(Self.wiringFailures(screen: screen, sheet: sheet).isEmpty, "\(Self.wiringFailures(screen: screen, sheet: sheet))")
        let mutants: [(String, String, String)] = [
            ("Allow wired to Deny", screen, sheet.replacingOccurrences(of: "allow: { Task { await inbox.allow(id) } }",
                                                                      with: "allow: { Task { await inbox.deny(id) } }")),
            ("the screen writes", screen + "\nlet w: (any DecisionWriter)? = nil", sheet),
            ("answers offered always", screen.replacingOccurrences(of: "if offer.deny {", with: "if true {"), sheet),
            ("Allow without the offer", screen.replacingOccurrences(of: "if let kind = offer.allow {",
                                                                    with: "if let kind = Optional(BiometryKind.faceID) {"), sheet),
            ("a third button", screen + "\nlet b = Button(action: {}) { Text(\"x\") }", sheet),
        ]
        for (name, mutantScreen, mutantSheet) in mutants {
            #expect(mutantScreen != screen || mutantSheet != sheet, "canary '\(name)' did not apply")
            #expect(!Self.wiringFailures(screen: mutantScreen, sheet: mutantSheet).isEmpty, "canary '\(name)' was NOT caught")
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
