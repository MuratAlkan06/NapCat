import NapCatWire
import Testing

/// The receiver links the repository's wire contract — the one source of
/// truth both apps import — and nothing else from the Mac package.
@Suite struct WireLinkTests {
    @Test func theLanesAreTheWireContractsTwo() {
        #expect(AlertWire.Lane.allCases.map(\.rawValue) == ["lid", "session"])
    }

    @Test func aRecordCarriesExactlyBodyLaneAndFiredAt() {
        #expect(AlertWire.Field.allCases.map(\.rawValue) == ["body", "lane", "firedAt"])
    }
}
