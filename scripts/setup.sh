#!/bin/bash
# NapCat privileged setup — v0.2 subset (stay-awake only).
#
# USER-RUN ONLY, as root:   sudo ./scripts/setup.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Installs /etc/sudoers.d/napcat with EXACTLY the two pmset entries from
# PLAN.md §4, scoped to the invoking user. Idempotent — safe to re-run.
#
# P5 will extend this script with:
#   - install of the vendored smc binary to /usr/local/napcat/smc (root:wheel)
#   - the six exact-argument smc sudoers entries
#   - the com.napcat.failsafe LaunchAgent (crash-failsafe layer c)

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/napcat"

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

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Exact-argument entries — the app execs these argv strings verbatim
# (PLAN.md §4, locked by PrivilegedCommandTests). Do not reword.
cat > "$TMP" <<EOF
# NapCat stay-awake privileged commands (v0.2 subset).
# Managed by NapCat scripts/setup.sh — do not edit by hand.
# Remove with: sudo ./scripts/uninstall.sh
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
EOF

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
echo "    /usr/bin/pmset -a disablesleep 1"
echo "    /usr/bin/pmset -a disablesleep 0"
echo "NapCat's Stay Awake toggle is ready. Verify with:"
echo "    sudo -n /usr/bin/pmset -a disablesleep 0 && echo OK"
