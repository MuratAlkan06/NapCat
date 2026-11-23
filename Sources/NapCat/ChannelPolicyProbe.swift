import Foundation
import NapCatWire

/// F4 slice S1: the managed-settings channel allowlist probe (the frozen
/// design's preview posture: whether a managed-settings channel allowlist can
/// replace the per-session development flag). Design:
/// design/remote-approvals.md.
///
/// READ-ONLY. It reads the file tier of Claude Code's managed settings
/// (`managed-settings.json` and the `managed-settings.d` drop-ins) and
/// nothing else: it never writes, never runs anything and never reads
/// `~/.claude`. What it cannot see it does not claim: remote settings (from
/// claude.ai or server-managed (remote) settings) and an MDM profile rank above the file
/// tier, and on a Pro, Max or Ultra plan without an organization Claude Code
/// skips these checks entirely, so there the development flag stays needed
/// whatever the files say. It runs only while the Mac toggle is on (slice
/// S2: the toggle's `.probe` effect, lint-locked), and Settings › Claude
/// shows the finding.
enum ChannelPolicyProbe {
    /// Claude Code's system directory for managed settings on macOS.
    static let systemDirectory = "/Library/Application Support/ClaudeCode"
    static let settingsFileName = "managed-settings.json"
    static let dropInDirectoryName = "managed-settings.d"
    /// A larger document is not read (and makes the finding `unreadable`).
    static let maxDocumentBytes = 1_048_576

    static func probe(directory: String = systemDirectory) -> ChannelPolicyFinding {
        guard let documents = documents(in: directory) else { return .unreadable }
        return ChannelPolicy.finding(documents: documents)
    }

    /// The file tier's documents in Claude Code's merge order: the settings
    /// file, then every visible `*.json` drop-in by name. Nil when one that
    /// exists cannot be read (links are followed, as Claude Code does).
    static func documents(in directory: String) -> [String]? {
        let files = FileManager.default
        var documents: [String] = []
        let settings = directory + "/" + settingsFileName
        if files.fileExists(atPath: settings) {
            guard let text = read(settings) else { return nil }
            documents.append(text)
        }
        let dropIns = directory + "/" + dropInDirectoryName
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: dropIns, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, let names = try? files.contentsOfDirectory(atPath: dropIns) else { return nil }
            for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
                guard let text = read(dropIns + "/" + name) else { return nil }
                documents.append(text)
            }
        }
        return documents
    }

    /// One document as text: a regular file of at most `maxDocumentBytes`,
    /// valid UTF-8. The size is checked on the open file BEFORE anything is
    /// read, and the read itself is bounded too (a file that grew since
    /// counts as too large). Opened non-blocking, so a FIFO or a device at
    /// the path is refused at once instead of waiting on it.
    static func read(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maxDocumentBytes else { return nil }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while bytes.count <= maxDocumentBytes {
            let count = Darwin.read(descriptor, &chunk, min(chunk.count, maxDocumentBytes + 1 - bytes.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            bytes += chunk[0..<count]
        }
        guard bytes.count <= maxDocumentBytes else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
