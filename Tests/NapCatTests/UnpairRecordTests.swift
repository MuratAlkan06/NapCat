// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship.
import AppKit
import CryptoKit
import NapCatWire
import Testing
@testable import NapCat

/// #247: the outstanding-Unpair record — its text, read strictly; what it
/// holds; this run's copy beside the disk's — and its file, played in a
/// scratch folder of the test's own (never the approvals folder).
struct UnpairRecordTests {
    static let item = PairedKeyStore.text(of: PairedPhone(publicKey: Array(P256.Signing.PrivateKey().publicKey.x963Representation),
                                                          pairedAt: Date(timeIntervalSince1970: 1_800_000_000))!)
    static let other = "napcat-paired-v1\nkey:04\n"

    // MARK: - The text

    @Test func theRecordIsTwoFixedLines() {
        let digest = Array(SHA256.hash(data: Data(Self.item.utf8)))
        let named = UnpairRecord.Named(item: digest)
        #expect(UnpairRecord.text(of: named) == "napcat-unpair-v1\nitem:" + ApprovalSigning.lowercaseHex(digest) + "\n")
        #expect(UnpairRecord.named(from: UnpairRecord.text(of: named)) == named)
        #expect(UnpairRecord.text(of: UnpairRecord.Named(item: nil)) == "napcat-unpair-v1\nitem:unknown\n")
        #expect(UnpairRecord.named(from: "napcat-unpair-v1\nitem:unknown\n") == UnpairRecord.Named(item: nil))
        #expect(UnpairRecord.digest(of: .found(Self.item)) == digest)
        #expect(UnpairRecord.digest(of: .failed(status: -25308)) == nil && UnpairRecord.digest(of: .notFound) == nil)
    }

    @Test func anythingButThatFormIsNoRecordsForm() {
        let good = UnpairRecord.text(of: UnpairRecord.Named(item: Array(SHA256.hash(data: Data(Self.item.utf8)))))
        let hex = String(good.dropFirst("napcat-unpair-v1\nitem:".count).dropLast())
        let swaps: [(String, String)] = [
            ("another header", good.replacingOccurrences(of: "napcat-unpair-v1", with: "napcat-unpair-v2")),
            ("no final line feed", String(good.dropLast())),
            ("an extra line", good + "note:x\n"),
            ("CRLF", good.replacingOccurrences(of: "\n", with: "\r\n")),
            ("uppercase hex", good.replacingOccurrences(of: hex, with: hex.uppercased())),
            ("a short digest", good.replacingOccurrences(of: hex, with: String(hex.dropLast(2)))),
            ("another label", good.replacingOccurrences(of: "item:", with: "key:")),
            ("Unknown", "napcat-unpair-v1\nitem:Unknown\n"),
            ("empty", ""),
        ]
        for (name, text) in swaps {
            #expect(text != good, "\(name) did not apply")
            #expect(UnpairRecord.named(from: text) == nil, "\(name) read as a record")
        }
    }

    // MARK: - What it holds

    /// A record names the item; another item is held by none, an empty slot
    /// by none, a refused read by every record. A record that names none,
    /// or that cannot be read, holds every item.
    @Test func whatARecordHolds() {
        let medium = FakeTopicStore()
        let record = UnpairRecord(medium: medium)
        #expect(!record.holds(.found(Self.item)) && !record.holds(.failed(status: -25308)), "no record holds nothing")
        record.record(.found(Self.item))
        #expect(record.holds(.found(Self.item)) && record.holds(.failed(status: -25308)))
        #expect(!record.holds(.found(Self.other)) && !record.holds(.notFound))
        record.record(.failed(status: -25308))
        #expect(record.holds(.found(Self.other)) && !record.holds(.notFound), "it names none: every item")

        for unreadable in [TopicStoreRead.found("junk"), .failed(status: 13)] {
            let disk = FakeTopicStore()
            disk.setReadAnswer(unreadable)
            #expect(UnpairRecord(medium: disk).holds(.found(Self.item)), "\(unreadable)")
        }
    }

    /// This run keeps its record from before the write: a record the disk
    /// refused still holds here (a relaunch reads the disk alone); one the
    /// disk would not remove still holds here too.
    @Test func thisRunsCopyStandsBesideTheDisks() {
        let medium = FakeTopicStore()
        medium.setFailWrites(true)
        let record = UnpairRecord(medium: medium)
        record.record(.found(Self.item))
        #expect(medium.storedValue == nil && record.holds(.found(Self.item)), "the disk refused it; this run keeps it")
        #expect(!UnpairRecord(medium: medium).holds(.found(Self.item)), "what a relaunch reads: the disk alone")

        medium.setFailWrites(false)
        record.record(.found(Self.item))
        medium.setFailDeletes(true)
        record.clear()
        #expect(medium.storedValue != nil && record.holds(.found(Self.item)), "a removal the disk refused ends nothing")
        medium.setFailDeletes(false)
        record.clear()
        #expect(medium.storedValue == nil && !record.holds(.found(Self.item)))
    }

    // MARK: - The file (in a scratch folder)

    /// A scratch home for one test: `<scratch>/approvals/unpair-outstanding`,
    /// its folder not yet made. Every mode is restored before it is removed.
    static func withScratch(_ body: (_ folder: String, _ file: UnpairRecordFile) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("napcat-unpair-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let folder = root.appendingPathComponent("approvals").path
        defer {
            chmod(folder, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        try body(folder, UnpairRecordFile(path: folder + "/" + UnpairRecordFile.fileName))
    }

    @Test func theFileIsWrittenReadAndRemoved() throws {
        try Self.withScratch { folder, file in
            #expect(file.read() == .notFound, "no folder yet: no record")
            #expect(file.delete(), "removing nothing is done")
            #expect(file.write("napcat-unpair-v1\nitem:unknown\n"))
            #expect(file.read() == .found("napcat-unpair-v1\nitem:unknown\n"))
            var info = stat()
            #expect(lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700, "the folder is made, 0700")
            #expect(lstat(file.path!, &info) == 0 && info.st_mode & 0o777 == 0o600, "the record is 0600")
            #expect(file.write("second\n") && file.read() == .found("second\n"), "replaced whole")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder)
            #expect(leftovers == [UnpairRecordFile.fileName], "no temporary file is left: \(leftovers)")
            #expect(file.delete() && file.read() == .notFound)
        }
    }

    /// Fail-closed reads: anything at the path but a small regular file of
    /// UTF-8 text is a failed read (which the record counts as one naming
    /// none), never "no record".
    @Test func anythingButASmallRegularTextFileIsAFailedRead() throws {
        let plants: [(String, (String, String) throws -> Void)] = [
            ("a symlink", { folder, path in
                try "napcat-unpair-v1\nitem:unknown\n".write(toFile: folder + "/target", atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: folder + "/target")
            }),
            ("a folder", { _, path in try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }),
            ("too large", { _, path in
                try String(repeating: "x", count: UnpairRecordFile.maxBytes + 1).write(toFile: path, atomically: true, encoding: .utf8)
            }),
            ("not UTF-8", { _, path in try Data([0xff, 0xfe, 0x0a]).write(to: URL(fileURLWithPath: path)) }),
            ("unreadable", { _, path in
                try "x".write(toFile: path, atomically: true, encoding: .utf8)
                chmod(path, 0o000)
            }),
        ]
        for (name, plant) in plants {
            try Self.withScratch { folder, file in
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
                try plant(folder, file.path!)
                guard case .failed = file.read() else {
                    Issue.record("\(name): \(file.read())")
                    return
                }
                #expect(UnpairRecord(medium: file).holds(.found(Self.item)), "\(name): the record holds the item")
                chmod(file.path!, 0o600)
            }
        }
        #expect(UnpairRecordFile(path: nil).read() == .failed(status: -1), "no home: a failed read")
        #expect(!UnpairRecordFile(path: nil).write("x") && !UnpairRecordFile(path: nil).delete())
    }

    /// A folder that takes no file refuses the write (and the record, kept
    /// for this run, still holds); a folder that is a symlink, or open to
    /// others, takes no write through it as it is.
    @Test func aWriteTheFolderRefusesIsRefused() throws {
        try Self.withScratch { folder, file in
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            chmod(folder, 0o500)
            #expect(file.read() == .notFound && !file.write("x"), "a read-only folder")
            let record = UnpairRecord(medium: file)
            record.record(.found(Self.item))
            #expect(record.holds(.found(Self.item)) && !UnpairRecord(medium: file).holds(.found(Self.item)))
        }
        try Self.withScratch { folder, file in
            let elsewhere = folder + "-elsewhere"
            try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: elsewhere)
            #expect(!file.write("x"), "a symlinked folder")
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
        }
        try Self.withScratch { folder, file in
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            chmod(folder, 0o755)
            #expect(file.write("x"))
            var info = stat()
            #expect(lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700, "tightened to 0700 first")
        }
    }
}
