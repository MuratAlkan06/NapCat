// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import NapCatWire
import Testing

/// F3 stage 1: the NapCatWire constants are the contract between the Mac
/// writer and the iOS receiver. A silent change to any of them would leave
/// the two apps talking past each other (the phone subscribed to a record
/// type nobody writes, or two subscriptions buzzing twice), so every value is
/// byte-pinned here, and the target itself must stay import-free.
struct WireContractTests {
    @Test func theWireConstantsArePinned() {
        #expect(AlertWire.containerIdentifier == "iCloud.com.muratalkan.napcat")
        #expect(AlertWire.recordType == "Alert")
        #expect(AlertWire.subscriptionID == "napcat-alert-created-v1")
    }

    /// The record schema is EXACTLY these three fields, in this order — a
    /// fourth case would widen what an alert record can carry.
    @Test func theFieldSetIsExactlyBodyLaneFiredAt() {
        #expect(AlertWire.Field.allCases.map(\.rawValue) == ["body", "lane", "firedAt"])
    }

    @Test func theLaneValuesArePinned() {
        #expect(AlertWire.Lane.allCases.map(\.rawValue) == ["lid", "session"])
    }

    /// Constants only: no import statement at all (so it builds for iOS and
    /// cannot reach I/O), and no other source file in the target.
    @Test func theWireTargetIsImportFreeConstants() throws {
        let dir = LidGuardStructureTests.repoRoot().appendingPathComponent("Sources/NapCatWire")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files == ["AlertWire.swift"], "NapCatWire holds one constants file, found \(files)")
        let code = LidGuardStructureTests.codeOnly(
            try String(contentsOf: dir.appendingPathComponent("AlertWire.swift"), encoding: .utf8))
        for line in code.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(!trimmed.hasPrefix("import ") && !trimmed.hasPrefix("@_exported"),
                    "NapCatWire must stay import-free: \(trimmed)")
        }
        for token in ["func ", "var ", "class ", "Process", "URLSession", "FileManager", "UserDefaults"] {
            #expect(!code.contains(token), "'\(token)' in NapCatWire — it holds constants only")
        }
        #expect(code.contains("public enum AlertWire"), "vacuity: the wire enum is the scanned file")
    }
}
