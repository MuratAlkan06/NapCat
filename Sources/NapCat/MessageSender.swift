import Foundation

/// One recorded send request (dry-run sender / tests).
struct RecordedMessageSend: Equatable, Sendable {
    let kind: LidGuardMessageKind
    let destination: NtfyDestination
    let firedAt: Date
}

/// How the lid guard hands a message to the outside world.
///
/// BODY IS APP-GENERATED, ENFORCED BY THE API SHAPE: there is exactly one entry
/// point and it takes NO free-text parameter — not even a String. The caller
/// passes a `LidGuardMessageKind` (a closed enum carrying at most an Int count)
/// plus a pre-validated `NtfyDestination`; the body itself is built by
/// `LidGuardPolicy.messageBody` from a fixed template. Nothing from a Claude
/// session, transcript, prompt, or working directory can reach an outgoing
/// message. `LidGuardStructureTests` byte-locks this signature.
protocol MessageSender: AnyObject, Sendable {
    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    )
}

/// Dry-run sender: records what WOULD be sent and never touches the network.
/// Used by the tests (no real ntfy publish is ever made by `make test`). The
/// debug-simulator build is protected more strongly still —
/// `LidGuardPolicy.lidGuardMayBeConstructed` keeps the whole B2 subsystem from
/// being constructed at all in debugBattery mode.
final class RecordingMessageSender: MessageSender, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedMessageSend] = []
    private var stubbedOutcome: MessageSendOutcome

    init(outcome: MessageSendOutcome = .accepted) {
        self.stubbedOutcome = outcome
    }

    var sends: [RecordedMessageSend] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Bodies the dry run would have produced — proves the app-generated
    /// template is what goes out.
    func bodies(clockTime: String) -> [String] {
        sends.map { LidGuardPolicy.messageBody(kind: $0.kind, clockTime: clockTime) }
    }

    func setOutcome(_ outcome: MessageSendOutcome) {
        lock.lock()
        stubbedOutcome = outcome
        lock.unlock()
    }

    func send(
        _ kind: LidGuardMessageKind,
        to destination: NtfyDestination,
        at firedAt: Date,
        completion: @escaping @Sendable (MessageSendOutcome) -> Void
    ) {
        lock.lock()
        recorded.append(RecordedMessageSend(kind: kind, destination: destination, firedAt: firedAt))
        let outcome = stubbedOutcome
        lock.unlock()
        completion(outcome)
    }
}
