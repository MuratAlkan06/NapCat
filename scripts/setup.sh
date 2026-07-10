#!/bin/bash
# NapCat privileged setup — v0.3 (stay-awake + charge limiting).
#
# USER-RUN ONLY, as root:   sudo ./scripts/setup.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Installs:
#   - /usr/local/napcat/smc   (root:wheel 755; expects the caller to have run
#     `make smc` — validates dist/smc exists and is an arm64 Mach-O; NOPASSWD
#     targets must never be user-writable, which is why the bundle path is
#     not used)
#   - /etc/sudoers.d/napcat   (0440 root:wheel) with EXACTLY the eight
#     exact-argument entries from PLAN.md §4, scoped to the invoking user.
#
# On Intel Macs only the two pmset entries are installed — charge limiting is
# Apple Silicon-only in v1 (PLAN.md locked decision); Stay Awake still works.
#
# Idempotent — safe to re-run. P5 will extend this script with the
# com.napcat.failsafe LaunchAgent (crash-failsafe layer c).

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/napcat"
SMC_DIR="/usr/local/napcat"
SMC_DEST="$SMC_DIR/smc"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMC_SRC="$REPO_ROOT/dist/smc"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo ./scripts/setup.sh" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "error: could not determine the invoking user (SUDO_USER unset or root)." >&2
    echo "       Run via sudo from your own account, not from a root shell." >&2
    exit 1
fi
# Security hardening (P2 review carryover): the value lands inside a sudoers
# rule, so it must look like a real macOS short name AND actually exist.
if ! printf '%s' "$TARGET_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    echo "error: SUDO_USER '$TARGET_USER' is not a valid macOS short user name — refusing." >&2
    exit 1
fi
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "error: user '$TARGET_USER' does not exist on this system — refusing." >&2
    exit 1
fi

# Apple Silicon detection — same source of truth as the app (ADR §9):
# hw.optional.arm64 missing (Intel) or 0 → no charge limiting.
IS_ARM64="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"

if [ "$IS_ARM64" = "1" ]; then
    # --- smc helper (charge limiting) ---
    if [ ! -f "$SMC_SRC" ]; then
        echo "error: $SMC_SRC not found — run 'make smc' (or plain 'make') first." >&2
        exit 1
    fi
    if ! /usr/bin/file "$SMC_SRC" | grep -q "Mach-O 64-bit executable arm64"; then
        echo "error: $SMC_SRC is not an arm64 Mach-O executable:" >&2
        /usr/bin/file "$SMC_SRC" >&2
        exit 1
    fi
    /usr/bin/install -d -m 755 -o root -g wheel "$SMC_DIR"
    if [ -f "$SMC_DEST" ] && cmp -s "$SMC_SRC" "$SMC_DEST"; then
        echo "ok: $SMC_DEST already up to date — nothing changed."
    else
        /usr/bin/install -m 755 -o root -g wheel "$SMC_SRC" "$SMC_DEST"
        echo "installed: $SMC_DEST (755 root:wheel)"
    fi
else
    echo "note: Intel Mac detected — charge limiting is unavailable in v1;"
    echo "      installing the stay-awake (pmset) entries only."
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Exact-argument entries — the app execs these argv strings verbatim
# (PLAN.md §4, locked by PrivilegedCommandTests). Do not reword.
{
    cat <<EOF
# NapCat privileged commands (v0.3).
# Managed by NapCat scripts/setup.sh — do not edit by hand.
# Remove with: sudo ./scripts/uninstall.sh
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
EOF
    if [ "$IS_ARM64" = "1" ]; then
        cat <<EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 02
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 02
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 01000000
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 00
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 00
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 00000000
EOF
    fi
} > "$TMP"

if ! /usr/sbin/visudo -cf "$TMP"; then
    echo "error: generated sudoers file failed visudo validation — aborting, nothing installed." >&2
    exit 1
fi

if [ -f "$SUDOERS_FILE" ] && cmp -s "$TMP" "$SUDOERS_FILE"; then
    echo "ok: $SUDOERS_FILE already up to date for user '$TARGET_USER' — nothing changed."
else
    /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"
    echo "installed: $SUDOERS_FILE (0440 root:wheel)"
fi

echo "User '$TARGET_USER' may now run without a password:"
grep "^$TARGET_USER" "$SUDOERS_FILE" | sed -e "s/^$TARGET_USER ALL=(root) NOPASSWD: /    /"
echo "NapCat is ready — reopen the menu (no app restart needed for charge limiting)."
echo "Verify with:"
echo "    sudo -n /usr/bin/pmset -a disablesleep 0 && echo OK"
if [ "$IS_ARM64" = "1" ]; then
    echo "    $SMC_DEST -k CHTE -r    # unprivileged read must print the key"
fi
