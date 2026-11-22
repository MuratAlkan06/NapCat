// swift-tools-version:6.0
import Foundation
import PackageDescription

// With Command Line Tools only (no Xcode.app), SwiftPM passes the toolchain's
// Developer/Frameworks directory as an import path (-I) instead of a framework
// search path (-F), so `import Testing` fails to resolve. Add the -F path
// explicitly when that directory exists; on machines with full Xcode the
// directory is absent and no flags are added. Test target only — the release
// binary is unaffected. See PLAN.md decision log 2026-07-09.
let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let hasCLTFrameworks = FileManager.default.fileExists(atPath: cltFrameworksPath)

let testSwiftSettings: [SwiftSetting] = hasCLTFrameworks
    ? [.unsafeFlags(["-F", cltFrameworksPath])]
    : []
let testLinkerSettings: [LinkerSetting] = hasCLTFrameworks
    ? [.unsafeFlags(["-F", cltFrameworksPath, "-Xlinker", "-rpath", "-Xlinker", cltFrameworksPath])]
    : []

let package = Package(
    name: "NapCat",
    // The iOS entry only states a floor for consumers of `NapCatWire` (the
    // NapCat Phone receiver, F3); it has no effect on the macOS build.
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        // The shared wire contract (CloudKit container, record types, field
        // keys, subscription IDs) and the pure F4 approval core (the gate
        // tables, the prompt lifecycle, the channel server's two wires) — the
        // one source of truth both apps import.
        .library(name: "NapCatWire", targets: ["NapCatWire"]),
        // F4: the channel server Claude Code spawns for a wired session
        // (slice S1). Built by `make`; not part of the app bundle yet.
        .executable(name: "napcat-channel", targets: ["NapCatChannel"]),
    ],
    targets: [
        // Constants and pure logic only: zero imports, no I/O — so it builds
        // for iOS too (WireContractTests locks both).
        .target(
            name: "NapCatWire"
        ),
        .executableTarget(
            name: "NapCat",
            dependencies: ["NapCatWire"]
        ),
        // macOS only, never linked by the phone app.
        .executableTarget(
            name: "NapCatChannel",
            dependencies: ["NapCatWire"]
        ),
        .testTarget(
            name: "NapCatTests",
            dependencies: ["NapCat", "NapCatChannel", "NapCatWire"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
