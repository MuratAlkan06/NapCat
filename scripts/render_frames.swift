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
//   idle0…idle16          — the user's hand-drawn 17-frame groom→sit cycle
//       (art/idle/idle00…idle16.png, committed), processed into template
//       frames scaled for iconPointHeight=21: <name>.png = 21×21 @1x,
//       <name>@2x.png = 42×42 @2x (a true higher-resolution render, not pixel
//       doubling). ONE union crop for all 17 frames, so the cat never
//       jitters. The drawn interior details (eyes, mouth, paw/leg lines) are
//       widened at source resolution first so they read at icon size. See the
//       idle-cycle pipeline below. (It replaced the static
//       grooming-cat "sleep" still from art/groom-source.png, 2026-11-19; that
//       source now feeds only scripts/render_appicon.swift.)
//
// DETERMINISM: output must be byte-identical across runs so regeneration
// keeps `git status` clean. The PNG encoder is self-contained and writes only
// IHDR/IDAT/IEND with a stored (uncompressed) zlib stream — no timestamps, no
// metadata chunks, no library whose compression may vary. The idle pipeline
// is pure integer/float math over fixed committed sources, so it too is
// reproducible (`make frames` twice → identical bytes, verified by shasum).
//
// ── run/sit design intent (ORIGINAL artwork — do not copy RunCat) ──────────
// Drawn by hand on the 18×18 grid: chunky 2px limbs/tail, boxy square head
// with a flat muzzle and 1px ear nubs, straight lance tail never curled over
// the back; three deliberately distinct silhouettes. 1px breathing room on
// every edge (outer ring transparent — validated below).
//   run — long low 5-phase gallop, side profile facing right, 1px body bob
//   sit — tall upright cat, tail wrapped along the ground; sit1 lifts the tip
// (the idle cat is the user's hand-drawn art — see the idle-cycle pipeline.)

import AppKit  // re-exports Foundation; CoreGraphics decodes the hand-drawn sources

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

// MARK: - Idle-cycle pipeline (idle frames from art/idle/idle00…idle16.png)
//
// The user's 17 hand-drawn 640×640 exports (frame order = export order:
// 00–04 paw-lick with eyes closed, 05–11 paw lowers / eyes open, 12–16
// upright sit) are WHITE art on transparency whose interior details — eyes,
// mouth, paw and leg lines — are drawn as transparent HOLES. The alpha
// channel alone therefore carries the whole drawing (unlike the retired
// dark-stroke groom pipeline, no dark-outline classification is needed).
// Steps (all deterministic; standing art rulings — NO hard threshold and NO
// dilation on the final rasters. Step 2b, the owner-requested detail
// widening of issue #59, opens the source HOLES before the downscale; the
// silhouette and steps 3–5 stay exactly as ruled):
//   1. Decode + validate: exactly idle00…idle16 present, each 640×640, every
//      visible pixel LIGHT. A dark opaque stroke would be blackened into the
//      body and silently lose its detail, so it fails the render loudly.
//   2. Template: alpha kept exactly as drawn, RGB → 0 (pure black + alpha);
//      the interior holes stay transparent → negative-space detail.
//   2b. Widen the interior details (owner request, issue #59, 2026-11-19):
//      the ~15× downscale + γ boost filled the 4–8 px drawn holes in until
//      the face and paws no longer read. Transparency reachable from the
//      canvas border is the EXTERIOR; every other at-least-half-transparent
//      pixel is a drawn DETAIL. Details grow by a disc of
//      `idleDetailWidenRadius` source px, but never within `idleOutlineGuard`
//      px of the exterior or the canvas edge, so the silhouette is untouched
//      and its outline stays visibly closed at icon size. The render fails
//      loudly if a widened detail ever touches or merges into the exterior.
//   3. ONE union bounding box across all 17 frames → centred square +4% pad
//      per side. Every frame uses that single crop, so the cat never jitters
//      frame to frame (only the drawn motion moves).
//   4. Area-average downscale to 21px (@1x) and 42px (@2x) — a true 2× render.
//   5. Gentle γ0.45 alpha boost.

let idleFrameCount = 17

/// Every idle source (art/idle/*.png) is a 640×640 export.
let sourceSize = 640

/// Interior-detail widening strength (step 2b): source pixels added to EACH
/// side of every drawn detail (disc kernel). Owner-tunable — the previews
/// offered 6 (subtle), 9 (medium) and 12 (bold); changing it is this one
/// line plus `make frames`.
let idleDetailWidenRadius = 6

/// Minimum distance, in source pixels, between any widened pixel and the
/// exterior (or the canvas edge). About one pixel of the 42px frame (the crop
/// maps ≈16.4 source px onto one @2x pixel), so the outline that separates a
/// widened detail from the outside survives the downscale as a visible wall
/// instead of a sub-pixel sliver that the area average washes out.
let idleOutlineGuard = 16

/// The exterior flood passes only through effectively empty pixels — alpha
/// ≤ 10, the same "not visible art" cutoff `alphaBBox` uses — so the
/// anti-aliased fringe around a drawn detail walls it off from the outside.
let idleExteriorMaxAlpha: UInt8 = 10

/// A non-exterior pixel at least half transparent belongs to a drawn detail.
/// The details are anti-aliased: a hairline's core often never reaches the
/// exterior cutoff, so a stricter test would widen it as scattered dots.
let idleDetailMaxAlpha: UInt8 = 127

/// Decode a committed hand-drawn source into straight (un-premultiplied)
/// RGBA, top row first. CoreGraphics decode of a fixed file is reproducible.
///
/// ORIENTATION: a CGBitmapContext's backing buffer is stored top-row-first
/// (memory offset 0 = the visual TOP of the drawn image); `ctx.draw` maps the
/// source image's top to that first row. So the buffer is already top-down and
/// must NOT be flipped — an earlier flip here (mistaking the bottom-left user-
/// space origin for the memory layout) rendered the former grooming-cat icon
/// upside down (2026-07-11).
func decodeSource(path: String) -> [UInt8] {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("could not load source art at \(path)")
    }
    guard cg.width == sourceSize, cg.height == sourceSize else {
        fail("\(path): source art must be \(sourceSize)×\(sourceSize), got \(cg.width)×\(cg.height)")
    }
    var buf = [UInt8](repeating: 0, count: sourceSize * sourceSize * 4)
    guard let ctx = CGContext(
        data: &buf, width: sourceSize, height: sourceSize, bitsPerComponent: 8,
        bytesPerRow: sourceSize * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create decode context") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sourceSize, height: sourceSize))
    // Un-premultiply so edge-pixel luma is straight (only affects the
    // light-art validation; blackening discards RGB afterward).
    for i in 0..<(sourceSize * sourceSize) {
        let a = buf[i * 4 + 3]
        if a > 0 && a < 255 {
            for c in 0..<3 { buf[i * 4 + c] = UInt8(min(255, Int(buf[i * 4 + c]) * 255 / Int(a))) }
        }
    }
    // Buffer is already top-row-first (see ORIENTATION note above) — no flip.
    return buf
}

typealias BBox = (minX: Int, minY: Int, maxX: Int, maxY: Int)

/// Bounding box of the visible art (alpha > 10) in a sourceSize² alpha mask.
/// An empty mask yields an inverted box (min > max); callers reject it.
func alphaBBox(_ a: [UInt8]) -> BBox {
    let n = sourceSize
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<n { for x in 0..<n where a[y * n + x] > 10 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }}
    return (minX, minY, maxX, maxY)
}

/// The centred crop square around a bounding box, padded with ~4% breathing
/// room per side (side = longer bbox edge × 1.08).
func paddedCropSquare(_ b: BBox) -> (ox: Double, oy: Double, side: Double) {
    let cw = Double(b.maxX - b.minX + 1), ch = Double(b.maxY - b.minY + 1)
    let side = max(cw, ch) * 1.08                 // +4% breathing room per side
    let ox = Double(b.minX) - (side - cw) / 2
    let oy = Double(b.minY) - (side - ch) / 2
    return (ox, oy, side)
}

/// Area-average downscale of a single alpha channel from a source square
/// [ox,oy] size `side` into `out`×`out` (fractional edge weighting).
func downscaleAlpha(_ a: [UInt8], ox: Double, oy: Double, side: Double, out: Int) -> [UInt8] {
    let n = sourceSize
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

/// Step 1+2 for one idle source → its alpha mask (RGB implicitly 0).
func idleTemplateAlpha(_ px: [UInt8], name: String) -> [UInt8] {
    var alpha = [UInt8](repeating: 0, count: sourceSize * sourceSize)
    for i in 0..<(sourceSize * sourceSize) {
        let a = px[i * 4 + 3]
        if a > 40 {
            let luma = 0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])
            if luma < 128 {
                fail("\(name): dark opaque pixel at (\(i % sourceSize), \(i / sourceSize)) — the idle pipeline expects white art whose interior details are transparent holes")
            }
        }
        alpha[i] = a
    }
    return alpha
}

/// Pixels reachable from the canvas border through 8-connected exterior
/// transparency (alpha ≤ `idleExteriorMaxAlpha`) in a sourceSize² mask.
/// Span fill: each popped seed claims its whole horizontal run, then seeds
/// every run in the rows above and below that touches it — diagonals
/// included (the scan spans one pixel past each end). Same set as a
/// pixel-by-pixel flood, many times faster under `swift`'s unoptimised
/// script mode.
func exteriorMask(_ a: [UInt8]) -> [Bool] {
    let n = sourceSize
    var exterior = [Bool](repeating: false, count: n * n)
    var stack: [Int] = []
    for i in 0..<n { stack += [i, (n - 1) * n + i, i * n, i * n + n - 1] }
    while let p = stack.popLast() {
        if exterior[p] || a[p] > idleExteriorMaxAlpha { continue }
        let row = (p / n) * n
        var left = p - row, right = left
        while left > 0 && !exterior[row + left - 1] && a[row + left - 1] <= idleExteriorMaxAlpha { left -= 1 }
        while right < n - 1 && !exterior[row + right + 1] && a[row + right + 1] <= idleExteriorMaxAlpha { right += 1 }
        var x = left
        while x <= right { exterior[row + x] = true; x += 1 }
        for neighbourRow in [row - n, row + n] where neighbourRow >= 0 && neighbourRow < n * n {
            var inRun = false
            x = max(0, left - 1)
            while x <= min(n - 1, right + 1) {
                let q = neighbourRow + x
                let open = !exterior[q] && a[q] <= idleExteriorMaxAlpha
                if open && !inRun { stack.append(q) }
                inRun = open
                x += 1
            }
        }
    }
    return exterior
}

/// Exact squared Euclidean distance from every pixel to the nearest `true`
/// pixel of a sourceSize² mask (Meijster, Roerdink & Hesselink 2000):
/// integer-only, so it is deterministic. A mask with no `true` pixel yields
/// distances far beyond any radius used here. (Plain while loops and no
/// nested helper functions: `swift`'s unoptimised script mode runs them
/// several times faster.)
func squaredDistanceTransform(_ mask: [Bool]) -> [Int] {
    let n = sourceSize
    let far = 2 * n
    // Phase 1: per column, the distance g to the nearest feature in that
    // column; phase 2 only needs it squared (g2).
    var g = [Int](repeating: 0, count: n * n)
    for x in 0..<n {
        g[x] = mask[x] ? 0 : far
        var y = 1
        while y < n {
            let p = y * n + x
            g[p] = mask[p] ? 0 : min(far, g[p - n] + 1)
            y += 1
        }
        y = n - 2
        while y >= 0 {
            let p = y * n + x
            if g[p + n] < g[p] { g[p] = g[p + n] + 1 }
            y -= 1
        }
    }
    let g2 = g.map { $0 * $0 }
    // Phase 2: per row, the lower envelope of the parabolas (x−i)² + g²(i):
    // s = the envelope's parabola apexes, t = where each takes over.
    var result = [Int](repeating: 0, count: n * n)
    var s = [Int](repeating: 0, count: n), t = [Int](repeating: 0, count: n)
    var row = 0
    while row < n * n {
        var q = 0
        s[0] = 0; t[0] = 0
        var u = 1
        while u < n {
            // Drop envelope parabolas that u's parabola beats at their start.
            while q >= 0 {
                let start = t[q], apex = s[q]
                let old = (start - apex) * (start - apex) + g2[row + apex]
                let new = (start - u) * (start - u) + g2[row + u]
                if old > new { q -= 1 } else { break }
            }
            if q < 0 {
                q = 0; s[0] = u
            } else {
                // Floor of the intersection abscissa (denominator > 0), + 1.
                let i = s[q]
                let num = u * u - i * i + g2[row + u] - g2[row + i]
                let den = 2 * (u - i)
                let w = 1 + (num >= 0 ? num / den : -((-num + den - 1) / den))
                if w < n { q += 1; s[q] = u; t[q] = w }
            }
            u += 1
        }
        u = n - 1
        while u >= 0 {
            let i = s[q]
            result[row + u] = (u - i) * (u - i) + g2[row + i]
            if u == t[q] { q -= 1 }
            u -= 1
        }
        row += n
    }
    return result
}

/// Step 2b for one idle template alpha: grow the drawn interior details by a
/// disc of `idleDetailWidenRadius`, clamped `idleOutlineGuard` px clear of the
/// exterior and the canvas edge. Widened pixels become fully transparent;
/// every other pixel keeps its drawn alpha. Fails the render if a detail
/// merges into the exterior or a widened pixel touches an exterior-adjacent
/// pixel or the canvas edge.
func widenInteriorDetails(_ alpha: [UInt8], name: String) -> [UInt8] {
    let n = sourceSize
    let exterior = exteriorMask(alpha)
    // Keep-out features: the exterior plus the canvas edge (art that touches
    // the edge has no exterior pixel beyond it, but the crop treats
    // off-canvas as empty, so the edge is outline too).
    var keepOut = exterior
    for i in 0..<n {
        keepOut[i] = true; keepOut[(n - 1) * n + i] = true
        keepOut[i * n] = true; keepOut[i * n + n - 1] = true
    }
    let keepOutDistance = squaredDistanceTransform(keepOut)
    let guardSquared = idleOutlineGuard * idleOutlineGuard
    var details = [Bool](repeating: false, count: n * n)
    for p in 0..<(n * n) where !exterior[p] && alpha[p] <= idleDetailMaxAlpha && keepOutDistance[p] > guardSquared {
        details[p] = true
    }
    let detailDistance = squaredDistanceTransform(details)
    let radiusSquared = idleDetailWidenRadius * idleDetailWidenRadius
    var widened = alpha
    for p in 0..<(n * n) where detailDistance[p] <= radiusSquared && keepOutDistance[p] > guardSquared {
        widened[p] = 0
    }
    // Silhouette check, independent of the distance transforms above: the
    // exterior recomputed from the widened art must be exactly the drawn one
    // (no detail merged into it), and no changed pixel may touch an
    // exterior-adjacent pixel or the canvas edge — every widened detail keeps
    // at least a 2 px wall of drawn art between itself and the outside.
    let widenedExterior = exteriorMask(widened)
    guard widenedExterior == exterior else {
        fail("\(name): a widened interior detail merged into the exterior — the silhouette would breach")
    }
    for p in 0..<(n * n) where widened[p] != alpha[p] {
        let x = p % n, y = p / n
        guard x >= 2 && y >= 2 && x < n - 2 && y < n - 2 else {
            fail("\(name): widened detail pixel (\(x), \(y)) touches the canvas edge")
        }
        for dy in -2...2 {
            for dx in -2...2 where widenedExterior[(y + dy) * n + x + dx] {
                fail("\(name): widened detail pixel (\(x), \(y)) touches an exterior-adjacent pixel")
            }
        }
    }
    return widened
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

// idle — the hand-drawn 17-frame groom→sit cycle at 21/42, one union crop.
let idleSourceDirectory = repoRoot.appendingPathComponent("art/idle", isDirectory: true)
let idleSourceNames = (0..<idleFrameCount).map { String(format: "idle%02d.png", $0) }
let idleSourcesOnDisk = ((try? FileManager.default.contentsOfDirectory(atPath: idleSourceDirectory.path)) ?? [])
    .filter { $0.hasSuffix(".png") }
guard Set(idleSourcesOnDisk) == Set(idleSourceNames) else {
    fail("art/idle must hold exactly \(idleSourceNames.first!)…\(idleSourceNames.last!), found \(idleSourcesOnDisk.sorted())")
}
let idleMasks = idleSourceNames.map { name in
    widenInteriorDetails(
        idleTemplateAlpha(decodeSource(path: idleSourceDirectory.appendingPathComponent(name).path), name: name),
        name: name)
}
var idleUnion: BBox = (sourceSize, sourceSize, -1, -1)
for (name, mask) in zip(idleSourceNames, idleMasks) {
    let b = alphaBBox(mask)
    guard b.minX <= b.maxX, b.minY <= b.maxY else { fail("\(name): blank frame (no visible art)") }
    idleUnion = (min(idleUnion.minX, b.minX), min(idleUnion.minY, b.minY),
                 max(idleUnion.maxX, b.maxX), max(idleUnion.maxY, b.maxY))
}
let idleSquare = paddedCropSquare(idleUnion)
for (index, mask) in idleMasks.enumerated() {
    for (suffix, size) in [("", 21), ("@2x", 42)] {
        let alpha = downscaleAlpha(mask, ox: idleSquare.ox, oy: idleSquare.oy, side: idleSquare.side, out: size)
        let data = encodePNG(width: size, height: size, rgba: gammaBoostToRGBA(alpha, 0.45))
        write("idle\(index)\(suffix).png", data, "\(size)x\(size)")
    }
}

print("render_frames: \(gridFrames.count) grid + \(idleFrameCount) idle frames (details widened r=\(idleDetailWidenRadius), guard \(idleOutlineGuard)) -> \(outputDirectory.path)")
