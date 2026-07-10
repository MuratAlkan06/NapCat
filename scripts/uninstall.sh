#!/bin/bash
# NapCat privileged uninstall — v0.3.
#
# USER-RUN ONLY, as root:   sudo ./scripts/uninstall.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Idempotent — safe to run any number of times, including when setup.sh was
# never run. Restores stock power behavior (sleep + charging), removes the
# sudoers entries and /usr/local/napcat.
#
# Structure (P2 security-review carryover): steps COLLECT errors instead of
# aborting — the sudoers file and /usr/local/napcat are removed even when the
# pmset or smc steps fail. Charging is re-enabled via the installed smc
# BEFORE the binary is deleted. P5 adds LaunchAgent removal here.

set -uo pipefail  # deliberately NOT -e: every step must be attempted

SUDOERS_FILE="/etc/sudoers.d/napcat"
SMC_DIR="/usr/local/napcat"
SMC_BIN="$SMC_DIR/smc"
FAILURES=()

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo ./scripts/uninstall.sh" >&2
    exit 1
fi

# 1. Restore stock sleep behavior (harmless no-op if already 0).
if /usr/bin/pmset -a disablesleep 0; then
    echo "ok: disablesleep cleared (pmset -a disablesleep 0)"
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
    else
        if "$SMC_BIN" -k CHTE -w 00000000; then
            echo "ok: charging re-enabled (CHTE cleared)"
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
    else
        FAILURES+=("could not remove $SMC_DIR")
    fi
else
    echo "ok: $SMC_DIR not present — nothing to remove"
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
