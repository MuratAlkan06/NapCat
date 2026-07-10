/// Pure charge-limit hysteresis (PLAN.md ADR §7; normative transition table
/// in PLAN.md "Hysteresis transition table" — HysteresisEngineTests mirrors
/// it row for row).
///
/// The engine is a pure function: no I/O, no state of its own. The caller
/// (ChargeLimiter, P3b) owns `ChargingControlState` and must only advance it
/// via `nextState(after:from:)` AFTER the corresponding charge-control write
/// SUCCEEDED — a failed write keeps the old state and surfaces an error
/// (never a false "paused", ADR §2).

/// What the caller must do to the charge circuit right now.
enum ChargeCommand: Equatable, Sendable {
    case none
    case disableCharging
    case enableCharging
}

/// Whether NapCat currently holds charging inhibited ("paused at limit").
enum ChargingControlState: Equatable, Sendable {
    case normal
    case paused
}

enum HysteresisEngine {
    /// Resume band width: once paused, charging re-enables at ≤ limit−5.
    static let resumeDelta = 5

    /// Decide the charge command for one observation.
    ///
    /// Rules (closed form, see PLAN.md table):
    /// - normal → `.disableCharging` iff enabled ∧ adapter ∧ limit < 100
    ///   ∧ percent != nil ∧ percent ≥ limit; otherwise `.none`.
    /// - paused → `.none` iff enabled ∧ adapter ∧ limit < 100
    ///   ∧ percent != nil ∧ percent > limit − resumeDelta; otherwise
    ///   `.enableCharging` — EVERY path out of paused emits an explicit
    ///   re-enable (toggle off, unplug, limit raised past the band, unknown
    ///   percent, limit set to 100).
    /// - limit == 100 means "uncapped": never pause at full charge, and a
    ///   pause that exists when the limit becomes 100 is released.
    static func decide(
        percent: Int?,
        adapterConnected: Bool,
        limit: Int,
        enabled: Bool,
        currentState: ChargingControlState
    ) -> ChargeCommand {
        switch currentState {
        case .normal:
            guard enabled,                    // feature off → inert
                  adapterConnected,           // on battery nothing charges → no write
                  limit < 100,                // 100 = uncapped, never pause
                  let percent                 // unknown % → take no action
            else { return .none }
            return percent >= limit ? .disableCharging : .none

        case .paused:
            guard enabled else { return .enableCharging }          // toggle off while paused
            guard adapterConnected else { return .enableCharging } // unplugged while paused
            guard limit < 100 else { return .enableCharging }      // raised to uncapped
            guard let percent else { return .enableCharging }      // % unreadable — fail open
            return percent <= limit - resumeDelta ? .enableCharging : .none
        }
    }

    /// State the caller must adopt after the command's write SUCCEEDED
    /// (`.none` performs no write and keeps the state).
    static func nextState(
        after command: ChargeCommand,
        from state: ChargingControlState
    ) -> ChargingControlState {
        switch command {
        case .none: return state
        case .disableCharging: return .paused
        case .enableCharging: return .normal
        }
    }
}
