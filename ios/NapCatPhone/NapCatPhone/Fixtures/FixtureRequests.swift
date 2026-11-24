import Foundation
import NapCatWire

/// Which fixture request a launch shows (`-NapCatRequest`), so a simulator
/// run, a screenshot or a design review can see the request screen in each
/// of its states. Fixture requests are answered by `FixtureDecisionWriter`
/// and signed by a software fixture key: nothing leaves the phone, and no
/// Mac has ever paired that key.
enum FixtureRequestState: String, CaseIterable, Sendable {
    /// Answerable, forwarded a minute ago.
    case pending
    /// Its window closed before it was answered.
    case expired
    /// The Mac took it back.
    case withdrawn
    /// Pending, on a phone with no paired key: no answer is on offer.
    case unpaired
    /// Pending, on a phone whose biometrics changed since it paired.
    case changed
}

/// One synthetic request: a Bash prompt as the Mac's gate forwards one. No
/// path, host or user name appears in it.
enum FixtureRequests {
    static let id = PromptID(high: 0x5eed_0000_0000_0001, low: 0x0000_0000_0000_00f4)!
    static let toolName = "Bash"
    static let inputPreview = #"{"command":"git status --short"}"#
    static let projectLabel = "napcat"

    static func request(createdAt: Date) -> PendingRequest {
        PendingRequest(id: id, toolName: toolName, inputPreview: inputPreview, projectLabel: projectLabel,
                       createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(PendingRequest.timeToLive))!
    }

    /// The fixture key's enrollment hashes: when it paired, and later.
    static let enrolledAtPairing = Data("fixture-enrolled-at-pairing".utf8)
    static let enrolledLater = Data("fixture-enrolled-later".utf8)

    /// The fixture's keys: a software key, committed (none for `unpaired`),
    /// made under a fixed enrollment that has moved on for `changed`. In
    /// memory only.
    @MainActor
    static func keyring(_ state: FixtureRequestState) -> PhoneKeyring {
        let store = MemorySigningKeyStore()
        let enclave = SoftwareEnclave()
        if state != .unpaired, let key = enclave.makeKey() {
            _ = store.write(StoredSigningKey(keyData: key.keyData, enrollment: enrolledAtPairing), to: .committed)
        }
        let enrolledNow = state == .changed ? enrolledLater : enrolledAtPairing
        return PhoneKeyring(store: store, enclave: enclave, enrollment: FixedEnrollment(hash: enrolledNow))
    }

    /// An inbox holding the fixture request in `state` at `now`, answered by
    /// a fixture writer and signed by the fixture key, behind the given
    /// biometric gate.
    @MainActor
    static func inbox(_ state: FixtureRequestState, now: Date, biometrics: any BiometricGate,
                      clock: @escaping () -> Date = Date.init) -> RequestInbox {
        let inbox = RequestInbox(writer: FixtureDecisionWriter(), biometrics: biometrics, keyring: keyring(state), clock: clock)
        switch state {
        case .pending, .unpaired, .changed:
            inbox.receive([request(createdAt: now.addingTimeInterval(-60))])
        case .expired:
            inbox.receive([request(createdAt: now.addingTimeInterval(-PendingRequest.timeToLive - 60))])
        case .withdrawn:
            inbox.receive([request(createdAt: now.addingTimeInterval(-120))])
            inbox.withdraw(id)
        }
        return inbox
    }
}

/// The fixture `DecisionWriter`: keeps what it was handed, in memory, and
/// says it was saved. Touches neither iCloud nor anything else.
actor FixtureDecisionWriter: DecisionWriter {
    private(set) var written: [PhoneDecision] = []

    func write(_ decision: PhoneDecision) async -> DecisionWriteOutcome {
        written.append(decision)
        return .saved
    }
}
