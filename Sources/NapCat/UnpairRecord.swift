import CryptoKit
import Darwin
import Foundation
import NapCatSeam
import NapCatWire

// #247 (Refs #240, #161): the record of an OUTSTANDING Unpair — the owner
// asked Unpair to remove the paired iPhone's key, and the removal has not
// gone through. Design: design/remote-approvals.md, "Slice S-PAIR".
//
// The slot (`PairedKeyStore`) reads it at every read, the decision
// verifier's among them: while it stands, the item it names counts as no
// pairing, so no decision signed by that key verifies — during this run and
// after a relaunch.
//
// FAIL-CLOSED. The record names the stored item by the SHA-256 of its text
// (the item holds a public key, so its digest is no secret), or names none
// when the keychain refused the read as Unpair ran. A record that cannot be
// read, or reads in any other form, names none. A record that names none
// holds whatever the slot holds. It is written BEFORE the keychain is asked
// to delete the key, and removed only once a deletion went through, a new
// key was written over the item, or Try Again found the item gone. This run
// keeps it in memory as well, from before the write: a record the disk
// refused still holds until NapCat quits.
//
// Where it lives: one small file in the approvals folder, beside the seam's
// socket (`UnpairRecordFile.fileName`), read as a regular file only and never
// through a symlink, replaced by rename and never written through. A missing
// folder or file is no record; any other failure to read it is a record that
// names none.
// UNPRIVILEGED — no sudo, no subprocess.

/// The outstanding-Unpair record: on disk (`medium`, a text item) and, for
/// this run, in memory as well. Every member may be called from any thread.
final class UnpairRecord: @unchecked Sendable {
    /// The app's record: the file in the approvals folder. Referenced by the
    /// app wiring only.
    static let approvalsFolder = UnpairRecord(medium: UnpairRecordFile.approvalsFolder)

    /// The record's first line.
    static let header = "napcat-unpair-v1"
    /// The second line's value when the record names no item.
    static let unknownItem = "unknown"

    /// What one record names: the SHA-256 of the stored item's text, or nil
    /// for none (then it holds whatever is stored).
    struct Named: Equatable, Sendable {
        let item: [UInt8]?
    }

    private let medium: any TopicStore
    private let lock = NSLock()
    /// This run's record, set before its write: gone once a removal of the
    /// record went through.
    private var kept: Named?

    init(medium: any TopicStore) {
        self.medium = medium
    }

    /// Whether an outstanding Unpair holds the item the slot read as
    /// `held`: an empty slot is held by none; any other read is held by a
    /// record that names its item, that names none, or that cannot be read.
    /// A refused read is held by every record (its item cannot be told).
    func holds(_ held: TopicStoreRead) -> Bool {
        if case .notFound = held { return false }
        let item = Self.digest(of: held)
        return [locked { kept }, disk()].contains { named in
            guard let named else { return false }
            guard let recorded = named.item, let item else { return true }
            return recorded == item
        }
    }

    /// Unpair, before the deletion: the record names `held`, here first,
    /// then on disk (a refused write leaves this run's copy).
    func record(_ held: TopicStoreRead) {
        let named = Named(item: Self.digest(of: held))
        locked { kept = named }
        _ = medium.write(Self.text(of: named))
    }

    /// After a deletion went through, a key written over the item, or Try
    /// Again finding the item gone: the record goes from disk, and then from
    /// here. A record the disk keeps stands, here too.
    func clear() {
        guard medium.delete() else { return }
        locked { kept = nil }
    }

    /// The record on disk: nil when there is none.
    private func disk() -> Named? {
        switch medium.read() {
        case .notFound: return nil
        case .found(let text): return Self.named(from: text) ?? Named(item: nil)
        case .failed: return Named(item: nil)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - The stored text (pure, read strictly)

    /// The SHA-256 of the stored item's text; nil when there is no text (a
    /// refused read, or no item).
    static func digest(of held: TopicStoreRead) -> [UInt8]? {
        guard case .found(let text) = held else { return nil }
        return Array(SHA256.hash(data: Data(text.utf8)))
    }

    /// Two lines, each ending in a line feed:
    ///
    ///     napcat-unpair-v1
    ///     item:<64 lowercase hex digits, or "unknown">
    static func text(of named: Named) -> String {
        let item = named.item.map(ApprovalSigning.lowercaseHex) ?? unknownItem
        return header + "\n" + "item:" + item + "\n"
    }

    /// What `text` names, or nil for anything but exactly that form.
    static func named(from text: String) -> Named? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 3, lines[0] == header, lines[2].isEmpty, lines[1].hasPrefix("item:") else { return nil }
        let value = String(lines[1].dropFirst("item:".count))
        if value == unknownItem { return Named(item: nil) }
        guard let item = PairedKeyStore.bytes(fromLowercaseHex: value), item.count == SHA256.byteCount else { return nil }
        return Named(item: item)
    }
}

/// The record's file, as a text item: read as a regular file only, through
/// no symlink and no larger than `maxBytes`; written to a fresh file beside
/// it and renamed over it; removed by unlinking it. The folder is made, mode
/// 0700, when missing; a folder that is not a real directory of this user's
/// takes no write.
struct UnpairRecordFile: TopicStore {
    static let fileName = "unpair-outstanding"
    /// The largest record read (a record is under 100 bytes).
    static let maxBytes = 256

    /// The app's file, in the approvals folder of the user's home as the
    /// user database names it (the seam's own rule). Referenced by the app's
    /// record only.
    static let approvalsFolder = UnpairRecordFile(path: SeamPaths.homeDirectory().map {
        $0 + "/" + SeamPaths.directoryRelativePath + "/" + fileName
    })

    /// nil when the home could not be found: then every read fails and
    /// every write and removal is refused (fail-closed).
    let path: String?

    func read() -> TopicStoreRead {
        guard let path else { return .failed(status: -1) }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .notFound : .failed(status: errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(Self.maxBytes) else {
            return .failed(status: -1)
        }
        var buffer = [UInt8](repeating: 0, count: Self.maxBytes + 1)
        var total = 0
        while total < buffer.count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + total, $0.count - total) }
            if got < 0 && errno == EINTR { continue }
            guard got >= 0 else { return .failed(status: errno) }
            if got == 0 { break }
            total += got
        }
        guard total <= Self.maxBytes, let text = String(bytes: buffer[..<total], encoding: .utf8) else { return .failed(status: -1) }
        return .found(text)
    }

    func write(_ text: String) -> Bool {
        guard let path, let slash = path.lastIndex(of: "/"), Self.prepareFolder(String(path[..<slash])) else { return false }
        var template = Array((path + ".XXXXXX").utf8CString)
        let descriptor = mkostemp(&template, O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let wrote = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + written, $0.count - written) }
            if wrote < 0 && errno == EINTR { continue }
            guard wrote > 0 else { break }
            written += wrote
        }
        let synced = written == bytes.count && fsync(descriptor) == 0
        let closed = close(descriptor) == 0
        guard synced, closed, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }

    func delete() -> Bool {
        guard let path else { return false }
        return unlink(path) == 0 || errno == ENOENT
    }

    /// The folder, made mode 0700 when missing (and any missing folder above
    /// it, with the default mode, as the seam makes them); true only for a
    /// real directory of this user's that nobody else can enter.
    static func prepareFolder(_ folder: String) -> Bool {
        guard makeMissingAncestors(of: folder) else { return false }
        if mkdir(folder, 0o700) != 0 && errno != EEXIST { return false }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { return false }
        return info.st_mode & 0o077 == 0 || chmod(folder, 0o700) == 0
    }

    /// Every missing folder above `path`, outermost first, like `mkdir -p`.
    static func makeMissingAncestors(of path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return true }
        let parent = String(path[..<slash])
        guard !parent.isEmpty else { return true }
        var info = stat()
        if stat(parent, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        guard errno == ENOENT, makeMissingAncestors(of: parent) else { return false }
        return mkdir(parent, 0o777) == 0 || errno == EEXIST
    }
}
