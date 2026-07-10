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
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "NapCat"
        ),
        .testTarget(
            name: "NapCatTests",
            dependencies: ["NapCat"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
