import Foundation
import NapCatWire
@testable import NapCatPhone
import Testing

/// F4 slice S-PAIR-C1.6 (#172): the live pairing's wiring, run where the
/// tests run — a simulator build, which cannot hold the iCloud entitlement.
/// There it gets no approvals database, so its pairing writes nothing and
/// fails dark on the screen's own line; and each opening of the pairing
/// screen gets a new ceremony. A scripted gate and software keys only.
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
        let ceremony = pairing.ceremony()
        await ceremony.scanned(PairingCeremonyTests.payload)
        #expect(gate.requests == [PairingCeremony.reason])
        #expect(ceremony.phase == .failed(.unsent))
        #expect(keys.provisional() == nil && keys.committed() == nil)
    }

    /// Each opening is a new ceremony over the same key: one scan each.
    @Test func eachOpeningIsANewCeremony() async {
        let keys = PhoneKeyringTests.World()
        let pairing = LivePairing.make(keyring: keys.keyring, biometrics: ScriptedBiometricGate())
        let first = pairing.ceremony()
        await first.scanned(FixturePairing.strayCode)
        #expect(first.phase == .refused)
        let second = pairing.ceremony()
        #expect(first !== second)
        #expect(second.phase == .scanning && second.deadline == nil)
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
