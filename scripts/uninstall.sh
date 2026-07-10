#!/bin/bash
# NapCat privileged uninstall — v1.0.
#
# USER-RUN ONLY, as root:   sudo ./scripts/uninstall.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Idempotent — safe to run any number of times, including when setup.sh was
# never run. Restores stock power behavior (sleep + charging), removes the
# sudoers entries, /usr/local/napcat, and the com.napcat.failsafe
# LaunchAgent.
#
# Structure (P2 security-review carryover): steps COLLECT errors instead of
# aborting — the sudoers file, /usr/local/napcat, and the LaunchAgent are
# removed even when the pmset or smc steps fail. Charging is re-enabled via
# the installed smc BEFORE the binary is removed.

set -uo pipefail  # deliberately NOT -e: every step must be attempted

SUDOERS_FILE="/etc/sudoers.d/napcat"
SMC_DIR="/usr/local/napcat"
SMC_BIN="$SMC_DIR/smc"
AGENT_LABEL="com.napcat.failsafe"
FAILURES=()
REVERTED=()

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo ./scripts/uninstall.sh" >&2
    exit 1
fi

# 1. Restore stock sleep behavior (harmless no-op if already 0).
if /usr/bin/pmset -a disablesleep 0; then
    echo "ok: disablesleep cleared (pmset -a disablesleep 0)"
    REVERTED+=("sleep restored to stock behavior (disablesleep 0)")
else
    FAILURES+=("pmset -a disablesleep 0 failed — check 'pmset -g | grep SleepDisabled' manually")
fi

# 2. Re-enable charging while the helper still exists (same probe chain as
#    the app: CHTE unless the key reports "no data", then CH0B/CH0C).
if [ -x "$SMC_BIN" ]; then
    if "$SMC_BIN" -k CHTE -r 2>/dev/null | grep -q "no data"; then
        "$SMC_BIN" -k CH0B -w 00 || FAILURES+=("smc CH0B enable failed — charging may still be inhibited until reboot")
        "$SMC_BIN" -k CH0C -w 00 || FAILURES+=("smc CH0C enable failed — charging may still be inhibited until reboot")
        echo "ok: charging re-enabled (CH0B/CH0C cleared)"
        REVERTED+=("charging re-enabled (CH0B/CH0C cleared)")
    else
        if "$SMC_BIN" -k CHTE -w 00000000; then
            echo "ok: charging re-enabled (CHTE cleared)"
            REVERTED+=("charging re-enabled (CHTE cleared)")
        else
            FAILURES+=("smc CHTE enable failed — charging may still be inhibited until reboot")
        fi
    fi
else
    echo "ok: $SMC_BIN not present — no charging state to restore"
fi

# 3. Remove the sudoers entries — ALWAYS reached, even after failures above.
if [ -f "$SUDOERS_FILE" ]; then
    if rm -f "$SUDOERS_FILE"; then
        echo "removed: $SUDOERS_FILE"
        REVERTED+=("sudoers entries removed ($SUDOERS_FILE)")
    else
        FAILURES+=("could not remove $SUDOERS_FILE")
    fi
else
    echo "ok: $SUDOERS_FILE not present — nothing to remove"
fi

# 4. Remove the helper directory.
if [ -d "$SMC_DIR" ]; then
    if rm -rf "$SMC_DIR"; then
        echo "removed: $SMC_DIR"
        REVERTED+=("smc helper removed ($SMC_DIR)")
    else
        FAILURES+=("could not remove $SMC_DIR")
    fi
else
    echo "ok: $SMC_DIR not present — nothing to remove"
fi

# 5. Remove the failsafe LaunchAgent (installed per-user by setup.sh v1.0).
#    Best-effort bootout first — the agent is usually not loaded (it is a
#    RunAtLoad one-shot), and the gui domain may not exist in this context.
TARGET_USER="${SUDO_USER:-}"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] \
    && printf '%s' "$TARGET_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$' \
    && id -u "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/sed 's/^NFSHomeDirectory: //')"
    AGENT_FILE="$TARGET_HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
    /bin/launchctl bootout "gui/$TARGET_UID/$AGENT_LABEL" >/dev/null 2>&1 || true
    if [ -n "$TARGET_HOME" ] && [ -f "$AGENT_FILE" ]; then
        if rm -f "$AGENT_FILE"; then
            echo "removed: $AGENT_FILE"
            REVERTED+=("failsafe LaunchAgent removed ($AGENT_FILE)")
        else
            FAILURES+=("could not remove $AGENT_FILE")
        fi
    else
        echo "ok: failsafe LaunchAgent not present for '$TARGET_USER' — nothing to remove"
    fi
else
    FAILURES+=("could not determine the invoking user — if present, remove ~/Library/LaunchAgents/$AGENT_LABEL.plist manually")
fi

echo ""
if [ "${#REVERTED[@]}" -gt 0 ]; then
    echo "Reverted/removed by this run:"
    for line in "${REVERTED[@]}"; do
        echo "  - $line"
    done
else
    echo "Nothing needed reverting — system was already in stock state."
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "" >&2
    echo "uninstall finished WITH ERRORS:" >&2
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "Done. NapCat's privileged setup is removed; the app will show 'Setup Required' if used again."
