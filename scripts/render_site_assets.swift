#!/usr/bin/env swift
// render_site_assets.swift — the landing page's images (docs/).
//
// Run from the repo root:
//   swift scripts/render_site_assets.swift
//       Rebuilds every derived asset from committed inputs only.
//   swift scripts/render_site_assets.swift --panel-captures <light.png> <dark.png>
//       Also re-imports the two menu-panel captures first (see PANEL below).
//
// Outputs (all in docs/):
//   menubar-idle.png         714×42  the 17 idle frames (Resources/frames/
//                            idle0@2x…idle16@2x) side by side, recoloured
//                            white for a dark menu bar: the sprite sheet the
//                            page steps through with CSS. Gray + alpha.
//   menu-panel-light.png     600×640 the menu panel at 2x on the light and
//   menu-panel-dark.png              dark menu background (PANEL below). RGB.
//   og-image.png             1200×630 social card: the menu bar with the cat,
//                            the dark panel hanging from it, and the app icon.
//   apple-touch-icon.png     180×180 the icon's squircle body, full bleed on
//                            the Night Groom navy (iOS applies its own mask
//                            and shows transparency as black). RGB.
//   icon_16x16.png, icon_32x32.png, icon_128x128.png, icon_256x256.png
//                            byte-for-byte copies of the committed iconset.
//
// DETERMINISM: as in render_frames.swift and render_appicon.swift — pure
// integer/float math over committed inputs and a self-contained PNG encoder
// (fixed-Huffman deflate, per-row PNG filters, no library compressor) that
// writes only IHDR, sRGB, IDAT and IEND: no timestamps, no text, no EXIF.
// Running the script twice leaves `git status` clean. Every PNG is decoded
// back with ImageIO and must reproduce the exact source pixels.
//
// PANEL: docs/menu-panel-*.png are captures of the real menu panel
// (MenuPanelView, 300 pt wide, Details collapsed), rendered OFFSCREEN at 2x —
// an NSHostingView in a borderless window that is never ordered front, drawn
// with CALayer.render(in:) into an sRGB bitmap, once with the aqua and once
// with the darkAqua appearance. They are never screenshots of a running app.
// The state is SIMULATED end to end and reads nothing from the machine:
// DebugPowerSimulator at 80 % on AC power; the charge limit on at 80 % (so
// charging is paused at the limit); Stay Awake off (a simulated `pmset -g`
// read); the unit tests' hermetic Claude detection stubs (hook installed and
// current, no task running); the lid alert and session alerts on, with a
// placeholder topic in a throwaway defaults suite (the collapsed panel never
// shows a topic). The default blue accent is used, and the window reports
// itself key and active in-process so the controls draw in the active style
// of an open menu. A capture must be 600 px wide, 8-bit RGBA, sRGB, with a
// transparent background; this script flattens it onto the menu background
// below, pads it like the menu's own content inset, and re-encodes it, which
// drops every metadata chunk of the capture.

import AppKit  // re-exports Foundation; ImageIO decodes the committed inputs and verifies output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render_site_assets: ERROR: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Resolve the repo root from the script's own path (works from any cwd)

let scriptPath = CommandLine.arguments.first ?? "scripts/render_site_assets.swift"
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var scriptURL = URL(fileURLWithPath: scriptPath, relativeTo: cwd).standardizedFileURL
if !FileManager.default.fileExists(atPath: scriptURL.path) {
    scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
}
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let docs = repoRoot.appendingPathComponent("docs", isDirectory: true)
let framesDir = repoRoot.appendingPathComponent("Resources/frames", isDirectory: true)
let iconsetDir = repoRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)

let args = Array(CommandLine.arguments.dropFirst())
var panelCaptures: (light: URL, dark: URL)?
if args.isEmpty {
    panelCaptures = nil
} else if args.count == 3, args[0] == "--panel-captures" {
    panelCaptures = (URL(fileURLWithPath: args[1], relativeTo: cwd).standardizedFileURL,
                     URL(fileURLWithPath: args[2], relativeTo: cwd).standardizedFileURL)
} else {
    fail("usage: swift scripts/render_site_assets.swift [--panel-captures <light.png> <dark.png>]")
}

// MARK: - PNG encoder (from render_appicon.swift; per-row filters + colour types added)

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

/// PNG colour types this script writes (8 bits per channel).
enum PixelFormat: Int {
    case grayAlpha = 4, rgb = 2, rgba = 6
    var channels: Int {
        switch self {
        case .grayAlpha: return 2
        case .rgb: return 3
        case .rgba: return 4
        }
    }
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

/// `pixels` is width*height*channels bytes, rows top to bottom (straight alpha).
func encodePNG(width: Int, height: Int, format: PixelFormat, pixels: [UInt8]) -> Data {
    let bpp = format.channels
    let stride = width * bpp
    precondition(pixels.count == height * stride)
    var raw: [UInt8] = []
    raw.reserveCapacity(height * (1 + stride))
    for y in 0..<height {
        let row = pixels[(y * stride)..<((y + 1) * stride)]
        let above = y > 0 ? pixels[((y - 1) * stride)..<(y * stride)] : nil
        raw += filterRow(row, above, bpp: bpp)
    }
    // zlib header 0x78 0x01 ((0x78*256+0x01) % 31 == 0), deflate, Adler-32.
    let idat: [UInt8] = [0x78, 0x01] + deflateFixed(raw) + bigEndian32(adler32(raw))
    let ihdr = bigEndian32(UInt32(width)) + bigEndian32(UInt32(height)) + [8, UInt8(format.rawValue), 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += pngChunk("IHDR", ihdr)
    png += pngChunk("sRGB", [0]) // perceptual intent; colours are authored in sRGB
    png += pngChunk("IDAT", idat)
    png += pngChunk("IEND", [])
    return Data(png)
}

/// Round-trip guard: decode with ImageIO and require the exact source bytes.
func verifyPNG(_ data: Data, _ w: Int, _ h: Int, _ format: PixelFormat, _ pixels: [UInt8], _ label: String) {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("\(label): ImageIO could not decode") }
    guard img.width == w, img.height == h else { fail("\(label): decoded size \(img.width)x\(img.height)") }
    let channels = format.channels
    let bytesPerPixel = img.bitsPerPixel / 8
    guard img.bitsPerComponent == 8, bytesPerPixel >= channels,
          let decoded = img.dataProvider?.data as Data? else {
        fail("\(label): unexpected decoded layout (bpc \(img.bitsPerComponent), bpp \(img.bitsPerPixel))")
    }
    let bpr = img.bytesPerRow
    decoded.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<channels where p[y * bpr + x * bytesPerPixel + c] != pixels[(y * w + x) * channels + c] {
                    fail("\(label): pixel mismatch at (\(x), \(y)) channel \(c)")
                }
            }
        }
    }
}

// MARK: - Decoding committed inputs (exact bytes; 8-bit straight RGBA only)

struct Image {
    let w: Int, h: Int
    var rgba: [UInt8] // straight alpha, rows top to bottom
}

func decodeRGBA(_ url: URL, requireSRGB: Bool = false) -> Image {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("could not decode \(url.path)") }
    guard img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .last,
          img.bitmapInfo.intersection(.byteOrderMask).rawValue == 0 || img.bitmapInfo.contains(.byteOrder32Big),
          let data = img.dataProvider?.data as Data? else {
        fail("\(url.lastPathComponent): expected 8-bit straight RGBA (bpc \(img.bitsPerComponent), bpp \(img.bitsPerPixel), alpha \(img.alphaInfo.rawValue))")
    }
    if requireSRGB, img.colorSpace?.name != CGColorSpace.sRGB {
        fail("\(url.lastPathComponent): expected sRGB pixels, got \(String(describing: img.colorSpace?.name))")
    }
    var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
    data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<img.height {
            for x in 0..<(img.width * 4) { out[y * img.width * 4 + x] = p[y * img.bytesPerRow + x] }
        }
    }
    return Image(w: img.width, h: img.height, rgba: out)
}

// MARK: - Canvas (premultiplied Double RGBA, src-over — as in render_appicon.swift)

struct RGBA { var r, g, b, a: Double }

func hex(_ v: UInt32, _ a: Double = 1) -> RGBA {
    RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
}

@inline(__always) func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

struct Canvas {
    let w: Int, h: Int
    var p: [Double]
    init(_ w: Int, _ h: Int, fill: RGBA? = nil) {
        self.w = w
        self.h = h
        p = [Double](repeating: 0, count: w * h * 4)
        if let fill {
            for i in 0..<(w * h) {
                p[i * 4] = fill.r * fill.a; p[i * 4 + 1] = fill.g * fill.a
                p[i * 4 + 2] = fill.b * fill.a; p[i * 4 + 3] = fill.a
            }
        }
    }
    init(_ image: Image) {
        self.init(image.w, image.h)
        for i in 0..<(w * h) {
            let a = Double(image.rgba[i * 4 + 3]) / 255
            for c in 0..<3 { p[i * 4 + c] = Double(image.rgba[i * 4 + c]) / 255 * a }
            p[i * 4 + 3] = a
        }
    }
    @inline(__always) mutating func blend(_ x: Int, _ y: Int, _ c: RGBA, _ coverage: Double) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let a = c.a * coverage
        if a <= 0 { return }
        let i = (y * w + x) * 4
        let inv = 1 - a
        p[i] = c.r * a + p[i] * inv
        p[i + 1] = c.g * a + p[i + 1] * inv
        p[i + 2] = c.b * a + p[i + 2] * inv
        p[i + 3] = a + p[i + 3] * inv
    }
    /// Src-over of a premultiplied canvas at an integer offset.
    mutating func draw(_ top: Canvas, x ox: Int, y oy: Int, opacity: Double = 1) {
        for y in 0..<top.h {
            let ty = y + oy
            if ty < 0 || ty >= h { continue }
            for x in 0..<top.w {
                let tx = x + ox
                if tx < 0 || tx >= w { continue }
                let s = (y * top.w + x) * 4
                let a = top.p[s + 3] * opacity
                if a <= 0 { continue }
                let d = (ty * w + tx) * 4
                let inv = 1 - a
                p[d] = top.p[s] * opacity + p[d] * inv
                p[d + 1] = top.p[s + 1] * opacity + p[d + 1] * inv
                p[d + 2] = top.p[s + 2] * opacity + p[d + 2] * inv
                p[d + 3] = a + p[d + 3] * inv
            }
        }
    }
    /// Area-average resample of the source rect (sx, sy, sw, sh) to ow×oh
    /// (fractional edge weighting, as render_frames.swift's downscaleAlpha).
    func resampled(sx: Double, sy: Double, sw: Double, sh: Double, ow: Int, oh: Int) -> Canvas {
        var out = Canvas(ow, oh)
        for oyi in 0..<oh {
            let y0 = sy + Double(oyi) / Double(oh) * sh, y1 = sy + Double(oyi + 1) / Double(oh) * sh
            for oxi in 0..<ow {
                let x0 = sx + Double(oxi) / Double(ow) * sw, x1 = sx + Double(oxi + 1) / Double(ow) * sw
                var acc = (0.0, 0.0, 0.0, 0.0), area = 0.0
                var yy = Int(y0.rounded(.down))
                while Double(yy) < y1 {
                    let wy = min(Double(yy) + 1, y1) - max(Double(yy), y0)
                    if wy > 0 && yy >= 0 && yy < h {
                        var xx = Int(x0.rounded(.down))
                        while Double(xx) < x1 {
                            let wx = min(Double(xx) + 1, x1) - max(Double(xx), x0)
                            if wx > 0 && xx >= 0 && xx < w {
                                let cover = wx * wy
                                let i = (yy * w + xx) * 4
                                acc.0 += p[i] * cover; acc.1 += p[i + 1] * cover
                                acc.2 += p[i + 2] * cover; acc.3 += p[i + 3] * cover
                            }
                            xx += 1
                        }
                    }
                    if wy > 0 { area += wy * (x1 - x0) }
                    yy += 1
                }
                let o = (oyi * ow + oxi) * 4
                if area > 0 {
                    out.p[o] = acc.0 / area; out.p[o + 1] = acc.1 / area
                    out.p[o + 2] = acc.2 / area; out.p[o + 3] = acc.3 / area
                }
            }
        }
        return out
    }
    /// Straight-alpha 8-bit pixels in the given format (rgb drops alpha and
    /// requires an opaque canvas; grayAlpha keeps the red channel as gray).
    func pixels(_ format: PixelFormat) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * format.channels)
        for i in 0..<(w * h) {
            let a = clamp01(p[i * 4 + 3])
            var c = [0.0, 0.0, 0.0]
            if a > 0 { for k in 0..<3 { c[k] = clamp01(p[i * 4 + k] / a) } }
            let a8 = UInt8(a * 255 + 0.5)
            let c8 = c.map { UInt8($0 * 255 + 0.5) }
            switch format {
            case .rgb:
                if a8 != 255 { fail("pixels(.rgb): canvas is not opaque at pixel \(i)") }
                out[i * 3] = c8[0]; out[i * 3 + 1] = c8[1]; out[i * 3 + 2] = c8[2]
            case .rgba:
                out[i * 4] = a8 == 0 ? 0 : c8[0]; out[i * 4 + 1] = a8 == 0 ? 0 : c8[1]
                out[i * 4 + 2] = a8 == 0 ? 0 : c8[2]; out[i * 4 + 3] = a8
            case .grayAlpha:
                out[i * 2] = a8 == 0 ? 0 : c8[0]; out[i * 2 + 1] = a8
            }
        }
        return out
    }
}

/// Signed distance to a rounded rectangle (negative inside), pixel units.
func sdRoundedRect(_ px: Double, _ py: Double, x: Double, y: Double, w: Double, h: Double, r: Double) -> Double {
    let cx = x + w / 2, cy = y + h / 2
    let qx = abs(px - cx) - (w / 2 - r), qy = abs(py - cy) - (h / 2 - r)
    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
    return outside + min(max(qx, qy), 0) - r
}

func fillRoundedRect(_ cv: inout Canvas, _ color: RGBA, x: Double, y: Double, w: Double, h: Double, r: Double) {
    for py in max(0, Int(y) - 1)..<min(cv.h, Int((y + h).rounded(.up)) + 1) {
        for px in max(0, Int(x) - 1)..<min(cv.w, Int((x + w).rounded(.up)) + 1) {
            let cov = clamp01(0.5 - sdRoundedRect(Double(px) + 0.5, Double(py) + 0.5, x: x, y: y, w: w, h: h, r: r))
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

/// A 1 px ring just inside a rounded rectangle's edge.
func strokeRoundedRect(_ cv: inout Canvas, _ color: RGBA, x: Double, y: Double, w: Double, h: Double, r: Double) {
    for py in max(0, Int(y) - 1)..<min(cv.h, Int((y + h).rounded(.up)) + 1) {
        for px in max(0, Int(x) - 1)..<min(cv.w, Int((x + w).rounded(.up)) + 1) {
            let d = sdRoundedRect(Double(px) + 0.5, Double(py) + 0.5, x: x, y: y, w: w, h: h, r: r)
            let cov = clamp01(0.5 - d) * clamp01(0.5 + d + 1)
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

/// Multiplies a canvas's coverage by a rounded-rectangle mask (corner clip).
func clipRoundedRect(_ cv: inout Canvas, r: Double) {
    for py in 0..<cv.h {
        for px in 0..<cv.w {
            let cov = clamp01(0.5 - sdRoundedRect(Double(px) + 0.5, Double(py) + 0.5,
                                                  x: 0, y: 0, w: Double(cv.w), h: Double(cv.h), r: r))
            if cov >= 1 { continue }
            let i = (py * cv.w + px) * 4
            for c in 0..<4 { cv.p[i + c] *= cov }
        }
    }
}

// MARK: - Palette (the Night Groom icon's own colours, scripts/render_appicon.swift)

let navy = hex(0x172447)        // the icon's squircle
let navyShadow = hex(0x0E1630)  // the icon's 32 px contact-shadow cell
/// The menu's background behind the transparent panel captures (macOS menu
/// material, approximated as an opaque colour).
let menuLight = hex(0xF5F5F7)
let menuDark = hex(0x2A2A2D)
/// Points of menu content inset added above and below the captured panel.
let menuInsetPt = 5

// MARK: - Output

do { try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true) } catch { fail("mkdir \(docs.path): \(error)") }

func write(_ name: String, _ cv: Canvas, _ format: PixelFormat) {
    let px = cv.pixels(format)
    let data = encodePNG(width: cv.w, height: cv.h, format: format, pixels: px)
    verifyPNG(data, cv.w, cv.h, format, px, name)
    let url = docs.appendingPathComponent(name)
    do { try data.write(to: url) } catch { fail("write \(url.path): \(error)") }
    print("wrote docs/\(name) (\(data.count) bytes, \(cv.w)x\(cv.h))")
}

// 1. Panel captures (only with --panel-captures): flatten, pad, re-encode.
if let panelCaptures {
    for (name, url, bg) in [("menu-panel-light.png", panelCaptures.light, menuLight),
                            ("menu-panel-dark.png", panelCaptures.dark, menuDark)] {
        let capture = decodeRGBA(url, requireSRGB: true)
        guard capture.w == 600 else { fail("\(url.lastPathComponent): a capture must be 600 px wide (300 pt at 2x), got \(capture.w)") }
        let inset = menuInsetPt * 2
        var cv = Canvas(capture.w, capture.h + 2 * inset, fill: bg)
        cv.draw(Canvas(capture), x: 0, y: inset)
        write(name, cv, .rgb)
    }
}

// 2. The menu-bar sprite: idle0@2x…idle16@2x side by side, white + alpha.
let idleCount = 17
let cell = 42
var sprite = Canvas(cell * idleCount, cell)
for i in 0..<idleCount {
    let frame = decodeRGBA(framesDir.appendingPathComponent("idle\(i)@2x.png"))
    guard frame.w == cell, frame.h == cell else { fail("idle\(i)@2x.png must be \(cell)x\(cell)") }
    for y in 0..<cell {
        for x in 0..<cell {
            let a = Double(frame.rgba[(y * cell + x) * 4 + 3]) / 255
            let o = (y * sprite.w + i * cell + x) * 4
            sprite.p[o] = a; sprite.p[o + 1] = a; sprite.p[o + 2] = a; sprite.p[o + 3] = a
        }
    }
}
write("menubar-idle.png", sprite, .grayAlpha)

// 3. apple-touch-icon: the 1024 px icon's squircle body (824 px, Apple's
// macOS grid), full bleed on navy, area-averaged to 180 px.
let icon1024 = Canvas(decodeRGBA(iconsetDir.appendingPathComponent("icon_512x512@2x.png")))
guard icon1024.w == 1024, icon1024.h == 1024 else { fail("icon_512x512@2x.png must be 1024 px") }
var touch = Canvas(180, 180, fill: navy)
touch.draw(icon1024.resampled(sx: 100, sy: 100, sw: 824, sh: 824, ow: 180, oh: 180), x: 0, y: 0)
write("apple-touch-icon.png", touch, .rgb)

// 4. Social card, 1200×630: a dark menu bar with the cat item open, the dark
// panel hanging under it, and the app icon on the left.
let panelDarkURL = docs.appendingPathComponent("menu-panel-dark.png")
guard FileManager.default.fileExists(atPath: panelDarkURL.path) else {
    fail("docs/menu-panel-dark.png is missing — run with --panel-captures first (see PANEL in the header)")
}
let panelDark: Canvas = {
    guard let src = CGImageSourceCreateWithURL(panelDarkURL as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          img.bitsPerComponent == 8, let data = img.dataProvider?.data as Data? else { fail("could not decode menu-panel-dark.png") }
    var cv = Canvas(img.width, img.height)
    let bpp = img.bitsPerPixel / 8
    data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<img.height {
            for x in 0..<img.width {
                let s = y * img.bytesPerRow + x * bpp, o = (y * img.width + x) * 4
                for c in 0..<3 { cv.p[o + c] = Double(p[s + c]) / 255 }
                cv.p[o + 3] = 1
            }
        }
    }
    return cv
}()

var og = Canvas(1200, 630, fill: navyShadow)
let barHeight = 48
for y in 0..<barHeight { for x in 0..<og.w { og.blend(x, y, hex(0xFFFFFF), 0.07) } }
// The open cat item: highlight pill + frame 0 of the sprite (white).
let pillW = 60.0, pillH = 40.0, pillRight = 1200.0 - 64
let pillX = pillRight - pillW, pillY = (Double(barHeight) - pillH) / 2
fillRoundedRect(&og, hex(0xFFFFFF, 0.18), x: pillX, y: pillY, w: pillW, h: pillH, r: 10)
var cat0 = Canvas(cell, cell)
for y in 0..<cell { for x in 0..<cell {
    let s = (y * sprite.w + x) * 4, o = (y * cell + x) * 4
    for c in 0..<4 { cat0.p[o + c] = sprite.p[s + c] }
} }
og.draw(cat0, x: Int(pillX + (pillW - Double(cell)) / 2), y: (barHeight - cell) / 2)
// The panel at 0.8×, right edge under the pill, corners clipped, with a soft
// shadow and a hairline edge like a menu window.
let scale = 0.8
let pw = Int((Double(panelDark.w) * scale).rounded()), ph = Int((Double(panelDark.h) * scale).rounded())
var panel = panelDark.resampled(sx: 0, sy: 0, sw: Double(panelDark.w), sh: Double(panelDark.h), ow: pw, oh: ph)
let radius = 20.0
clipRoundedRect(&panel, r: radius)
let panelX = Int(pillRight) - pw, panelY = barHeight + 12
for py in max(0, panelY - 40)..<min(og.h, panelY + ph + 60) {
    for px in max(0, panelX - 50)..<min(og.w, panelX + pw + 50) {
        let d = sdRoundedRect(Double(px) + 0.5, Double(py) + 0.5 - 10, x: Double(panelX), y: Double(panelY),
                              w: Double(pw), h: Double(ph), r: radius)
        if d > 0 { og.blend(px, py, hex(0x000000), 0.45 * exp(-(d / 18) * (d / 18))) }
    }
}
og.draw(panel, x: panelX, y: panelY)
strokeRoundedRect(&og, hex(0xFFFFFF, 0.14), x: Double(panelX), y: Double(panelY), w: Double(pw), h: Double(ph), r: radius)
// The app icon, centred in the space left of the panel and below the bar.
let iconSize = 288
let iconCanvas = icon1024.resampled(sx: 0, sy: 0, sw: 1024, sh: 1024, ow: iconSize, oh: iconSize)
let iconX = (panelX - iconSize) / 2
let iconY = barHeight + (og.h - barHeight - iconSize) / 2
og.draw(iconCanvas, x: iconX, y: iconY)
write("og-image.png", og, .rgb)

// 5. Byte-for-byte copies of the committed iconset for the page's icons.
for name in ["icon_16x16.png", "icon_32x32.png", "icon_128x128.png", "icon_256x256.png"] {
    let src = iconsetDir.appendingPathComponent(name), dst = docs.appendingPathComponent(name)
    guard let data = FileManager.default.contents(atPath: src.path) else { fail("missing \(src.path)") }
    do { try data.write(to: dst) } catch { fail("write \(dst.path): \(error)") }
    print("copied docs/\(name) (\(data.count) bytes)")
}

print("render_site_assets: done -> \(docs.path)")
