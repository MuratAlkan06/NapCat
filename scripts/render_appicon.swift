#!/usr/bin/env swift
// render_appicon.swift — NapCat APP-ICON renderer ("Night Groom").
//
// Run from the repo root:  swift scripts/render_appicon.swift Resources/AppIcon.iconset
//                          (or `make appicon`; the argument defaults to that path)
//
// Produces the full 10-file macOS iconset ladder in the given `.iconset`
// directory (icon_16x16 … icon_512x512@2x). The committed PNGs are the
// canonical icon bytes; `make` compiles them into the bundle's AppIcon.icns
// with iconutil at build time (the .icns container is NOT committed — its
// bytes are not stable across iconutil versions).
//
// ── Design + provenance (ORIGINAL art — nothing traced from RunCat, Apple or
//    any existing icon) ──────────────────────────────────────────────────────
// "Night Groom", the owner's pick on 2026-11-19 from three rendered directions
// (UI audit B1). The owner's own hand-drawn art/groom-source.png (the same
// source as the menu bar's sleep frame) is re-inked: its outline and fill
// masks are cleaned (dilate → blur → iso-contour) and re-rendered at icon
// resolution on a night-blue squircle. The crescent moon, the one soft contact
// shadow and the hand-tuned 32 px and 16 px cells are new.
//
// DETERMINISM: output must be byte-identical across runs so regeneration
// keeps `git status` clean. Pure integer/float math over a fixed committed
// source, plus a self-contained PNG encoder (the one from render_frames.swift,
// extended with a fixed-Huffman LZ77 deflate — a stored block caps at 64 KB —
// and an sRGB chunk). No timestamps, no library compressor.
//
// CHECKS (fail loudly before or while writing): every hand-tuned cell must sit
// fully inside the squircle body at its size, and every PNG is decoded back
// with ImageIO and must reproduce the exact source pixels.

import AppKit  // re-exports Foundation; CoreGraphics/ImageIO decode the groom source and verify output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render_appicon: ERROR: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Resolve the repo root from the script's own path (works from any cwd)

let scriptPath = CommandLine.arguments.first ?? "scripts/render_appicon.swift"
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var scriptURL = URL(fileURLWithPath: scriptPath, relativeTo: cwd).standardizedFileURL
if !FileManager.default.fileExists(atPath: scriptURL.path) {
    scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
}
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let args = CommandLine.arguments
guard args.count <= 2 else { fail("usage: swift scripts/render_appicon.swift [<out>.iconset]") }
let outDir = args.count == 2
    ? URL(fileURLWithPath: args[1], isDirectory: true, relativeTo: cwd).standardizedFileURL
    : repoRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
guard outDir.pathExtension == "iconset" else { fail("output directory must end in .iconset (iconutil requires it): \(outDir.path)") }

// MARK: - PNG encoder (from render_frames.swift; deflate + sRGB added)

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

/// 8-bit RGBA PNG (straight alpha). `rgba` is width*height*4 bytes, rows top to bottom.
func encodePNG(width: Int, height: Int, rgba: [UInt8]) -> Data {
    precondition(rgba.count == width * height * 4)
    var raw: [UInt8] = []
    raw.reserveCapacity(height * (1 + width * 4))
    for y in 0..<height {
        raw.append(0) // filter None
        raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
    }
    // zlib header 0x78 0x01 ((0x78*256+0x01) % 31 == 0), deflate, Adler-32.
    let idat: [UInt8] = [0x78, 0x01] + deflateFixed(raw) + bigEndian32(adler32(raw))
    let ihdr = bigEndian32(UInt32(width)) + bigEndian32(UInt32(height)) + [8, 6, 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += pngChunk("IHDR", ihdr)
    png += pngChunk("sRGB", [0]) // perceptual intent; colours are authored in sRGB
    png += pngChunk("IDAT", idat)
    png += pngChunk("IEND", [])
    return Data(png)
}

/// Round-trip guard: decode with ImageIO and require the exact source bytes.
func verifyPNG(_ data: Data, _ w: Int, _ h: Int, _ rgba: [UInt8], _ label: String) {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("\(label): ImageIO could not decode") }
    guard img.width == w, img.height == h else { fail("\(label): decoded size \(img.width)x\(img.height)") }
    guard img.bitsPerPixel == 32, img.alphaInfo == .last,
          let decoded = img.dataProvider?.data as Data? else {
        fail("\(label): unexpected decoded layout (bpp \(img.bitsPerPixel), alpha \(img.alphaInfo.rawValue))")
    }
    let bpr = img.bytesPerRow
    decoded.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for y in 0..<h {
            for x in 0..<(w * 4) where p[y * bpr + x] != rgba[y * w * 4 + x] {
                fail("\(label): pixel mismatch at row \(y) byte \(x)")
            }
        }
    }
}

// MARK: - Colour + canvas (premultiplied Double RGBA, src-over)

struct RGBA { var r, g, b, a: Double }

func hex(_ v: UInt32, _ a: Double = 1) -> RGBA {
    RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: a)
}

@inline(__always) func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

struct Canvas {
    let w: Int, h: Int
    var p: [Double]
    init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
        p = [Double](repeating: 0, count: w * h * 4)
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
    /// Box-filter downsample by an integer factor (premultiplied → correct edges).
    func downsampled(_ f: Int) -> Canvas {
        if f == 1 { return self }
        var out = Canvas(w / f, h / f)
        let norm = 1.0 / Double(f * f)
        for y in 0..<out.h {
            for x in 0..<out.w {
                var acc = (0.0, 0.0, 0.0, 0.0)
                for dy in 0..<f {
                    for dx in 0..<f {
                        let i = ((y * f + dy) * w + (x * f + dx)) * 4
                        acc.0 += p[i]; acc.1 += p[i + 1]; acc.2 += p[i + 2]; acc.3 += p[i + 3]
                    }
                }
                let o = (y * out.w + x) * 4
                out.p[o] = acc.0 * norm; out.p[o + 1] = acc.1 * norm
                out.p[o + 2] = acc.2 * norm; out.p[o + 3] = acc.3 * norm
            }
        }
        return out
    }
    func rgba8() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = p[i * 4 + 3]
            if a <= 0 { continue }
            for c in 0..<3 { out[i * 4 + c] = UInt8(clamp01(p[i * 4 + c] / a) * 255 + 0.5) }
            out[i * 4 + 3] = UInt8(clamp01(a) * 255 + 0.5)
        }
        return out
    }
}

// MARK: - SDF primitives (design space = the 1024 canvas; y down; negative inside)

func sdCircle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
    ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() - r
}

/// Continuous-corner squircle ≈ superellipse n=5 (matches Apple's 824/1024
/// body with ~0.45 corner ratio). Distance ≈ (N−1)/|∇N|.
func sdSquircle(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ a: Double, _ n: Double = 5) -> Double {
    let ux = abs(x - cx) / a, uy = abs(y - cy) / a
    if ux < 1e-9 && uy < 1e-9 { return -a }
    let N = pow(pow(ux, n) + pow(uy, n), 1 / n)
    let gx = pow(ux, n - 1), gy = pow(uy, n - 1)
    let g = (gx * gx + gy * gy).squareRoot() / pow(N, n - 1)
    return (N - 1) * a / g
}

/// Paint an SDF shape. `s` = pixels per design unit; `bbox` (design units)
/// limits the scan.
func paintSDF(_ cv: inout Canvas, _ color: RGBA, _ s: Double,
              _ bbox: (Double, Double, Double, Double)? = nil,
              _ sdf: (Double, Double) -> Double) {
    let b = bbox ?? (0, 0, 1024, 1024)
    let px0 = max(0, Int((b.0 * s).rounded(.down)) - 2), py0 = max(0, Int((b.1 * s).rounded(.down)) - 2)
    let px1 = min(cv.w, Int((b.2 * s).rounded(.up)) + 2), py1 = min(cv.h, Int((b.3 * s).rounded(.up)) + 2)
    if px0 >= px1 || py0 >= py1 { return }
    for py in py0..<py1 {
        let y = (Double(py) + 0.5) / s
        for px in px0..<px1 {
            let x = (Double(px) + 0.5) / s
            let cov = clamp01(0.5 - sdf(x, y) * s)
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

/// Paint a soft alpha field (design-space function → 0…1).
func paintField(_ cv: inout Canvas, _ color: RGBA, _ s: Double,
                _ bbox: (Double, Double, Double, Double), _ field: (Double, Double) -> Double) {
    let px0 = max(0, Int((bbox.0 * s).rounded(.down))), py0 = max(0, Int((bbox.1 * s).rounded(.down)))
    let px1 = min(cv.w, Int((bbox.2 * s).rounded(.up))), py1 = min(cv.h, Int((bbox.3 * s).rounded(.up)))
    if px0 >= px1 || py0 >= py1 { return }
    for py in py0..<py1 {
        let y = (Double(py) + 0.5) / s
        for px in px0..<px1 {
            let cov = clamp01(field((Double(px) + 0.5) / s, y))
            if cov > 0 { cv.blend(px, py, color, cov) }
        }
    }
}

// MARK: - Icon geometry (Apple macOS grid: 824/1024 body, 100 px margin)

/// Squircle half-size in PIXELS. ≥256 is exact (103/206/412). Small sizes are
/// pixel-snapped so straight edges land on pixel boundaries:
///   16 → 14 px body (nominal 12.9; 13 can't centre on an even canvas, 14 keeps
///         legibility), 32 → 26 (25.75), 64 → 52 (51.5), 128 → 104 (103).
func squircleHalfPx(_ size: Int) -> Double {
    switch size {
    case 16: return 7
    case 32: return 13
    case 64: return 26
    case 128: return 52
    default: return Double(size) * 412.0 / 1024.0
    }
}

func paintSquircle(_ cv: inout Canvas, _ size: Int, _ ss: Int, _ color: RGBA) {
    let s = Double(size * ss) / 1024
    let a = squircleHalfPx(size) / (Double(size) / 1024) // design units
    paintSDF(&cv, color, s) { x, y in sdSquircle(x, y, 512, 512, a) }
}

// MARK: - Grid art (the hand-tuned 32 px and 16 px cells)

struct Grid {
    let name: String
    let rows: [String]
    var n: Int { rows.count }
}

/// Validate a grid and that every painted cell sits fully inside the squircle
/// drawn at `size` (cells are size/n px).
func validate(_ g: Grid, size: Int, allowed: Set<Character>) {
    for (r, row) in g.rows.enumerated() {
        guard row.count == g.n else { fail("\(g.name) row \(r): expected \(g.n) chars, got \(row.count)") }
        for ch in row where !allowed.contains(ch) && ch != "." {
            fail("\(g.name) row \(r): illegal char '\(ch)'")
        }
    }
    let cell = Double(size) / Double(g.n)
    let half = squircleHalfPx(size)
    let c = Double(size) / 2
    for (r, row) in g.rows.enumerated() {
        for (col, ch) in row.enumerated() where ch != "." {
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let x = (Double(col) + dx) * cell, y = (Double(r) + dy) * cell
                if sdSquircle(x, y, c, c, half) > 1e-9 {
                    fail("\(g.name): cell (\(col),\(r)) leaves the squircle at \(size)px")
                }
            }
        }
    }
}

func paintGrid(_ cv: inout Canvas, _ g: Grid, _ palette: [Character: RGBA], cellPx: Int) {
    for (r, row) in g.rows.enumerated() {
        for (col, ch) in row.enumerated() {
            guard let color = palette[ch] else { continue }
            for dy in 0..<cellPx {
                for dx in 0..<cellPx { cv.blend(col * cellPx + dx, r * cellPx + dy, color, 1) }
            }
        }
    }
}

// MARK: - Night Groom

let navyColor = hex(0x172447)
let moonColor = hex(0xEFE5C6)
let inkColor = hex(0x111216)
let shadowColor = hex(0x060A18)
let groomN = 640

/// Decode art/groom-source.png to straight RGBA, top row first (as in
/// render_frames.swift — the buffer is already top-down; no flip).
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

var groomCache: GroomInk?
func groom() -> GroomInk {
    if let g = groomCache { return g }
    let g = buildGroomInk(decodeGroomSource(repoRoot.appendingPathComponent("art/groom-source.png").path),
                          dilate: 2.5, sigma: 1.6)
    groomCache = g
    return g
}

// Layout (design units).
let catHeight = 590.0
let catBottom = 812.0
let catCenterX = 500.0
let moonCenter = (655.0, 318.0), moonRadius = 138.0
let biteCenter = (598.0, 276.0), biteRadius = 122.0

func catTransform() -> (k: Double, tx: Double, ty: Double) {
    let b = groom().bbox
    let k = catHeight / (b.3 - b.1)
    let tx = catCenterX - k * (b.0 + b.2) / 2
    let ty = catBottom - k * b.3
    return (k, tx, ty)
}

/// 64 px and up: the vector render (supersampled to 512 px below 512, then
/// box-filtered down).
func renderVector(_ size: Int) -> Canvas {
    let ss = size >= 512 ? 1 : 512 / size
    let S = size * ss
    let s = Double(S) / 1024
    var cv = Canvas(S, S)
    paintSquircle(&cv, size, ss, navyColor)
    let g = groom()
    let (k, tx, ty) = catTransform()
    let catL = tx + k * g.bbox.0, catR = tx + k * g.bbox.2
    let catT = ty + k * g.bbox.1
    // Pale crescent moon behind the cat's back (upper right, partly occluded),
    // kept fully inside the content margin.
    paintSDF(&cv, moonColor, s, (moonCenter.0 - moonRadius, moonCenter.1 - moonRadius, moonCenter.0 + moonRadius, moonCenter.1 + moonRadius)) { x, y in
        max(sdCircle(x, y, moonCenter.0, moonCenter.1, moonRadius), -sdCircle(x, y, biteCenter.0, biteCenter.1, biteRadius))
    }
    // ONE soft contact shadow under the cat (the only depth cue).
    let shC = ((catL + catR) / 2 + 10, catBottom - 4), shRX = 0.42 * (catR - catL), shRY = 30.0
    paintField(&cv, shadowColor, s, (shC.0 - shRX * 1.6, shC.1 - shRY * 2.2, shC.0 + shRX * 1.6, shC.1 + shRY * 2.2)) { x, y in
        let dx = (x - shC.0) / shRX, dy = (y - shC.1) / shRY
        return 0.8 * exp(-2.0 * (dx * dx + dy * dy))
    }
    // The re-inked cat: grey fill (silhouette iso-contour), then ink on top.
    let pxPerSrc = k * s
    let x0 = max(0, Int(((catL - 30) * s).rounded(.down))), x1 = min(S, Int(((catR + 30) * s).rounded(.up)))
    let y0 = max(0, Int(((catT - 30) * s).rounded(.down))), y1 = min(S, Int(((catBottom + 30) * s).rounded(.up)))
    for py in y0..<y1 {
        let v = ((Double(py) + 0.5) / s - ty) / k
        for px in x0..<x1 {
            let u = ((Double(px) + 0.5) / s - tx) / k
            let fc = isoCoverage(g.sil, u, v, 0.5, pxPerSrc)
            if fc > 0 { cv.blend(px, py, g.fill, fc) }
            let ic = isoCoverage(g.ink, u, v, 0.5, pxPerSrc)
            if ic > 0 { cv.blend(px, py, inkColor, ic) }
        }
    }
    return cv.downsampled(ss)
}

// Hand-tuned small cells. . = field, M = moon, m = moon AA, G = grey fill,
// g = grey AA (fill over navy), K = ink, S = contact shadow.
var palette: [Character: RGBA] { [
    "M": moonColor, "m": hex(0x8C8C93), "K": inkColor, "S": hex(0x0E1630),
    "G": groom().fill, "g": hex(0x7E8293),
] }
let cellChars: Set<Character> = ["M", "m", "K", "S", "G", "g"]

// 32 px: the groom pose kept as grey silhouette (ink outline dropped — it
// eats a pixel per side and vanishes against navy); ink only for the closed
// eyes, the raised-paw arm and the front-leg line. Tail = 2 px stroke with a
// 1 px navy gap from the head, hooked right at the top; the crescent is
// redrawn as a clean ")" peeking behind the tail hook; a 1-row contact shadow.
let grid32 = Grid(name: "32 px", rows: [
    "................................", // 0
    "................................", // 1
    "................................", // 2
    "................................", // 3
    ".......................MM.......", // 4
    "........................MM......", // 5
    "...............G.........MM.....", // 6
    ".......G......GG.........MM.....", // 7
    ".......GG.....GGG........MM.....", // 8
    ".......GGG...GGGG.......MM......", // 9
    ".......GGGGGGGGGGG..GGGGM.......", // 10
    ".......GGGGGGGGGGG.GG...........", // 11
    "........GGGGGGGGGG.GG...........", // 12
    "........GGGGGGGGGG.GG...........", // 13
    ".........GGGGGGGGG.GG...........", // 14
    ".........GKKGGKKGG.GG...........", // 15
    ".........GGKKGGGGG.GG...........", // 16
    "..........GGGKKKGGGGG...........", // 17
    "...........GGGGGKKGGGG..........", // 18
    "...........GGGGGGGGGGG..........", // 19
    "...........GGGGKGGGGGG..........", // 20
    "..........GGGGGKGGGGGG..........", // 21
    "..........GGGGGKGGGGGG..........", // 22
    "..........GGGGGKGGKKGG..........", // 23
    "...........GGGG.GGGGG...........", // 24
    "..........SSSSSSSSSSSS..........", // 25
    "................................", // 26
    "................................", // 27
    "................................", // 28
    "................................", // 29
    "................................", // 30
    "................................", // 31
])

// 16 px: ears + head + raised-paw hint + hooked tail + 2-px crescent; eyes are
// single ink pixels (closed-vs-open is not resolvable at 16).
let grid16 = Grid(name: "16 px", rows: [
    "................", // 0
    "................", // 1
    "...........M....", // 2
    "............M...", // 3
    "....G..G....MM..", // 4
    "....GGGGG.GGMM..", // 5
    "...GGGGGG.G.M...", // 6
    "...GKGGKG.G.....", // 7
    "...GGGGGGGG.....", // 8
    "....GKKGGGG.....", // 9
    ".....GGGGGG.....", // 10
    ".....GGKGGG.....", // 11
    ".....GG.GGG.....", // 12
    "....SSSSSSSS....", // 13
    "................", // 14
    "................", // 15
])

func renderIcon(_ size: Int) -> Canvas {
    switch size {
    case 32, 16:
        var cv = Canvas(size, size)
        paintSquircle(&cv, size, 1, navyColor)
        paintGrid(&cv, size == 32 ? grid32 : grid16, palette, cellPx: 1)
        return cv
    default:
        return renderVector(size)
    }
}

// MARK: - Iconset ladder

let ladder: [(file: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let distinctSizes = [16, 32, 64, 128, 256, 512, 1024]

validate(grid32, size: 32, allowed: cellChars)
validate(grid16, size: 16, allowed: cellChars)

do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch { fail("mkdir \(outDir.path): \(error)") }

var renders: [Int: [UInt8]] = [:]
for size in distinctSizes { renders[size] = renderIcon(size).rgba8() }

for entry in ladder {
    let url = outDir.appendingPathComponent(entry.file)
    let rgba = renders[entry.px]!
    let data = encodePNG(width: entry.px, height: entry.px, rgba: rgba)
    verifyPNG(data, entry.px, entry.px, rgba, entry.file)
    do { try data.write(to: url) } catch { fail("write \(url.path): \(error)") }
    print("wrote \(entry.file) (\(data.count) bytes, \(entry.px)x\(entry.px))")
}

// A stale extra file would be compiled into the .icns by iconutil; refuse to
// leave one behind (hidden files such as Finder's .DS_Store are ignored).
let expectedFiles = Set(ladder.map(\.file))
let present = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
let extras = present.filter { !$0.hasPrefix(".") && !expectedFiles.contains($0) }.sorted()
guard extras.isEmpty else { fail("unexpected files in \(outDir.path) — remove them: \(extras.joined(separator: ", "))") }

// Debug aid (DUMP_REF=1): ASCII class map of the vector render at 32/16 — the
// reference used when hand-tuning the small cells (the cells themselves are
// authored, not generated from this). Prints only; writes nothing.
if ProcessInfo.processInfo.environment["DUMP_REF"] == "1" {
    let g = groom()
    let (k, tx, ty) = catTransform()
    for size in [32, 16] {
        print("mask reference @\(size)  (K ink≥45%  G sil≥50%  g sil≥20%  M moon≥50%  m moon≥20%):")
        let n = 8
        for py in 0..<size {
            var line = ""
            for px in 0..<size {
                var sil = 0.0, ink = 0.0, moon = 0.0
                for j in 0..<n {
                    for i in 0..<n {
                        let X = (Double(px) + (Double(i) + 0.5) / Double(n)) * 1024 / Double(size)
                        let Y = (Double(py) + (Double(j) + 0.5) / Double(n)) * 1024 / Double(size)
                        let u = (X - tx) / k, v = (Y - ty) / k
                        if bilinear(g.sil, u, v) >= 0.5 { sil += 1 }
                        if bilinear(g.ink, u, v) >= 0.5 { ink += 1 }
                        if max(sdCircle(X, Y, moonCenter.0, moonCenter.1, moonRadius), -sdCircle(X, Y, biteCenter.0, biteCenter.1, biteRadius)) < 0 { moon += 1 }
                    }
                }
                let t = Double(n * n)
                sil /= t; ink /= t; moon /= t
                line += ink >= 0.45 ? "K" : sil >= 0.5 ? "G" : sil >= 0.2 ? "g" : moon >= 0.5 ? "M" : moon >= 0.2 ? "m" : "."
            }
            print("    \"\(line)\", // \(py)")
        }
    }
}

print("render_appicon: \(ladder.count) files -> \(outDir.path)")
