import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// F4 slice S-PAIR-C1.6 (#172): the live pairing's wiring, run where the
/// tests run — a simulator build, which cannot hold the iCloud entitlement.
/// There it gets no approvals database, so its pairing writes nothing and
/// fails dark on the screen's own line; and each opening of the pairing
/// screen gets a new ceremony. A scripted gate and software keys only.
/// Every test that builds the live wiring is gated on `LiveCapability`, so a
/// run on an entitled device never builds a container.
@MainActor
@Suite struct LivePairingTests {
    /// The test host is a simulator build: no approvals database, ever.
    /// (Gated, so a run on an entitled device never builds a container.)
    @Test(.enabled(if: !LiveCapability.isAvailable))
    func thisSimulatorBuildGetsNoApprovalsDatabase() {
        #expect(!LiveCapability.isAvailable)
        #expect(CloudKitAlertSource.makeLiveApprovalDatabase() == nil)
    }

    /// Unentitled, the live pairing's writer writes nothing: a ceremony runs
    /// to its one write, which reads as unsent, and its new key is gone.
    @Test(.enabled(if: !LiveCapability.isAvailable))
    func anUnentitledPairingFailsDark() async {
        let keys = PhoneKeyringTests.World()
        let gate = ScriptedBiometricGate()
        let pairing = LivePairing.make(keyring: keys.keyring, biometrics: gate)
        #expect(pairing.camera.isLive, "the real camera, never a fixture's")
        let ceremony = pairing.makeCeremony()
        await ceremony.scanned(PairingCeremonyTests.code)
        #expect(gate.requests == [PairingCeremony.reason])
        #expect(ceremony.phase == .failed(.unsent))
        #expect(keys.provisional() == nil && keys.committed() == nil)
    }

    /// Each opening is a new ceremony over the same key: one scan each.
    /// (Gated: it builds the live pairing, which an entitled device would
    /// build over a real container.)
    @Test(.enabled(if: !LiveCapability.isAvailable))
    func eachOpeningIsANewCeremony() async {
        let keys = PhoneKeyringTests.World()
        let pairing = LivePairing.make(keyring: keys.keyring, biometrics: ScriptedBiometricGate())
        let first = pairing.makeCeremony()
        await first.scanned(ScannedCode(payload: FixturePairing.strayCode))
        #expect(first.phase == .refused)
        let second = pairing.makeCeremony()
        #expect(first !== second)
        #expect(second.phase == .scanning && second.deadline == nil)
    }

    /// #175: the live pairing names this phone's biometric through the gate
    /// its ceremonies ask, asking for nothing: Touch ID, Face ID, a kind with
    /// none enrolled, or none at all. Settings' footer says that name.
    /// (Gated: it builds the live pairing.)
    @Test(.enabled(if: !LiveCapability.isAvailable))
    func theLivePairingNamesThePhonesBiometric() {
        let keys: PhoneKeyringTests.World = PhoneKeyringTests.World()
        let gate: ScriptedBiometricGate = ScriptedBiometricGate(available: .available(.touchID))
        let pairing: LivePairing = LivePairing.make(keyring: keys.keyring, biometrics: gate)
        #expect(pairing.biometric() == .touchID)
        gate.available = .available(.faceID)
        #expect(pairing.biometric() == .faceID)
        gate.available = .unavailable(.touchID)
        #expect(pairing.biometric() == .touchID, "a biometric with none enrolled is still the one this phone has")
        gate.available = .unavailable(nil)
        #expect(pairing.biometric() == nil)
        #expect(gate.requests.isEmpty, "reading it asks for nothing")
    }

    /// The unsent writer writes nothing and says so.
    @Test func theUnsentWriterReadsAsUnsent() async throws {
        let response = try #require(PairingResponse(recordName: String(repeating: "a", count: 64), wireVersion: ApprovalWire.wireVersion,
                                                    publicKey: Data([0x04] + Array(repeating: UInt8(1), count: 64)),
                                                    confirmation: Data(count: 32), proof: Data(count: 64)))
        #expect(await UnsentPairingWriter().write(response) == .failed)
    }

    /// A launch with a request fixture has no live pairing: its inbox signs
    /// with a software key. (The live inbox's pairing is the launch's own:
    /// `SigningKeyStructureTests` lock 6 pins it to the live keyring.)
    @Test func aRequestFixtureInboxHasNoLivePairing() {
        let inbox = FixtureRequests.inbox(.pending, now: Date(timeIntervalSince1970: 1_800_000_000), biometrics: ScriptedBiometricGate())
        #expect(inbox.pairing == nil)
    }
}
