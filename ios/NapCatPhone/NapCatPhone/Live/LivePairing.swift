/// The phone's live pairing (F4 slice S-PAIR-C1.6, #172): what Settings'
/// Pair with Mac opens. Design: design/remote-approvals.md, "S-PAIR-C1.6".
///
/// It is made once per launch, by the live inbox's factory
/// (`RequestInbox.make`), over the keyring that inbox signs with, so the key
/// a pairing commits is the key every answer is signed by. A request
/// fixture launch, whose key is software, has none.
///
/// Each opening of the pairing screen gets a new ceremony (one scan each)
/// over the same parts: this keyring, the live biometric gate, the real
/// camera and one writer. Only the owner's tap on Pair with Mac makes one
/// (`makeCeremony`, lint-locked to that one site).
@MainActor
struct LivePairing {
    /// The real camera: a pairing code reaches a live ceremony only through
    /// its scan (`ScannedCode`).
    let camera: any CameraAccess
    private let keyring: PhoneKeyring
    private let biometrics: any BiometricGate
    private let writer: any PairingResponseWriter

    /// THE live wiring site: the one place the CloudKit pairing writer is
    /// built, once per launch, over the live approvals database, which only a
    /// build that can hold the iCloud entitlement gets. Any other build
    /// writes nothing (`UnsentPairingWriter`): its pairing fails dark.
    static func make(keyring: PhoneKeyring, biometrics: any BiometricGate) -> LivePairing {
        let writer: any PairingResponseWriter
        if let database = CloudKitAlertSource.makeLiveApprovalDatabase() {
            writer = CloudKitPairingResponseWriter(database: database)
        } else {
            writer = UnsentPairingWriter()
        }
        return LivePairing(camera: LiveCameraAccess(), keyring: keyring, biometrics: biometrics, writer: writer)
    }

    /// A new ceremony, each time the owner opens the pairing screen.
    func makeCeremony() -> PairingCeremony {
        PairingCeremony(keyring: keyring, biometrics: biometrics, writer: writer)
    }
}
