#!/usr/bin/env swift
// render_frames.swift — NapCat icon frame renderer (PLAN.md ADR §10).
//
// Run from the repo root:  swift scripts/render_frames.swift   (or `make frames`)
//
// Produces every animation frame in Resources/frames/ as template PNGs
// (black + alpha; the system tints them for the menu bar):
//
//   run0…run4, sit0…sit1  — ORIGINAL on-grid pixel art, rendered from the
//       in-code 18×18 "X"/"." grids below.  <name>.png = 18×18 @1x,
//       <name>@2x.png = 36×36 (nearest-neighbor 2× doubling of the grid).
//
//   sleep0…sleep2         — the user's hand-drawn grooming cat
//       (art/groom-source.png, committed), processed into ONE static template
//       and scaled for iconPointHeight=21: <name>.png = 21×21 @1x,
//       <name>@2x.png = 42×42 @2x (a true higher-resolution render, not pixel
//       doubling). All three sleepN frames are byte-identical copies — the
//       sleep state is a STILL image, not an animation (the user rejected the
//       synthetic head-bob, decision log 2026-07-11). See the pipeline below.
//
// DETERMINISM: output must be byte-identical across runs so regeneration
// keeps `git status` clean. The PNG encoder is self-contained and writes only
// IHDR/IDAT/IEND with a stored (uncompressed) zlib stream — no timestamps, no
// metadata chunks, no library whose compression may vary. The groom pipeline
// is pure integer/float math over a fixed committed source, so it too is
// reproducible (`make frames` twice → identical bytes, verified by shasum).
//
// ── run/sit design intent (ORIGINAL artwork — do not copy RunCat) ──────────
// Drawn by hand on the 18×18 grid: chunky 2px limbs/tail, boxy square head
// with a flat muzzle and 1px ear nubs, straight lance tail never curled over
// the back; three deliberately distinct silhouettes. 1px breathing room on
// every edge (outer ring transparent — validated below).
//   run — long low 5-phase gallop, side profile facing right, 1px body bob
//   sit — tall upright cat, tail wrapped along the ground; sit1 lifts the tip
// (sleep is now the processed grooming cat — see the pipeline section.)

import AppKit  // re-exports Foundation; CoreGraphics decodes the groom source

// MARK: - Pixel grids (single source of truth for run/sit)

let canvas = 18

struct Frame {
    let name: String
    let grid: [String]
}

let gridFrames: [Frame] = [
    // ───── run: 5-frame gallop, side profile facing right, ~10 fps ─────
    Frame(name: "run0", grid: [ // flight/stretch: airborne, legs splayed fore+aft, tail high
        "..................",
        "..................",
        "..................",
        "..................",
        "............X..X..",
        ".X..........XXXX..",
        ".XX.........XXXXX.",
        "..XXXXXXXXXXXXXXX.",
        "..XXXXXXXXXXXXXX..",
        "...XXXXXXXXXXXXX..",
        "...XXX.......XXX..",
        "..XX..........XX..",
        ".XX............XX.",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "run1", grid: [ // front contact: body dips 1px, front leg planted, hinds swing under
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "............X..X..",
        ".X..........XXXX..",
        ".XX.........XXXXX.",
        "..XXXXXXXXXXXXXXX.",
        "..XXXXXXXXXXXXXX..",
        "...XXXXXXXXXXXXX..",
        "....XXX.....XXXX..",
        ".....XX.....XX....",
        "............XX....",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "run2", grid: [ // gather: body compressed, all legs tucked, tail level
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "............X..X..",
        "............XXXX..",
        ".XXX........XXXXX.",
        "...XXXXXXXXXXXXXX.",
        "....XXXXXXXXXXXX..",
        "....XXXXXXXXXXXX..",
        ".....XXX...XXX....",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "run3", grid: [ // hind contact: hind leg planted, front legs reaching forward
        "..................",
        "..................",
        "..................",
        "..................",
        "............X..X..",
        "............XXXX..",
        ".X..........XXXXX.",
        ".XXXXXXXXXXXXXXXX.",
        "..XXXXXXXXXXXXXX..",
        "...XXXXXXXXXXXXX..",
        "...XXXX......XXXX.",
        "....XX........XXX.",
        "....XX............",
        "....XX............",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "run4", grid: [ // push-off: hind extended down-back, fronts lifting, tail high
        "..................",
        "..................",
        "..................",
        "..................",
        ".X..........X..X..",
        ".XX.........XXXX..",
        "..X.........XXXXX.",
        "..XXXXXXXXXXXXXXX.",
        "..XXXXXXXXXXXXXX..",
        "...XXXXXXXXXXXXX..",
        "...XXX......XXXX..",
        "..XX.........XX...",
        ".XX...............",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    // ───── sit: content upright cat, ~1 fps; sit1 lifts the tail tip 1px ─────
    Frame(name: "sit0", grid: [ // tail flat along the ground, tip in front of the paws
        "..................",
        "..................",
        "..........X..X....",
        "..........XXXX....",
        ".........XXXXXX...",
        ".........XXXXXX...",
        "..........XXXX....",
        "..........XXXX....",
        ".........XXXXX....",
        "........XXXXXX....",
        ".......XXXXXXX....",
        "......XXXXXXXX....",
        "......XXXXXXXX....",
        ".....XXXXXXXXX....",
        ".....XXXXXXXXX....",
        "....XXXXXXXXXXX...",
        "..................",
        "..................",
    ]),
    Frame(name: "sit1", grid: [ // tail tip raised one pixel (idle flick)
        "..................",
        "..................",
        "..........X..X....",
        "..........XXXX....",
        ".........XXXXXX...",
        ".........XXXXXX...",
        "..........XXXX....",
        "..........XXXX....",
        ".........XXXXX....",
        "........XXXXXX....",
        ".......XXXXXXX....",
        "......XXXXXXXX....",
        "......XXXXXXXX....",
        ".....XXXXXXXXX....",
        ".....XXXXXXXXXX...",
        "....XXXXXXXXXX....",
        "..................",
        "..................",
    ]),
]

// MARK: - Validation of the run/sit grids (fail loudly before writing)

let expectedGridNames = (0..<5).map { "run\($0)" } + (0..<2).map { "sit\($0)" }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render_frames: ERROR: " + message + "\n").utf8))
    exit(1)
}

guard gridFrames.map(\.name) == expectedGridNames else {
    fail("grid frame names/order must be exactly \(expectedGridNames), got \(gridFrames.map(\.name))")
}

for frame in gridFrames {
    guard frame.grid.count == canvas else {
        fail("\(frame.name): expected \(canvas) rows, got \(frame.grid.count)")
    }
    for (rowIndex, row) in frame.grid.enumerated() {
        guard row.count == canvas else {
            fail("\(frame.name) row \(rowIndex): expected \(canvas) chars, got \(row.count)")
        }
        guard row.allSatisfy({ $0 == "X" || $0 == "." }) else {
            fail("\(frame.name) row \(rowIndex): only 'X' and '.' are allowed")
        }
        let isEdgeRow = rowIndex == 0 || rowIndex == canvas - 1
        if isEdgeRow, row.contains("X") {
            fail("\(frame.name) row \(rowIndex): edge rows must be empty (1px margin)")
        }
        if row.hasPrefix("X") || row.hasSuffix("X") {
            fail("\(frame.name) row \(rowIndex): edge columns must be empty (1px margin)")
        }
    }
}

// MARK: - Deterministic PNG encoder (IHDR + one stored-deflate IDAT + IEND)

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
    for byte in bytes {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
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

/// 8-bit RGBA PNG. `rgba` is width*height*4 bytes, rows top to bottom.
/// All NapCat frames are ≤ 42×42, so the single stored deflate block (≤ 64 KB
/// raw) always suffices.
func encodePNG(width: Int, height: Int, rgba: [UInt8]) -> Data {
    precondition(rgba.count == width * height * 4)
    // Scanlines, each prefixed with filter type 0 (None).
    var raw: [UInt8] = []
    raw.reserveCapacity(height * (1 + width * 4))
    for y in 0..<height {
        raw.append(0)
        raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
    }
    precondition(raw.count <= 0xFFFF, "single stored deflate block only")
    // zlib header 0x78 0x01 ((0x78*256+0x01) % 31 == 0), then one stored
    // block: BFINAL=1/BTYPE=00, LEN + NLEN little-endian, raw data, Adler-32.
    let len = raw.count
    let nlen = len ^ 0xFFFF
    var idat: [UInt8] = [
        0x78, 0x01, 0x01,
        UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
        UInt8(nlen & 0xFF), UInt8((nlen >> 8) & 0xFF),
    ]
    idat += raw
    idat += bigEndian32(adler32(raw))
    // bit depth 8, color type 6 (RGBA), compression 0, filter 0, interlace 0
    let ihdr = bigEndian32(UInt32(width)) + bigEndian32(UInt32(height)) + [8, 6, 0, 0, 0]
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += pngChunk("IHDR", ihdr)
    png += pngChunk("IDAT", idat)
    png += pngChunk("IEND", [])
    return Data(png)
}

/// Grid → RGBA at an integer scale (nearest neighbor: each cell becomes a
/// scale×scale block). "X" = opaque black, "." = fully transparent.
func rasterize(grid: [String], scale: Int) -> [UInt8] {
    let size = canvas * scale
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    for (rowIndex, row) in grid.enumerated() {
        for (colIndex, cell) in row.enumerated() where cell == "X" {
            for dy in 0..<scale {
                for dx in 0..<scale {
                    let y = rowIndex * scale + dy
                    let x = colIndex * scale + dx
                    rgba[(y * size + x) * 4 + 3] = 255 // alpha; RGB stays black
                }
            }
        }
    }
    return rgba
}

// MARK: - Groom-art pipeline (sleep frames from art/groom-source.png)
//
// Turns the user's 640×640 hand-drawn grooming cat into ONE static template
// frame (the rest pose). Steps (all deterministic; user-validated chain,
// PLAN.md decision log 2026-07-11):
//   1. Interior-line cutout: flood-fill the transparent exterior from the
//      corners; dark outline pixels (luma < 90) within 3px of the exterior are
//      kept (outer outline), interior dark lines (eyes, paw stroke) are cut to
//      alpha 0 → negative-space detail.
//   2. Blacken: every surviving opaque pixel is pure black (RGB 0), alpha kept
//      — so the result is a solid black cat with cutout gaps (template icons
//      render gray as dim, so gray must become black).
//   3. Trim to the silhouette's bounding box, pad to a centred square with
//      ~4% breathing room.
//   4. Area-average downscale to 21px (@1x) and 42px (@2x) — a true 2× render.
//   5. Gentle γ0.45 alpha boost (no hard threshold, no dilation).
//
// The single result is written to sleep0/1/2 as three byte-identical copies:
// the sleep icon is a STILL grooming cat. The earlier synthetic head-bob was
// rejected by the user; the upcoming 17-frame hand-drawn set will animate the
// SIT state instead (decision log 2026-07-11).

let groomSize = 640

/// Decode the committed groom source into straight (un-premultiplied) RGBA,
/// top row first. CoreGraphics decode of a fixed file is reproducible.
///
/// ORIENTATION: a CGBitmapContext's backing buffer is stored top-row-first
/// (memory offset 0 = the visual TOP of the drawn image); `ctx.draw` maps the
/// source image's top to that first row. So the buffer is already top-down and
/// must NOT be flipped — an earlier flip here (mistaking the bottom-left user-
/// space origin for the memory layout) rendered the sleep cat upside down.
func decodeGroomSource(path: String) -> [UInt8] {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("could not load groom source at \(path)")
    }
    guard cg.width == groomSize, cg.height == groomSize else {
        fail("groom source must be \(groomSize)×\(groomSize), got \(cg.width)×\(cg.height)")
    }
    var buf = [UInt8](repeating: 0, count: groomSize * groomSize * 4)
    guard let ctx = CGContext(
        data: &buf, width: groomSize, height: groomSize, bitsPerComponent: 8,
        bytesPerRow: groomSize * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create decode context") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: groomSize, height: groomSize))
    // Un-premultiply so edge-pixel luma is straight (only affects the luma
    // classification in step 1; blackening discards RGB afterward).
    for i in 0..<(groomSize * groomSize) {
        let a = buf[i * 4 + 3]
        if a > 0 && a < 255 {
            for c in 0..<3 { buf[i * 4 + c] = UInt8(min(255, Int(buf[i * 4 + c]) * 255 / Int(a))) }
        }
    }
    // Buffer is already top-row-first (see ORIENTATION note above) — no flip.
    return buf
}

/// Steps 1+2 → a black-cat alpha mask (RGB implicitly 0).
func buildGroomSilhouette(_ px: [UInt8]) -> [UInt8] {
    let n = groomSize
    func idx(_ x: Int, _ y: Int) -> Int { y * n + x }
    func blocked(_ x: Int, _ y: Int) -> Bool { px[idx(x, y) * 4 + 3] > 40 }
    // Exterior = flood fill of {alpha ≤ 40} from the four corners (4-conn).
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
    // "within 3px of exterior" = dilate the exterior by a radius-3 disk.
    var kernel: [(Int, Int)] = []
    for dy in -3...3 { for dx in -3...3 where dx * dx + dy * dy <= 9 { kernel.append((dx, dy)) } }
    var nearOutside = [Bool](repeating: false, count: n * n)
    for y in 0..<n { for x in 0..<n where outside[idx(x, y)] {
        for (dx, dy) in kernel {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= n || ny >= n { continue }
            nearOutside[idx(nx, ny)] = true
        }
    }}
    var alpha = [UInt8](repeating: 0, count: n * n)
    for y in 0..<n { for x in 0..<n {
        let i = idx(x, y)
        let a = px[i * 4 + 3]
        if a <= 40 { continue } // transparent
        let luma = 0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])
        if luma < 90 {
            if nearOutside[i] { alpha[i] = a } // outer outline → keep
            // else interior line (eyes, paw stroke) → cut (alpha stays 0)
        } else {
            alpha[i] = a // body fill → keep
        }
    }}
    return alpha
}

func groomBBox(_ a: [UInt8]) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
    let n = groomSize
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<n { for x in 0..<n where a[y * n + x] > 10 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }}
    return (minX, minY, maxX, maxY)
}

/// Area-average downscale of a single alpha channel from a source square
/// [ox,oy] size `side` into `out`×`out` (fractional edge weighting).
func downscaleAlpha(_ a: [UInt8], ox: Double, oy: Double, side: Double, out: Int) -> [UInt8] {
    let n = groomSize
    var result = [UInt8](repeating: 0, count: out * out)
    for oyi in 0..<out {
        let y0 = oy + Double(oyi) / Double(out) * side
        let y1 = oy + Double(oyi + 1) / Double(out) * side
        for oxi in 0..<out {
            let x0 = ox + Double(oxi) / Double(out) * side
            let x1 = ox + Double(oxi + 1) / Double(out) * side
            var sum = 0.0, area = 0.0
            var yy = Int(y0.rounded(.down))
            let yyEnd = Int(y1.rounded(.up)) - 1
            while yy <= yyEnd {
                let wy = min(Double(yy) + 1, y1) - max(Double(yy), y0)
                if wy > 0 {
                    var xx = Int(x0.rounded(.down))
                    let xxEnd = Int(x1.rounded(.up)) - 1
                    while xx <= xxEnd {
                        let wx = min(Double(xx) + 1, x1) - max(Double(xx), x0)
                        if wx > 0 {
                            let cover = wx * wy
                            area += cover
                            let av = (xx >= 0 && yy >= 0 && xx < n && yy < n) ? Double(a[yy * n + xx]) : 0.0
                            sum += cover * av
                        }
                        xx += 1
                    }
                }
                yy += 1
            }
            result[oyi * out + oxi] = area > 0 ? UInt8(max(0, min(255, (sum / area).rounded()))) : 0
        }
    }
    return result
}

func gammaBoostToRGBA(_ alpha: [UInt8], _ gamma: Double) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: alpha.count * 4) // RGB stays 0 (black)
    for (i, a) in alpha.enumerated() {
        rgba[i * 4 + 3] = UInt8(max(0, min(255, (255.0 * pow(Double(a) / 255.0, gamma)).rounded())))
    }
    return rgba
}

/// The centred crop square for the static sleep cat: the silhouette's own
/// bounding box, padded with ~4% breathing room per side. There is no motion,
/// so the crop is simply this one rest-pose silhouette's extent (identical to
/// the former union bbox — the removed head-bob only ever shrank the head, so
/// the rest pose was always the widest frame).
func groomCropSquare(_ silhouette: [UInt8]) -> (ox: Double, oy: Double, side: Double) {
    let b = groomBBox(silhouette)
    let cw = Double(b.maxX - b.minX + 1), ch = Double(b.maxY - b.minY + 1)
    let side = max(cw, ch) * 1.08                 // +4% breathing room per side
    let ox = Double(b.minX) - (side - cw) / 2
    let oy = Double(b.minY) - (side - ch) / 2
    return (ox, oy, side)
}

// MARK: - Resolve the repo root from the script's own path (works from any cwd)

let scriptPath = CommandLine.arguments.first ?? "scripts/render_frames.swift"
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var scriptURL = URL(fileURLWithPath: scriptPath, relativeTo: cwd).standardizedFileURL
if !FileManager.default.fileExists(atPath: scriptURL.path) {
    scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
}
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = repoRoot.appendingPathComponent("Resources/frames", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("could not create \(outputDirectory.path): \(error)")
}

func write(_ name: String, _ data: Data, _ dims: String) {
    let url = outputDirectory.appendingPathComponent(name)
    do {
        try data.write(to: url)
    } catch {
        fail("could not write \(url.path): \(error)")
    }
    print("wrote \(name) (\(data.count) bytes, \(dims))")
}

// run/sit — grid art at 18/36.
for frame in gridFrames {
    for (suffix, scale) in [("", 1), ("@2x", 2)] {
        let size = canvas * scale
        let data = encodePNG(width: size, height: size, rgba: rasterize(grid: frame.grid, scale: scale))
        write("\(frame.name)\(suffix).png", data, "\(size)x\(size)")
    }
}

// sleep — processed grooming cat at 21/42, rendered ONCE and written to all
// three sleep frames (the sleep icon is static; the head-bob was removed).
let sleepFrameCount = 3
let groomSourcePath = repoRoot.appendingPathComponent("art/groom-source.png").path
let silhouette = buildGroomSilhouette(decodeGroomSource(path: groomSourcePath))
let square = groomCropSquare(silhouette)
for (suffix, size) in [("", 21), ("@2x", 42)] {
    let alpha = downscaleAlpha(silhouette, ox: square.ox, oy: square.oy, side: square.side, out: size)
    let data = encodePNG(width: size, height: size, rgba: gammaBoostToRGBA(alpha, 0.45))
    for index in 0..<sleepFrameCount {
        write("sleep\(index)\(suffix).png", data, "\(size)x\(size)")
    }
}

print("render_frames: \(gridFrames.count) grid + \(sleepFrameCount) sleep frames (static) -> \(outputDirectory.path)")
