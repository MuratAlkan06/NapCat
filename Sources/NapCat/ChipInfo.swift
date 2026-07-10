import Foundation

/// Chip detection per PLAN.md ADR §9: `sysctlbyname("hw.optional.arm64")`.
/// ENOENT (key absent, i.e. Intel) or value 0 → not Apple Silicon.
/// Never uname/arch — Rosetta lies about those.
enum ChipInfo {
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false // ENOENT → Intel
        }
        return value == 1
    }()
}
