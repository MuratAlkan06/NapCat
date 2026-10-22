import Foundation

/// One parsed marker together with the session id it was read under (the
/// marker FILE NAME). The id is an internal diff key only (Track C finish
/// alert): it never reaches a log line or a message body — message kinds carry
/// Int counts/minutes exclusively.
struct IdentifiedBusyMarker: Equatable, Sendable {
    let sessionID: String
    let marker: BusyMarker
}

/// Reads the companion hook's marker directory. Subprocess-free: plain
/// FileManager calls plus one descriptor-checked read per marker
/// (`open`/`fstat`/`read`). INJECTABLE root (tests point it at a temp dir). Only
/// files whose name matches the session-id regex are ever parsed; anything
/// unparseable, foreign, not a regular file, or larger than
/// `ClaudeBusyConstants.maxMarkerBytes` is ignored (never counted busy).
@MainActor
protocol BusyMarkerStore: AnyObject {
    /// All parseable `v1` markers found (no freshness filtering here — the
    /// policy applies the 12h cap, so freshness stays in one place).
    func markers() -> [BusyMarker]
    /// The same markers as `markers()`, each keyed by its session id (the file
    /// name). Track C diffs these across fs events; ids are internal keys only.
    func identifiedMarkers() -> [IdentifiedBusyMarker]
    /// Whether the marker directory exists at all (absent ⇒ "not installed").
    func markerDirExists() -> Bool
    /// Whether the hook's private log exists (its presence = "the hook has run
    /// at least once while not paused").
    func hookLogExists() -> Bool
    /// Marker-dir modification time as a unix epoch, or nil if unreadable.
    /// The dir mtime bumps on marker create/remove/sweep — the liveness clock.
    func lastActivityEpoch() -> Int?
    /// S7: the `# napcat-hook-version: N` stamp of the INSTALLED hook copy, or
    /// nil when that copy is absent, unreadable, not a regular file, or
    /// carries no well-formed stamp. Reads at most its first KiB.
    func installedHookVersion() -> Int?
}

@MainActor
final class MarkerDirectoryStore: BusyMarkerStore {
    private let root: URL
    /// The installer's stable copy of the hook (S7). This file is the ONLY
    /// Sources file allowed to resolve that path (structure lint).
    private let installedHookURL: URL
    private let fileManager = FileManager.default

    /// `installedHookURL` nil ⇒ the real `~/.claude/hooks/…` copy; tests
    /// inject a temp path.
    init(root: URL = ClaudeBusyConstants.markerDirURL, installedHookURL: URL? = nil) {
        self.root = root
        self.installedHookURL = installedHookURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(ClaudeBusyConstants.installedHookRelativePath)
    }

    func markerDirExists() -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func hookLogExists() -> Bool {
        fileManager.fileExists(atPath: root.appendingPathComponent(ClaudeBusyConstants.logFileName).path)
    }

    func lastActivityEpoch() -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Int(modified.timeIntervalSince1970)
    }

    /// One read path: `markers()` is derived from `identifiedMarkers()`.
    func markers() -> [BusyMarker] {
        identifiedMarkers().map(\.marker)
    }

    /// Sorted by session id so the result is deterministic.
    func identifiedMarkers() -> [IdentifiedBusyMarker] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [IdentifiedBusyMarker] = []
        for name in names.sorted() {
            // Path-traversal / foreign-file guard: only session-id-shaped
            // names are ever opened.
            guard ClaudeBusyConstants.isValidSessionID(name) else { continue }
            let url = root.appendingPathComponent(name)
            guard let contents = cappedContents(of: url),
                  let marker = ClaudeActivityPolicy.parseMarker(contents) else { continue }
            found.append(IdentifiedBusyMarker(sessionID: name, marker: marker))
        }
        return found
    }

    /// S7: the installed hook copy's version stamp — the same descriptor-
    /// checked read as a marker (regular file only, no symlink, never
    /// blocking), bounded to `installedHookReadBytes` leading bytes whatever
    /// the file's size. Never written, never read past that cap.
    func installedHookVersion() -> Int? {
        guard let result = Self.readRegularFilePrefix(path: installedHookURL.path,
                                                    limit: ClaudeBusyConstants.installedHookReadBytes,
                                                    maxSize: nil) else { return nil }
        return Self.parseHookVersionStamp(result.bytes, truncated: result.size > result.bytes.count)
    }

    /// Pure stamp parser over the hook's leading bytes (unit-tested). The
    /// FIRST line starting with `hookVersionStampPrefix` decides: the rest of
    /// that line must be 1–9 ASCII digits, else nil. Only COMPLETE lines
    /// count — when the read stopped short of the file's end (`truncated`),
    /// the last, possibly cut line is dropped, so a stamp cut mid-number can
    /// never parse as a smaller one. Byte-level, so a multi-byte character
    /// cut by the cap cannot break the decode.
    nonisolated static func parseHookVersionStamp(_ bytes: [UInt8], truncated: Bool) -> Int? {
        var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeLast() }
        let prefix = Array(ClaudeBusyConstants.hookVersionStampPrefix.utf8)
        guard let stamp = lines.first(where: { $0.starts(with: prefix) }) else { return nil }
        let digits = stamp.dropFirst(prefix.count)
        guard (1...9).contains(digits.count),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Risk F12 + security review L1 (2026-10-21): a marker is read only if it
    /// is a REGULAR file (the hook writes markers with mktemp + mv; a FIFO,
    /// device, directory or symlink is never one — and a FIFO could block the
    /// read) whose size is within `maxMarkerBytes`. The read is bounded to
    /// `maxMarkerBytes + 1` bytes, so a file that grows after the `fstat` is
    /// still rejected without being read in full.
    private func cappedContents(of url: URL) -> String? {
        let cap = ClaudeBusyConstants.maxMarkerBytes
        guard let result = Self.readRegularFilePrefix(path: url.path, limit: cap + 1, maxSize: cap),
              result.bytes.count <= cap else { return nil }
        return String(bytes: result.bytes, encoding: .utf8)
    }

    /// The ONE descriptor-checked read (markers and the installed hook).
    ///
    /// The checks run on the OPENED DESCRIPTOR, never on the path first: an
    /// attribute check followed by a separate open could be raced by a swap to
    /// a symlink-to-FIFO, blocking the main thread in `open`. So the open
    /// itself refuses a symlink (`O_NOFOLLOW`) and cannot block on a FIFO
    /// (`O_NONBLOCK`; `O_CLOEXEC` keeps the fd out of any child), and `fstat`
    /// of that same descriptor decides regular-file (+ `maxSize`, when given).
    /// At most `limit` leading bytes are read. Returns them with the
    /// `fstat` size, or nil.
    private nonisolated static func readRegularFilePrefix(
        path: String, limit: Int, maxSize: Int?
    ) -> (bytes: [UInt8], size: Int)? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        if let maxSize, info.st_size > off_t(maxSize) { return nil }
        var buffer = [UInt8](repeating: 0, count: limit)
        var total = 0
        while total < buffer.count {
            let got = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress! + total, raw.count - total)
            }
            if got < 0 && errno == EINTR { continue }
            guard got >= 0 else { return nil }
            if got == 0 { break }
            total += got
        }
        return (Array(buffer[..<total]), Int(info.st_size))
    }
}
