import Foundation
import NapCatWire

/// Which fixture pairing a launch shows (`-NapCatPairing`), so a simulator
/// run, a screenshot or a design review can see the pairing screen: its
/// real ceremony over a software key in memory, a fixture writer and a
/// fixture camera. The biometric gate is the real one (the simulator's Face
/// ID). Nothing leaves the phone, and nothing is kept past the launch.
enum FixturePairingState: String, CaseIterable, Sendable {
    /// Ready to scan; the viewfinder is drawn (the simulator has no camera).
    case scan
    /// The camera not asked yet.
    case camera
    /// Camera access off.
    case cameraOff
    /// The fixture code is scanned at launch: the match, then the code to
    /// compare.
    case code
    /// A code that is not NapCat's is scanned at launch: refused.
    case stray
    /// The fixture code is scanned at launch, and a response for it is
    /// saved already: the ceremony fails, loudly.
    case taken
}

/// The fixture launch's pairing: its ceremony, its camera, and what it
/// scans at launch.
@MainActor
struct FixturePairing {
    let ceremony: PairingCeremony
    let camera: any CameraAccess
    /// Fed to the ceremony once, as the launch's scan: the fixture's own
    /// code, built here (only the live scanner builds one outside the
    /// fixtures).
    let scan: ScannedCode?

    /// A fixed nonce: the fixture code is the same on every launch.
    nonisolated static let nonce = Array(0..<UInt8(ApprovalSigning.pairingNonceByteCount))
    nonisolated static let strayCode = "https://example.com/not-a-pairing-code"

    /// The launch's fixture pairing, or nil when none was asked for.
    static func make(options: LaunchOptions) -> FixturePairing? {
        options.pairing.map { pairing($0, biometrics: LocalAuthenticationGate()) }
    }

    static func pairing(_ state: FixturePairingState, biometrics: any BiometricGate) -> FixturePairing {
        let keyring = PhoneKeyring(store: MemorySigningKeyStore(), enclave: SoftwareEnclave(),
                                   enrollment: FixedEnrollment(hash: FixtureRequests.enrolledAtPairing))
        let writer = FixturePairingResponseWriter(outcome: state == .taken ? .alreadyAnswered : .saved)
        let ceremony = PairingCeremony(keyring: keyring, biometrics: biometrics, writer: writer)
        let camera = FixtureCamera(answer: state == .camera ? .notAsked : state == .cameraOff ? .off : .ready)
        let scan: ScannedCode? = switch state {
        case .scan, .camera, .cameraOff: nil
        case .code, .taken: ApprovalSigning.pairingPayload(nonce: nonce).map { ScannedCode(payload: $0) }
        case .stray: ScannedCode(payload: strayCode)
        }
        return FixturePairing(ceremony: ceremony, camera: camera, scan: scan)
    }
}

/// The fixture `PairingResponseWriter`: keeps what it was handed, in
/// memory, and answers as it was told. Touches neither iCloud nor anything
/// else.
actor FixturePairingResponseWriter: PairingResponseWriter {
    private(set) var written: [PairingResponse] = []
    private let outcome: PairingWriteOutcome

    init(outcome: PairingWriteOutcome = .saved) {
        self.outcome = outcome
    }

    func write(_ response: PairingResponse) async -> PairingWriteOutcome {
        written.append(response)
        return outcome
    }
}

/// A camera that says what it was told; asked, it is allowed.
@MainActor
final class FixtureCamera: CameraAccess {
    private var answer: CameraState

    init(answer: CameraState) {
        self.answer = answer
    }

    var isLive: Bool { false }

    func state() -> CameraState { answer }

    func request() async -> CameraState {
        if answer == .notAsked { answer = .ready }
        return answer
    }
}
