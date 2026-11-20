import SwiftUI

/// The list's entrance cadence (charter DNA): rows arrive 40 ms apart. Only
/// the first eight rows get their own step; every later row shares the
/// eighth row's delay, so the whole entrance finishes within 280 ms plus one
/// curve (the theme's, at most 0.3 s). Product behaviour, not style, so no
/// theme can change it.
enum StaggerTiming {
    static let step: Double = 0.040
    static let staggeredRows = 8

    static func delay(forIndex index: Int) -> Double {
        Double(min(max(index, 0), staggeredRows - 1)) * step
    }
}

/// Fades a row in and lifts it by the theme's offset, after its stagger
/// delay. It runs once per appearance of the screen: `revealed` goes true on
/// appear and false on disappear, and rows created later (scrolled into
/// view) are already revealed, so they appear plainly. Under Reduce Motion
/// the row is simply there, with no fade, no movement and no delay.
struct StaggeredEntrance: ViewModifier {
    let index: Int
    let revealed: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = revealed || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : theme.entranceOffset)
            .animation(
                reduceMotion ? nil : theme.entrance.delay(StaggerTiming.delay(forIndex: index)),
                value: revealed
            )
    }
}

extension View {
    func staggeredEntrance(index: Int, revealed: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, revealed: revealed))
    }
}
