#!/bin/bash
# NapCat privileged uninstall — v1.0.
#
# USER-RUN ONLY, as root:   sudo ./scripts/uninstall.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Idempotent — safe to run any number of times, including when setup.sh was
# never run. Restores stock power behavior (sleep + charging), removes the
# sudoers entries, /usr/local/napcat, the com.napcat.failsafe LaunchAgent, and
# the app's own settings (the com.muratalkan.napcat defaults domain — which
# holds the ntfy topic, a bearer credential for the alert feed).
#
# Structure (P2 security-review carryover): steps COLLECT errors instead of
# aborting — the sudoers file, /usr/local/napcat, and the LaunchAgent are
# removed even when the pmset or smc steps fail. Charging is re-enabled via
# the installed smc BEFORE the binary is removed — and only after the
# helper's path is re-checked as root-owned (otherwise that one step is
# skipped and reported).

set -uo pipefail  # deliberately NOT -e: every step must be attempted
# Pinned PATH + umask: sudo is not guaranteed to reset the caller's PATH (no
# secure_path by default), so a user-writable PATH entry could otherwise
# hijack a bare rm/id/grep run as root here.
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

SUDOERS_FILE="/etc/sudoers.d/napcat"
SMC_DIR="/usr/local/napcat"
SMC_BIN="$SMC_DIR/smc"
AGENT_LABEL="com.napcat.failsafe"
DEFAULTS_DOMAIN="com.muratalkan.napcat"
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
#    The helper runs AS ROOT here, so first re-check what setup.sh checked at
#    install time: /usr/local, the helper directory and the binary must each
#    be root-owned, not group/other-writable, and not a symlink. If anything
#    fails, ONLY this step is skipped (with a collected failure); every later
#    step still runs.
#    Prints the first problem found; prints nothing when the path is trusted.
smc_helper_trust_problem() {
    local path owner perms
    for path in /usr/local "$SMC_DIR" "$SMC_BIN"; do
        if [ -L "$path" ]; then
            echo "$path is a symlink"
            return 0
        fi
        owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" || owner=""
        perms="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" || perms=""
        case "$owner" in
            ''|*[!0-9]*) echo "$path could not be inspected"; return 0 ;;
        esac
        case "$perms" in
            ''|*[!0-7]*) echo "$path could not be inspected"; return 0 ;;
        esac
        if [ "$owner" -ne 0 ]; then
            echo "$path is not owned by root (uid $owner)"
            return 0
        fi
        if [ $(( 8#$perms & 8#022 )) -ne 0 ]; then
            echo "$path is group- or other-writable (mode $perms)"
            return 0
        fi
    done
    return 0
}
SMC_TRUST_PROBLEM=""
if [ -x "$SMC_BIN" ] || [ -L "$SMC_BIN" ]; then
    SMC_TRUST_PROBLEM="$(smc_helper_trust_problem)"
fi
if [ -n "$SMC_TRUST_PROBLEM" ]; then
    FAILURES+=("$SMC_TRUST_PROBLEM — refused to run $SMC_BIN as root, so charging was NOT re-enabled; it may stay paused until reboot. Inspect with: ls -ld /usr/local $SMC_DIR $SMC_BIN")
elif [ -x "$SMC_BIN" ]; then
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
    AGENT_DIR="$TARGET_HOME/Library/LaunchAgents"
    AGENT_FILE="$AGENT_DIR/$AGENT_LABEL.plist"
    /bin/launchctl bootout "gui/$TARGET_UID/$AGENT_LABEL" >/dev/null 2>&1 || true
    # Same boundary as setup.sh (audit F2, 2026-10-19): everything under the
    # user's home is user-controlled, so root never acts through it — refuse a
    # symlinked ~/Library or ~/Library/LaunchAgents, and delete AS the user.
    if [ -n "$TARGET_HOME" ] && { [ -L "$TARGET_HOME/Library" ] || [ -L "$AGENT_DIR" ]; }; then
        FAILURES+=("$TARGET_HOME/Library or $AGENT_DIR is a symlink — refusing to remove the LaunchAgent through it; check it and remove $AGENT_LABEL.plist by hand")
    elif [ -n "$TARGET_HOME" ] && [ -f "$AGENT_FILE" ]; then
        if /usr/bin/sudo -u "$TARGET_USER" /bin/rm -f "$AGENT_FILE"; then
            echo "removed: $AGENT_FILE"
            REVERTED+=("failsafe LaunchAgent removed ($AGENT_FILE)")
        else
            FAILURES+=("could not remove $AGENT_FILE")
        fi
    else
        echo "ok: failsafe LaunchAgent not present for '$TARGET_USER' — nothing to remove"
    fi

    # 6. Remove the app's own settings (per-user defaults domain).
    #    WHY THIS IS A SECURITY STEP, not just tidiness: the lid-alert setting
    #    `lidGuardNtfyTopic` is a BEARER CREDENTIAL — on ntfy there are no
    #    accounts, so whoever knows the topic name can read and post to that
    #    feed. Leaving it behind after an uninstall leaves a live credential in
    #    the preferences plist. The value is never printed here (every read is
    #    redirected to /dev/null); it is deleted, not inspected.
    #    Run in the user's own context via `launchctl asuser`, because defaults
    #    talk to that user's cfprefsd — root's own domain is a different one.
    if /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \
        /usr/bin/defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
        if /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" \
            /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
            echo "removed: $DEFAULTS_DOMAIN settings (including the ntfy topic)"
            REVERTED+=("NapCat settings removed (defaults domain $DEFAULTS_DOMAIN, including the ntfy topic)")
        else
            FAILURES+=("could not remove the $DEFAULTS_DOMAIN defaults domain — as '$TARGET_USER' run: defaults delete $DEFAULTS_DOMAIN")
        fi
    else
        echo "ok: no $DEFAULTS_DOMAIN settings for '$TARGET_USER' — nothing to remove"
    fi
    # cfprefsd may leave the (now empty) plist behind; drop it too — as the
    # user, so a symlink under their home can only reach their own files.
    DEFAULTS_PLIST="$TARGET_HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
    if [ -n "$TARGET_HOME" ] && [ -f "$DEFAULTS_PLIST" ]; then
        /usr/bin/sudo -u "$TARGET_USER" /bin/rm -f "$DEFAULTS_PLIST" || FAILURES+=("could not remove $DEFAULTS_PLIST")
    fi
else
    FAILURES+=("could not determine the invoking user — if present, remove ~/Library/LaunchAgents/$AGENT_LABEL.plist and run 'defaults delete $DEFAULTS_DOMAIN' manually")
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
