import Foundation
import ImageIO
import Testing

/// The app icon's upload rules (#96): ONE 1024×1024 PNG, 8-bit RGB with no
/// alpha channel (App Store Connect rejects an icon that has one), sRGB.
/// The file is full bleed: iOS cuts the rounded shape itself.
/// scripts/render_ios_icon.swift renders the icon (`make iosicon`, variant a)
/// and checks these rules on its own output. These tests hold the committed
/// asset to them.
@Suite struct AppIconTests {
    static let iconSetDir = "ios/NapCatPhone/NapCatPhone/Assets.xcassets/AppIcon.appiconset"
    static let side = 1024

    static var iconSet: URL { CloudKitStructureTests.repoRoot.appendingPathComponent(iconSetDir) }

    /// What is wrong with `data` as the app icon; empty when nothing is.
    /// The chunk walk is the ground truth for "has an alpha channel" (colour
    /// type and tRNS). ImageIO then has to decode it the same way.
    static func iconProblems(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            return ["not a PNG"]
        }
        func be32(_ i: Int) -> Int {
            Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        var problems: [String] = []
        var types: [String] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = be32(offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            guard offset + 12 + length <= bytes.count else { return problems + ["chunk \(type) overruns the file"] }
            if type == "IHDR" && length == 13 {
                let (width, height) = (be32(offset + 8), be32(offset + 12))
                let (depth, colorType) = (bytes[offset + 16], bytes[offset + 17])
                if width != side || height != side { problems.append("size \(width)x\(height), not \(side)x\(side)") }
                if colorType != 2 || depth != 8 {
                    problems.append("colour type \(colorType), depth \(depth): not 8-bit RGB (type 2, no alpha channel)")
                }
            }
            types.append(type)
            offset += 12 + length
        }
        if types.first != "IHDR" || types.last != "IEND" || offset != bytes.count { problems.append("malformed chunks \(types)") }
        if types.contains("tRNS") { problems.append("a tRNS chunk adds transparency") }
        if !types.contains("sRGB") { problems.append("no sRGB chunk") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return problems + ["ImageIO cannot decode it"]
        }
        if image.width != side || image.height != side { problems.append("decodes at \(image.width)x\(image.height)") }
        let opaqueLayouts: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
        if !opaqueLayouts.contains(image.alphaInfo) {
            problems.append("decodes with alpha (alphaInfo \(image.alphaInfo.rawValue))")
        }
        if image.colorSpace?.name != CGColorSpace.sRGB { problems.append("decodes outside sRGB") }
        return problems
    }

    // MARK: Synthetic PNGs, so each rule is seen failing

    static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in body { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return bigEndian(UInt32(payload.count)) + body + bigEndian(crc ^ 0xFFFF_FFFF)
    }

    /// A solid navy PNG with stored (uncompressed) deflate blocks.
    static func png(side: Int, colorType: UInt8, extra: [[UInt8]] = [], sRGB: Bool = true) -> Data {
        let pixel: [UInt8] = colorType == 6 ? [0x17, 0x24, 0x47, 0xFF] : [0x17, 0x24, 0x47]
        let row = [0] + Array([[UInt8]](repeating: pixel, count: side).joined())
        let raw = Array([[UInt8]](repeating: row, count: side).joined())
        var zlib: [UInt8] = [0x78, 0x01]
        var start = 0
        repeat {
            let end = min(raw.count, start + 65535)
            let length = UInt16(end - start)
            zlib += [end == raw.count ? 1 : 0, UInt8(length & 0xFF), UInt8(length >> 8),
                     UInt8(~length & 0xFF), UInt8(~length >> 8)]
            zlib += raw[start..<end]
            start = end
        } while start < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        zlib += bigEndian(b << 16 | a)
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", bigEndian(UInt32(side)) + bigEndian(UInt32(side)) + [8, colorType, 0, 0, 0])
        if sRGB { file += chunk("sRGB", [0]) }
        for extraChunk in extra { file += extraChunk }
        file += chunk("IDAT", zlib) + chunk("IEND", [])
        return Data(file)
    }

    @Test func anOpaque1024RGBSquarePasses() {
        #expect(Self.iconProblems(Self.png(side: 1024, colorType: 2)) == [])
    }

    @Test func eachRuleFails() {
        func problems(_ data: Data) -> String { Self.iconProblems(data).joined(separator: "; ") }
        #expect(problems(Self.png(side: 1024, colorType: 6)).contains("not 8-bit RGB"))
        #expect(problems(Self.png(side: 1024, colorType: 6)).contains("decodes with alpha"))
        #expect(problems(Self.png(side: 512, colorType: 2)).contains("size 512x512"))
        #expect(problems(Self.png(side: 1024, colorType: 2, extra: [Self.chunk("tRNS", [0, 0, 0, 0, 0, 0])]))
            .contains("tRNS"))
        #expect(problems(Self.png(side: 1024, colorType: 2, sRGB: false)).contains("no sRGB chunk"))
        #expect(problems(Data("not an image".utf8)) == "not a PNG")
    }

    /// The one image the committed set files (nil unless exactly one).
    static func filedImage() throws -> [String: Any]? {
        let contents = try JSONSerialization.jsonObject(
            with: Data(contentsOf: iconSet.appendingPathComponent("Contents.json"))) as? [String: Any]
        let filed = (contents?["images"] as? [[String: Any]] ?? []).filter { $0["filename"] != nil }
        return filed.count == 1 ? filed[0] : nil
    }

    /// The committed set holds one 1024 image for the default appearance,
    /// nothing else, and the built app names it as its icon.
    @Test func theCommittedIconSetIsOneUploadableSquare() throws {
        let entry = try #require(try Self.filedImage(), "the icon set must file exactly one image")
        #expect(entry["idiom"] as? String == "universal")
        #expect(entry["platform"] as? String == "ios")
        #expect(entry["size"] as? String == "1024x1024")
        #expect(entry["appearances"] == nil)
        let filename = try #require(entry["filename"] as? String)
        #expect(Self.iconProblems(try Data(contentsOf: Self.iconSet.appendingPathComponent(filename))) == [])
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.iconSet.path).filter { !$0.hasPrefix(".") }
        #expect(Set(files) == ["Contents.json", filename])
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        #expect(primary?["CFBundleIconName"] as? String == "AppIcon")
    }

    /// `make iosicon` regenerates exactly the committed file, from variant a
    /// (the Night Groom composition the owner ruled for).
    @Test func makeIosiconRegeneratesTheCommittedFileFromVariantA() throws {
        let filename = try #require(try Self.filedImage()?["filename"] as? String)
        let makefile = try String(contentsOf: CloudKitStructureTests.repoRoot.appendingPathComponent("Makefile"),
                                  encoding: .utf8)
        #expect(makefile.contains(
            "\niosicon:\n\tswift scripts/render_ios_icon.swift --variant a \(Self.iconSetDir)/\(filename)\n"
        ), "the Makefile's iosicon target must render variant a into \(Self.iconSetDir)/\(filename)")
    }
}
