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

/// How the rows change once the list is on screen (a push while the app is
/// open, a refresh): only the arriving row moves. It fades in and rises by
/// the theme's entrance offset, on the theme's entrance curve, like the
/// first entrance without the stagger. The curve rides on the row's own
/// transition, so nothing else in that update animates: rows already
/// listed step to their new places whole, and their text never
/// cross-fades. Under Reduce Motion nothing moves: the identity transition
/// and no curve, so a new row is simply there.
enum ListMotion {
    /// The curve an arriving row moves on; nil under Reduce Motion.
    static func animation(_ theme: Theme, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : theme.entrance
    }

    /// How far a new row rises while it fades in; nil under Reduce Motion.
    static func rise(_ theme: Theme, reduceMotion: Bool) -> CGFloat? {
        reduceMotion ? nil : theme.entranceOffset
    }

    /// A row's insertion (and removal, its reverse), carrying its own curve.
    @MainActor static func transition(_ theme: Theme, reduceMotion: Bool) -> AnyTransition {
        guard let rise = rise(theme, reduceMotion: reduceMotion) else { return .identity }
        return AnyTransition(ArrivingRow(rise: rise).animation(animation(theme, reduceMotion: reduceMotion)))
    }

    /// The arriving row: transparent and `rise` lower until it is in place.
    /// The rise is a drawing offset, not a layout one: with no animation in
    /// the update itself, a layout `.offset` in a transition does not follow
    /// the transition's own curve (the row faded in but never rose, iOS
    /// 27.2 simulator), while a drawing offset does, as opacity does.
    struct ArrivingRow: Transition {
        let rise: CGFloat

        func body(content: Content, phase: TransitionPhase) -> some View {
            let lowered = phase.isIdentity ? 0 : rise
            return content
                .opacity(phase.isIdentity ? 1 : 0)
                .visualEffect { effect, _ in effect.offset(y: lowered) }
        }
    }

    /// A row's stacking order: each row draws over the rows below it, so a
    /// row rising into its place passes over its lower neighbor, not under.
    static func stacking(index: Int) -> Double {
        -Double(index)
    }
}
