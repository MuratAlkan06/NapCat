import CryptoKit
import Foundation
import LocalAuthentication
@testable import NapCatPhone
import Testing

/// N-25 (F4 slice S-PAIR-C1.6, #172): what the one signing line names for
/// a failure. A domain from the closed table and a number, nothing else;
/// any other domain, however it is spelled, reads as `other`. (Its one line,
/// its call sites and its privacy are `SigningKeyStructureTests` lock 7.)
@Suite struct SigningFailureLogTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let error: @Sendable () -> any Error
        let domain: SigningFailureLog.Domain
        let code: Int
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "a cancelled match", error: { LAError(.userCancel) }, domain: .localAuthentication, code: LAError.Code.userCancel.rawValue),
        Row(name: "a lockout", error: { LAError(.biometryLockout) }, domain: .localAuthentication,
            code: LAError.Code.biometryLockout.rawValue),
        Row(name: "a failed match", error: { LAError(.authenticationFailed) }, domain: .localAuthentication,
            code: LAError.Code.authenticationFailed.rawValue),
        Row(name: "an OSStatus", error: { NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)) }, domain: .osStatus,
            code: Int(errSecUserCanceled)),
        Row(name: "CryptoKit wrapping a status", error: { CryptoKitError.underlyingCoreCryptoError(error: errSecAuthFailed) },
            domain: .coreCrypto, code: Int(errSecAuthFailed)),
        Row(name: "another CryptoKit error", error: { CryptoKitError.incorrectKeySize }, domain: .cryptoKit,
            code: (CryptoKitError.incorrectKeySize as NSError).code),
        Row(name: "a domain holding text", error: { NSError(domain: "the owner's private note", code: 7) }, domain: .other, code: 7),
        Row(name: "a domain spelled like a table entry's name", error: { NSError(domain: "other", code: 8) }, domain: .other, code: 8),
        Row(name: "a Swift error", error: { URLError(.timedOut) }, domain: .other, code: URLError.Code.timedOut.rawValue),
    ]

    @Test(arguments: rows)
    func eachFailureReadsAsItsDomainAndCode(_ row: Row) {
        let reading = SigningFailureLog.reading(row.error())
        #expect(reading.domain == row.domain)
        #expect(reading.code == row.code)
    }

    /// The table, exactly: the line can name these and nothing else.
    @Test func theDomainsAreAClosedTable() {
        let names: [String] = SigningFailureLog.Domain.allCases.map(\.rawValue)
        #expect(names == ["com.apple.LocalAuthentication", "NSOSStatusErrorDomain", "CryptoKitError.underlyingCoreCryptoError",
                          "CryptoKitError", "other"])
        #expect(SigningFailureLog.Domain.localAuthentication.rawValue == LAError.errorDomain)
    }

    /// Recording runs on any failure and keeps nothing.
    @Test func recordingAFailureReturns() {
        for row in Self.rows { SigningFailureLog.record(row.error()) }
    }
}
