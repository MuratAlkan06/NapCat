#!/usr/bin/env swift
// render_frames.swift — NapCat pixel-art frame renderer (PLAN.md ADR §10).
//
// Run from the repo root:  swift scripts/render_frames.swift   (or `make frames`)
//
// Renders every frame below from an in-code 18×18 pixel grid ("X" = opaque
// black, "." = transparent) into template PNGs in Resources/frames/:
//   <name>.png     18×18  @1x
//   <name>@2x.png  36×36  @2x — nearest-neighbor pixel doubling of the SAME
//                  grid (each cell becomes a crisp 2×2 block; no interpolation)
//
// DETERMINISM: output must be byte-identical across runs so regeneration
// keeps `git status` clean. The PNG encoder below is self-contained and
// writes only IHDR/IDAT/IEND with a stored (uncompressed) zlib stream — no
// timestamps, no metadata chunks, no library whose compression may vary.
//
// ── Design intent (ORIGINAL artwork — PLAN.md hard rule: do not copy RunCat) ─
// Drawn by hand on the 18×18 grid for this project. Style choices that set it
// apart from RunCat's runner (thin-limbed, round-headed, curved-tail outline
// cat) and make it read at menu-bar size:
//   • chunky silhouette: 2px-thick legs and tail, no 1px outlines or noise
//   • boxy, square head with a flat muzzle and two 1px triangular ear nubs
//   • straight, lance-like streaming tail (never curled over the back)
//   • three deliberately distinct silhouettes so state is legible at a glance:
//       run    — long and low (side profile, facing right), 5-phase gallop:
//                flight/stretch → front contact → gather → hind contact →
//                push-off; 1px vertical body bob; tail waves high→level→high;
//                ground plane fixed at row 13
//       sleep  — low round curled-kitten blob, head tucked (only the ear nubs
//                peek out, upper right); frames differ ONLY by the slow tail
//                flick along the left side (tip up / mid / down)
//       sit    — tall upright cat, straight chest edge (front legs), back
//                curving out to the haunches, tail wrapped around the front
//                paws along the ground; sit1 lifts just the tail tip 1px
//   • 1px breathing room on every edge (outer ring always transparent —
//     validated below)
// Rendered as template images (black + alpha): the system tints them for
// menu-bar appearance, so no colors are baked in.

import Foundation

// MARK: - Pixel grids (single source of truth for the art)

let canvas = 18

struct Frame {
    let name: String
    let grid: [String]
}

let frames: [Frame] = [
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
    // ───── sleep: curled kitten, ~0.5 fps; frames differ ONLY by tail flick ─────
    Frame(name: "sleep0", grid: [ // tail tip UP (col 2 reaches row 8)
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "...........X..X...",
        "..........XXXXXX..",
        ".......XXXXXXXXXX.",
        "..X..XXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "...XXXXXXXXXXXXXX.",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "sleep1", grid: [ // tail tip MID (col 2 reaches row 9)
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "...........X..X...",
        "..........XXXXXX..",
        ".......XXXXXXXXXX.",
        ".....XXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "...XXXXXXXXXXXXXX.",
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
    ]),
    Frame(name: "sleep2", grid: [ // tail tip DOWN (col 2 reaches row 10)
        "..................",
        "..................",
        "..................",
        "..................",
        "..................",
        "...........X..X...",
        "..........XXXXXX..",
        ".......XXXXXXXXXX.",
        ".....XXXXXXXXXXXX.",
        "....XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "..X.XXXXXXXXXXXXX.",
        "...XXXXXXXXXXXXXX.",
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

// MARK: - Validation (fail loudly before writing anything)

let expectedNames = (0..<5).map { "run\($0)" } + (0..<3).map { "sleep\($0)" } + (0..<2).map { "sit\($0)" }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render_frames: ERROR: " + message + "\n").utf8))
    exit(1)
}

guard frames.map(\.name) == expectedNames else {
    fail("frame names/order must be exactly \(expectedNames), got \(frames.map(\.name))")
}

for frame in frames {
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
        // 1px breathing room: the outer ring must be fully transparent.
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

// MARK: - Write Resources/frames/

// Resolve the repo root from the script's own path so this works from any cwd.
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

for frame in frames {
    for (suffix, scale) in [("", 1), ("@2x", 2)] {
        let data = encodePNG(
            width: canvas * scale,
            height: canvas * scale,
            rgba: rasterize(grid: frame.grid, scale: scale)
        )
        let url = outputDirectory.appendingPathComponent("\(frame.name)\(suffix).png")
        do {
            try data.write(to: url)
        } catch {
            fail("could not write \(url.path): \(error)")
        }
        print("wrote \(url.lastPathComponent) (\(data.count) bytes, \(canvas * scale)x\(canvas * scale))")
    }
}
print("render_frames: \(frames.count) frames -> \(outputDirectory.path)")
