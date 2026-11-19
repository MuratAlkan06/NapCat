// AppKit, not Foundation: an explicit `import Foundation` next to `import
// Testing` triggers the _Testing_Foundation cross-import overlay, which the
// CLT frameworks dir does not ship (see PLAN.md decision log 2026-07-09).
import AppKit
import Testing

/// App icon + bundle metadata lints against the COMMITTED files (located from
/// this file's path — the SPM test bundle does not embed them). The iconset is
/// produced by scripts/render_appicon.swift (`make appicon`); `make` compiles
/// it into the bundle's AppIcon.icns, which Info.plist names.
struct AppIconTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)  // Tests/NapCatTests/<this file>
            .deletingLastPathComponent() // NapCatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static var iconsetDirectory: URL {
        repoRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
    }

    /// The canonical macOS iconset ladder: five point sizes at @1x and @2x.
    private static let ladder: [(file: String, px: Int)] = [16, 32, 128, 256, 512].flatMap { pt in
        [("icon_\(pt)x\(pt).png", pt), ("icon_\(pt)x\(pt)@2x.png", pt * 2)]
    }

    private static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Exactly the 10 canonical files (no stale extras — iconutil would pack
    /// them; hidden files such as Finder's .DS_Store are ignored), each an
    /// 8-bit RGBA PNG whose IHDR carries the right pixel size.
    @Test func iconsetHoldsExactlyTheCanonicalLadderAtTheRightPixelSizes() throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: Self.iconsetDirectory.path)
        #expect(Self.ladder.count == 10)
        #expect(Set(contents.filter { !$0.hasPrefix(".") }) == Set(Self.ladder.map(\.file)))

        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func be32(_ b: [UInt8], _ at: Int) -> Int {
            Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
        }
        for entry in Self.ladder {
            let bytes = [UInt8](try Data(contentsOf: Self.iconsetDirectory.appendingPathComponent(entry.file)))
            try #require(bytes.count >= 33, "\(entry.file) is too short to be a PNG")
            #expect(Array(bytes[0..<8]) == signature, "\(entry.file): not a PNG")
            // The first chunk must be IHDR: length 13, then width, height,
            // bit depth 8, colour type 6 (RGBA).
            #expect(be32(bytes, 8) == 13 && String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR",
                    "\(entry.file): first chunk is not IHDR")
            #expect(be32(bytes, 16) == entry.px && be32(bytes, 20) == entry.px,
                    "\(entry.file): IHDR says \(be32(bytes, 16))x\(be32(bytes, 20)), expected \(entry.px)x\(entry.px)")
            #expect(bytes[24] == 8 && bytes[25] == 6, "\(entry.file): expected 8-bit RGBA")
        }
    }

    /// Info.plist names the icon `make` builds, carries a copyright line, and
    /// keeps the build version equal to the marketing version (the release
    /// workflow reads only CFBundleShortVersionString; this keeps the two
    /// from drifting apart when it is bumped).
    @Test func infoPlistNamesTheBuiltIconAndMirrorsTheVersion() throws {
        let plist = try Self.infoPlist()
        let iconFile = try #require(plist["CFBundleIconFile"] as? String)
        #expect(iconFile == "AppIcon")
        let copyright = try #require(plist["NSHumanReadableCopyright"] as? String)
        #expect(!copyright.isEmpty)
        let shortVersion = try #require(plist["CFBundleShortVersionString"] as? String)
        let buildVersion = try #require(plist["CFBundleVersion"] as? String)
        #expect(buildVersion == shortVersion,
                "CFBundleVersion '\(buildVersion)' must equal CFBundleShortVersionString '\(shortVersion)' — bump both together")

        // The named icon must actually be produced into the bundle.
        let makefile = try String(contentsOf: Self.repoRoot.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains(
            "iconutil -c icns Resources/AppIcon.iconset -o $(APP)/Contents/Resources/\(iconFile).icns"
        ), "the Makefile must compile the iconset into Contents/Resources/\(iconFile).icns")
    }
}
