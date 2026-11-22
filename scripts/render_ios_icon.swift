#!/usr/bin/env swift
// render_ios_icon.swift — NapCat Phone (iOS) APP-ICON renderer: Night Groom, full bleed.
//
// Run from the repo root:  swift scripts/render_ios_icon.swift --variant <a|b|c> <out.png>
//
// Writes ONE 1024×1024 PNG: the single-size iOS app icon an asset catalog
// takes (the system derives every smaller size from it).
//
// ── Design + provenance (ORIGINAL art — nothing traced from RunCat, Apple or
//    any existing icon) ──────────────────────────────────────────────────────
// The Mac icon's own scene, scripts/render_appicon.swift ("Night Groom", the
// owner's pick on 2026-11-19): the owner's hand-drawn art/groom-source.png
// re-inked with the same mask pipeline and parameters, the same crescent
// moon, the one soft contact shadow, and the same colours and layout, all
// copied from that script rather than re-derived. What changes for iOS:
//   • FULL BLEED. The ground covers the whole canvas, and no squircle or
//     margin is drawn: iOS applies its own corner mask, so the macOS shape
//     would be masked twice.
//   • NO ALPHA. The PNG is 8-bit RGB (colour type 2) with no tRNS chunk:
//     App Store Connect rejects an app icon that has an alpha channel.
//   • A VARIANT picks the framing (a square window onto the Mac icon's
//     1024-unit design space, shown at 1024 px) and the ground tone:
//       a  the Mac composition unchanged, ground extended to the edges
//       b  a tighter crop on the cat (the scene zoomed 1024/760 ≈ 1.35×)
//       c  a's framing on the brand accent blue 2C4896 (NapCat Phone's
//          accent and the site's link blue) instead of the night navy
//
// DETERMINISM: as in render_frames.swift and render_appicon.swift — pure
// integer/float math over a fixed committed source and a self-contained PNG
// encoder (render_site_assets.swift's: fixed-Huffman deflate, per-row PNG
// filters) that writes only IHDR, sRGB, IDAT and IEND: no timestamps, no
// text, no EXIF. Running it twice writes identical bytes.
//
// CHECKS (fail loudly before writing): every pixel must be opaque before the
// alpha is dropped; the encoded bytes must be 1024×1024, 8-bit, colour type 2
// with no tRNS chunk; decoded back with ImageIO the PNG must report no alpha
// and the sRGB colour space and reproduce the exact pixels.

import AppKit  // re-exports Foundation; CoreGraphics/ImageIO decode the groom source and verify output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render_ios_icon: ERROR: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Resolve the repo root from the script's own path (works from any cwd)

let scriptPath = CommandLine.arguments.first ?? "scripts/render_ios_icon.swift"
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var scriptURL = URL(fileURLWithPath: scriptPath, relativeTo: cwd).standardizedFileURL
if !FileManager.default.fileExists(atPath: scriptURL.path) {
    scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
}
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Palette and layout (copied from render_appicon.swift)

struct RGBA { var r, g, b, a: Double }

func hex(_ v: UInt32, _ a: Double = 1) -> RGBA {
    RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
}

let navyColor = hex(0x172447)
let moonColor = hex(0xEFE5C6)
let inkColor = hex(0x111216)
let shadowColor = hex(0x060A18)
/// The brand's accent blue: NapCat Phone's light accent (PixelNapTheme) and
/// the site's --color-accent, the icon navy's hue lifted.
let accentColor = hex(0x2C4896)

let groomN = 640
let catHeight = 590.0
let catBottom = 812.0
let catCenterX = 500.0
let moonCenter = (655.0, 318.0), moonRadius = 138.0
let biteCenter = (598.0, 276.0), biteRadius = 122.0

// MARK: - Variants

/// `window` is the square (x, y, side) of the Mac icon's design space that
/// fills the 1024 px canvas.
struct Variant {
    let id: String
    let ground: RGBA
    let window: (x: Double, y: Double, side: Double)
}

/// b's window is centred on the scene's content box: x 221 (the left ear) to
/// 792 (the moon's edge), y 181 (the moon's tip) to about 845, where the
/// contact shadow fades out. It keeps the whole moon inside the iOS mask's
/// top-right corner.
let variants: [Variant] = [
    Variant(id: "a", ground: navyColor, window: (0, 0, 1024)),
    Variant(id: "b", ground: navyColor, window: (127, 132, 760)),
    Variant(id: "c", ground: accentColor, window: (0, 0, 1024)),
]

let size = 1024

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3, args[0] == "--variant", let variant = variants.first(where: { $0.id == args[1] }) else {
    fail("usage: swift scripts/render_ios_icon.swift --variant <\(variants.map(\.id).joined(separator: "|"))> <out.png>")
}
let outURL = URL(fileURLWithPath: args[2], relativeTo: cwd).standardizedFileURL
guard outURL.pathExtension == "png" else { fail("output must be a .png file: \(outURL.path)") }

// MARK: - PNG encoder (from render_site_assets.swift; RGB only)

let crcTable: [UInt32] = (0..<256).map { index in
    var c = UInt32(index)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

func adler32(_ bytes: [UInt8]) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    var i = 0
    let n = bytes.count
    while i < n {
        let end = min(n, i + 5552) // NMAX: no 32-bit overflow before the modulo
        while i < end { a &+= UInt32(bytes[i]); b &+= a; i += 1 }
        a %= 65521
        b %= 65521
    }
    return (b << 16) | a
}

func bigEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let typeBytes = Array(type.utf8)
    return bigEndian32(UInt32(payload.count)) + typeBytes + payload + bigEndian32(crc32(typeBytes + payload))
}

// Fixed-Huffman deflate (RFC 1951 §3.2.6) with greedy hash-chain LZ77.
// Deterministic by construction: fixed chain limit, fixed tie-breaking.
struct BitSink {
    var out: [UInt8] = []
    var acc: UInt64 = 0
    var count: Int = 0
    mutating func put(_ bits: UInt32, _ n: Int) {
        acc |= UInt64(bits) << UInt64(count)
        count += n
        while count >= 8 {
            out.append(UInt8(truncatingIfNeeded: acc))
            acc >>= 8
            count -= 8
        }
    }
    mutating func finish() {
        if count > 0 { out.append(UInt8(truncatingIfNeeded: acc)) }
        acc = 0
        count = 0
    }
}

func reversedBits(_ code: Int, _ len: Int) -> UInt32 {
    var r = 0, c = code
    for _ in 0..<len { r = (r << 1) | (c & 1); c >>= 1 }
    return UInt32(r)
}

let fixedLitCode: [UInt32] = (0..<288).map { sym in
    switch sym {
    case 0...143: return reversedBits(0x30 + sym, 8)
    case 144...255: return reversedBits(0x190 + sym - 144, 9)
    case 256...279: return reversedBits(sym - 256, 7)
    default: return reversedBits(0xC0 + sym - 280, 8)
    }
}
let fixedLitLen: [Int] = (0..<288).map { sym in
    switch sym {
    case 0...143: return 8
    case 144...255: return 9
    case 256...279: return 7
    default: return 8
    }
}
let lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
let lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
let lenIndex: [Int] = {
    var t = [Int](repeating: 0, count: 259)
    for l in 3...258 { var i = 28; while lenBase[i] > l { i -= 1 }; t[l] = i }
    return t
}()
let distIndex: [Int] = {
    var t = [Int](repeating: 0, count: 32769)
    for d in 1...32768 { var i = 29; while distBase[i] > d { i -= 1 }; t[d] = i }
    return t
}()
let distCode: [UInt32] = (0..<30).map { reversedBits($0, 5) }

func deflateFixed(_ data: [UInt8]) -> [UInt8] {
    let n = data.count
    var bs = BitSink()
    bs.out.reserveCapacity(n / 8 + 64)
    bs.put(1, 1) // BFINAL
    bs.put(1, 2) // BTYPE = 01 fixed Huffman
    let hashSize = 1 << 15, mask = 32767, maxChain = 48
    var head = [Int32](repeating: -1, count: hashSize)
    var prev = [Int32](repeating: -1, count: 32768)
    data.withUnsafeBufferPointer { d in
        @inline(__always) func hash(_ i: Int) -> Int {
            ((Int(d[i]) << 10) ^ (Int(d[i + 1]) << 5) ^ Int(d[i + 2])) & (hashSize - 1)
        }
        @inline(__always) func insert(_ i: Int) {
            let h = hash(i)
            prev[i & mask] = head[h]
            head[h] = Int32(i)
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 2 < n {
                let maxLen = min(258, n - i)
                var cand = Int(head[hash(i)])
                var chain = 0
                while cand >= 0 && i - cand <= 32768 && chain < maxChain {
                    var l = 0
                    while l < maxLen && d[cand + l] == d[i + l] { l += 1 }
                    if l > bestLen {
                        bestLen = l
                        bestDist = i - cand
                        if l == maxLen { break }
                    }
                    cand = Int(prev[cand & mask])
                    chain += 1
                }
                insert(i)
            }
            if bestLen >= 3 {
                let li = lenIndex[bestLen]
                bs.put(fixedLitCode[257 + li], fixedLitLen[257 + li])
                if lenExtra[li] > 0 { bs.put(UInt32(bestLen - lenBase[li]), lenExtra[li]) }
                let di = distIndex[bestDist]
                bs.put(distCode[di], 5)
                if distExtra[di] > 0 { bs.put(UInt32(bestDist - distBase[di]), distExtra[di]) }
                var j = i + 1
                let end = i + bestLen
                while j < end { if j + 2 < n { insert(j) }; j += 1 }
                i = end
            } else {
                let b = Int(d[i])
                bs.put(fixedLitCode[b], fixedLitLen[b])
                i += 1
            }
        }
    }
    bs.put(fixedLitCode[256], fixedLitLen[256]) // end of block
    bs.finish()
    return bs.out
}

/// One scanline through the five PNG filters; the filter with the smallest
/// sum of absolute (signed) residuals wins, ties to the lower filter number.
func filterRow(_ row: ArraySlice<UInt8>, _ above: ArraySlice<UInt8>?, bpp: Int) -> [UInt8] {
    let r = Array(row)
    let up = above.map(Array.init) ?? [UInt8](repeating: 0, count: r.count)
    var best: [UInt8] = []
    var bestScore = Int.max
    for type in 0...4 {
        var out = [UInt8](repeating: 0, count: r.count + 1)
        out[0] = UInt8(type)
        var score = 0
        for i in 0..<r.count {
            let a = i >= bpp ? Int(r[i - bpp]) : 0
            let b = Int(up[i])
            let c = i >= bpp ? Int(up[i - bpp]) : 0
            let predictor: Int
            switch type {
            case 1: predictor = a
            case 2: predictor = b
            case 3: predictor = (a + b) / 2
            case 4:
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                predictor = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
            default: predictor = 0
            }
            let v = UInt8(truncatingIfNeeded: Int(r[i]) - predictor)
            out[i + 1] = v
            score += v < 128 ? Int(v) : 256 - Int(v)
        }
        if score < bestScore { bestScore = score; best = out }
    }
    return best
}

/// 8-bit RGB PNG (colour type 2: no alpha channel). `rgb` is width*height*3
/// bytes, rows top to bottom.
func encodeRGBPNG(width: Int, height: Int, rgb: [UInt8]) -> Data {
    let stride = width * 3
    precondition(rgb.count == height * stride)
    var raw: [UInt8] = []
    raw.reserveCapacity(height * (1 + stride))
    for y in 0..<height {
        let row = rgb[(y * stride)..<((y + 1) * stride)]
        let above = y > 0 ? rgb[((y - 1) * stride)..<(y * stride)] : nil
        raw += filterRow(row, above, bpp: 3)
    }
    // zlib header 0x78 0x01 ((0x78*256+0x01) % 31 == 0), deflate, Adler-32.
    let idat: [UInt8] = [0x78, 0x01] + deflateFixed(raw) + bigEndian32(adler32(raw))
    let ihdr = bigEndian32(UInt32(width)) + bigEndian32(UInt32(height)) + [8, 2, 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += pngChunk("IHDR", ihdr)
    png += pngChunk("sRGB", [0]) // perceptual intent; colours are authored in sRGB
    png += pngChunk("IDAT", idat)
    png += pngChunk("IEND", [])
    return Data(png)
}

// MARK: - The App Store icon checks

/// Byte-level: walk the chunks; IHDR must say 1024×1024, 8-bit, colour type
/// 2 (RGB, no alpha channel), and no tRNS chunk may add transparency.
func checkChunks(_ data: Data) {
    let bytes = [UInt8](data)
    guard bytes.count > 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { fail("not a PNG") }
    func be32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
    var i = 8
    var types: [String] = []
    while i + 8 <= bytes.count {
        let length = be32(i)
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        guard i + 12 + length <= bytes.count else { fail("chunk \(type) overruns the file") }
        if type == "IHDR" {
            guard length == 13, be32(i + 8) == size, be32(i + 12) == size else { fail("IHDR is not \(size)x\(size)") }
            guard bytes[i + 16] == 8, bytes[i + 17] == 2 else {
                fail("IHDR bit depth \(bytes[i + 16]), colour type \(bytes[i + 17]): need 8-bit RGB (type 2, no alpha)")
            }
        }
        types.append(type)
        i += 12 + length
    }
    guard types.first == "IHDR", types.last == "IEND", i == bytes.count else { fail("malformed chunk sequence \(types)") }
    guard !types.contains("tRNS") else { fail("tRNS chunk adds transparency") }
    guard types.contains("sRGB") else { fail("no sRGB chunk") }
}

/// Decoded: ImageIO must see size×size, 8 bits per component, no alpha, the
/// sRGB colour space, and exactly the source pixels.
func verifyDecoded(_ data: Data, _ rgb: [UInt8]) {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("ImageIO could not decode") }
    guard img.width == size, img.height == size else { fail("decoded size \(img.width)x\(img.height)") }
    let opaqueLayouts: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
    guard opaqueLayouts.contains(img.alphaInfo) else {
        fail("decoded image has alpha (alphaInfo \(img.alphaInfo.rawValue))")
    }
    guard img.colorSpace?.name == CGColorSpace.sRGB else {
        fail("decoded colour space is \(String(describing: img.colorSpace?.name)), not sRGB")
    }
    let bytesPerPixel = img.bitsPerPixel / 8
    let firstColour = img.alphaInfo == .noneSkipFirst ? 1 : 0
    guard img.bitsPerComponent == 8, bytesPerPixel >= 3, let decoded = img.dataProvider?.data as Data? else {
        fail("unexpected decoded layout (bpc \(img.bitsPerComponent), bpp \(img.bitsPerPixel))")
    }
    let bpr = img.bytesPerRow
    decoded.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<size {
            for x in 0..<size {
                for c in 0..<3 where p[y * bpr + x * bytesPerPixel + firstColour + c] != rgb[(y * size + x) * 3 + c] {
                    fail("pixel mismatch at (\(x), \(y)) channel \(c)")
                }
            }
        }
    }
}

// MARK: - Canvas (premultiplied Double RGBA, src-over — as in render_appicon.swift)

@inline(__always) func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

struct Canvas {
    let w: Int, h: Int
    var p: [Double]
    init(_ w: Int, _ h: Int, fill: RGBA) {
        self.w = w
        self.h = h
        p = [Double](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            p[i * 4] = fill.r * fill.a; p[i * 4 + 1] = fill.g * fill.a
            p[i * 4 + 2] = fill.b * fill.a; p[i * 4 + 3] = fill.a
        }
    }
    @inline(__always) mutating func blend(_ x: Int, _ y: Int, _ c: RGBA, _ coverage: Double) {
        let a = c.a * coverage
        if a <= 0 { return }
        let i = (y * w + x) * 4
        let inv = 1 - a
        p[i] = c.r * a + p[i] * inv
        p[i + 1] = c.g * a + p[i + 1] * inv
        p[i + 2] = c.b * a + p[i + 2] * inv
        p[i + 3] = a + p[i + 3] * inv
    }
    /// 8-bit RGB; every pixel must be opaque (the alpha is dropped, not
    /// flattened onto anything).
    func rgb8() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let a = clamp01(p[i * 4 + 3])
            guard UInt8(a * 255 + 0.5) == 255 else { fail("pixel \(i % w),\(i / w) is not opaque (alpha \(a))") }
            for c in 0..<3 { out[i * 3 + c] = UInt8(clamp01(p[i * 4 + c] / a) * 255 + 0.5) }
        }
        return out
    }
}

// MARK: - The view: design units (the Mac icon's 1024 space) → output pixels

/// Pixels per design unit, and the design-space origin of pixel (0, 0).
let pxPerUnit = Double(size) / variant.window.side
let origin = (x: variant.window.x, y: variant.window.y)

@inline(__always) func designX(_ px: Int) -> Double { (Double(px) + 0.5) / pxPerUnit + origin.x }
@inline(__always) func designY(_ py: Int) -> Double { (Double(py) + 0.5) / pxPerUnit + origin.y }

/// The pixel range covering a design-space box, padded by `pad` pixels and
/// clipped to the canvas.
func pixelRange(_ bbox: (Double, Double, Double, Double), pad: Int) -> (x: Range<Int>, y: Range<Int>)? {
    let x0 = max(0, Int(((bbox.0 - origin.x) * pxPerUnit).rounded(.down)) - pad)
    let y0 = max(0, Int(((bbox.1 - origin.y) * pxPerUnit).rounded(.down)) - pad)
    let x1 = min(size, Int(((bbox.2 - origin.x) * pxPerUnit).rounded(.up)) + pad)
    let y1 = min(size, Int(((bbox.3 - origin.y) * pxPerUnit).rounded(.up)) + pad)
    return x0 < x1 && y0 < y1 ? (x0..<x1, y0..<y1) : nil
}

// MARK: - SDF primitives (design space; y down; negative inside — from render_appicon.swift)

func sdCircle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
    ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() - r
}

func paintSDF(_ cv: inout Canvas, _ color: RGBA, _ bbox: (Double, Double, Double, Double),
              _ sdf: (Double, Double) -> Double) {
    guard let r = pixelRange(bbox, pad: 2) else { return }
    for py in r.y {
        let y = designY(py)
        for px in r.x {
            let cov = clamp01(0.5 - sdf(designX(px), y) * pxPerUnit)
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

func paintField(_ cv: inout Canvas, _ color: RGBA, _ bbox: (Double, Double, Double, Double),
                _ field: (Double, Double) -> Double) {
    guard let r = pixelRange(bbox, pad: 0) else { return }
    for py in r.y {
        let y = designY(py)
        for px in r.x {
            let cov = clamp01(field(designX(px), y))
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

// MARK: - The re-inked cat (from render_appicon.swift, unchanged)

/// Decode art/groom-source.png to straight RGBA, top row first.
func decodeGroomSource(_ path: String) -> [UInt8] {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("could not load \(path)") }
    guard cg.width == groomN, cg.height == groomN else { fail("groom source must be \(groomN)²") }
    var buf = [UInt8](repeating: 0, count: groomN * groomN * 4)
    guard let ctx = CGContext(data: &buf, width: groomN, height: groomN, bitsPerComponent: 8,
                              bytesPerRow: groomN * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("decode ctx") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: groomN, height: groomN))
    for i in 0..<(groomN * groomN) {
        let a = buf[i * 4 + 3]
        if a > 0 && a < 255 {
            for c in 0..<3 { buf[i * 4 + c] = UInt8(min(255, Int(buf[i * 4 + c]) * 255 / Int(a))) }
        }
    }
    return buf
}

struct GroomInk {
    let sil: [Double]   // blurred silhouette mask (whole cat incl. outline)
    let ink: [Double]   // blurred, thickened ink mask (outline + interior lines)
    let fill: RGBA      // the source's own grey
    let bbox: (Double, Double, Double, Double) // silhouette bbox, source px
}

func gaussianBlur(_ f: [Double], _ n: Int, _ sigma: Double) -> [Double] {
    let r = Int((sigma * 3).rounded(.up))
    var k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    let sum = k.reduce(0, +)
    k = k.map { $0 / sum }
    var tmp = [Double](repeating: 0, count: n * n)
    var out = [Double](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            var acc = 0.0
            for i in -r...r { let xx = x + i; if xx >= 0 && xx < n { acc += k[i + r] * f[y * n + xx] } }
            tmp[y * n + x] = acc
        }
    }
    for y in 0..<n {
        for x in 0..<n {
            var acc = 0.0
            for i in -r...r { let yy = y + i; if yy >= 0 && yy < n { acc += k[i + r] * tmp[yy * n + x] } }
            out[y * n + x] = acc
        }
    }
    return out
}

func buildGroomInk(_ px: [UInt8], dilate: Double, sigma: Double) -> GroomInk {
    let n = groomN
    func idx(_ x: Int, _ y: Int) -> Int { y * n + x }
    func blocked(_ x: Int, _ y: Int) -> Bool { px[idx(x, y) * 4 + 3] > 40 }
    // Exterior = 4-connected flood fill of {alpha ≤ 40} from the corners.
    var outside = [Bool](repeating: false, count: n * n)
    var work: [(Int, Int)] = []
    for (sx, sy) in [(0, 0), (n - 1, 0), (0, n - 1), (n - 1, n - 1)] where !blocked(sx, sy) {
        outside[idx(sx, sy)] = true
        work.append((sx, sy))
    }
    while let (x, y) = work.popLast() {
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= n || ny >= n { continue }
            let ni = idx(nx, ny)
            if outside[ni] || blocked(nx, ny) { continue }
            outside[ni] = true
            work.append((nx, ny))
        }
    }
    var sil = [Double](repeating: 0, count: n * n)
    var inkRaw = [Bool](repeating: false, count: n * n)
    var sumR = 0.0, sumG = 0.0, sumB = 0.0, cnt = 0.0
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<n {
        for x in 0..<n {
            let i = idx(x, y)
            if outside[i] { continue }
            sil[i] = 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            let a = px[i * 4 + 3]
            let luma = 0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])
            if a > 40 && luma < 90 { inkRaw[i] = true }
            if a == 255 && luma > 150 {
                sumR += Double(px[i * 4]); sumG += Double(px[i * 4 + 1]); sumB += Double(px[i * 4 + 2]); cnt += 1
            }
        }
    }
    // Thicken the ink with a disk (re-inking weight), then blur both masks so
    // their iso-contours are clean curves instead of hand-drawn jaggies.
    var kernel: [(Int, Int)] = []
    let rr = Int(dilate.rounded(.up))
    for dy in -rr...rr { for dx in -rr...rr where Double(dx * dx + dy * dy) <= dilate * dilate { kernel.append((dx, dy)) } }
    var ink = [Double](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n where inkRaw[idx(x, y)] {
            for (dx, dy) in kernel {
                let nx = x + dx, ny = y + dy
                if nx >= 0 && ny >= 0 && nx < n && ny < n { ink[idx(nx, ny)] = 1 }
            }
        }
    }
    return GroomInk(sil: gaussianBlur(sil, n, sigma), ink: gaussianBlur(ink, n, sigma),
                    fill: RGBA(r: sumR / cnt / 255, g: sumG / cnt / 255, b: sumB / cnt / 255, a: 1),
                    bbox: (Double(minX), Double(minY), Double(maxX + 1), Double(maxY + 1)))
}

@inline(__always) func bilinear(_ f: [Double], _ u: Double, _ v: Double) -> Double {
    let x = u - 0.5, y = v - 0.5
    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
    let fx = x - Double(x0), fy = y - Double(y0)
    @inline(__always) func at(_ i: Int, _ j: Int) -> Double {
        (i < 0 || j < 0 || i >= groomN || j >= groomN) ? 0 : f[j * groomN + i]
    }
    let a = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
    let b = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
    return a * (1 - fy) + b * fy
}

/// Coverage of the iso-contour {f ≥ t} at source point (u,v); `pxPerSrc` =
/// output pixels per source pixel (for the AA ramp).
@inline(__always) func isoCoverage(_ f: [Double], _ u: Double, _ v: Double, _ t: Double, _ pxPerSrc: Double) -> Double {
    let c = bilinear(f, u, v)
    let h = 0.5
    let gx = (bilinear(f, u + h, v) - bilinear(f, u - h, v)) / (2 * h)
    let gy = (bilinear(f, u, v + h) - bilinear(f, u, v - h)) / (2 * h)
    let g = (gx * gx + gy * gy).squareRoot()
    if g < 1e-6 { return c >= t ? 1 : 0 }
    return clamp01(0.5 - (t - c) / g * pxPerSrc)
}

let groom = buildGroomInk(decodeGroomSource(repoRoot.appendingPathComponent("art/groom-source.png").path),
                          dilate: 2.5, sigma: 1.6)

// MARK: - Night Groom, full bleed (render_appicon.swift's renderVector without the squircle)

func render() -> Canvas {
    var cv = Canvas(size, size, fill: variant.ground)
    let g = groom
    let k = catHeight / (g.bbox.3 - g.bbox.1)
    let tx = catCenterX - k * (g.bbox.0 + g.bbox.2) / 2
    let ty = catBottom - k * g.bbox.3
    let catL = tx + k * g.bbox.0, catR = tx + k * g.bbox.2
    let catT = ty + k * g.bbox.1
    // Pale crescent moon behind the cat's back.
    paintSDF(&cv, moonColor, (moonCenter.0 - moonRadius, moonCenter.1 - moonRadius,
                              moonCenter.0 + moonRadius, moonCenter.1 + moonRadius)) { x, y in
        max(sdCircle(x, y, moonCenter.0, moonCenter.1, moonRadius), -sdCircle(x, y, biteCenter.0, biteCenter.1, biteRadius))
    }
    // ONE soft contact shadow under the cat (the only depth cue).
    let shC = ((catL + catR) / 2 + 10, catBottom - 4), shRX = 0.42 * (catR - catL), shRY = 30.0
    paintField(&cv, shadowColor, (shC.0 - shRX * 1.6, shC.1 - shRY * 2.2, shC.0 + shRX * 1.6, shC.1 + shRY * 2.2)) { x, y in
        let dx = (x - shC.0) / shRX, dy = (y - shC.1) / shRY
        return 0.8 * exp(-2.0 * (dx * dx + dy * dy))
    }
    // The re-inked cat: grey fill (silhouette iso-contour), then ink on top.
    let pxPerSrc = k * pxPerUnit
    guard let r = pixelRange((catL - 30, catT - 30, catR + 30, catBottom + 30), pad: 0) else { return cv }
    for py in r.y {
        let v = (designY(py) - ty) / k
        for px in r.x {
            let u = (designX(px) - tx) / k
            let fc = isoCoverage(g.sil, u, v, 0.5, pxPerSrc)
            if fc > 0 { cv.blend(px, py, g.fill, fc) }
            let ic = isoCoverage(g.ink, u, v, 0.5, pxPerSrc)
            if ic > 0 { cv.blend(px, py, inkColor, ic) }
        }
    }
    return cv
}

let rgb = render().rgb8()
let data = encodeRGBPNG(width: size, height: size, rgb: rgb)
checkChunks(data)
verifyDecoded(data, rgb)
do {
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: outURL)
} catch { fail("write \(outURL.path): \(error)") }
print("render_ios_icon: variant \(variant.id) -> \(outURL.path) (\(data.count) bytes, \(size)x\(size), RGB, no alpha)")
