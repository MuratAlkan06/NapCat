#!/bin/bash
# NapCat privileged uninstall — v0.2 subset (stay-awake only).
#
# USER-RUN ONLY, as root:   sudo ./scripts/uninstall.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Idempotent — safe to run any number of times, including when setup.sh was
# never run. Restores stock sleep behavior and removes the sudoers entries.
#
# P5 will extend this script with: charging re-enable via smc, LaunchAgent
# removal, and /usr/local/napcat removal.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/napcat"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo ./scripts/uninstall.sh" >&2
    exit 1
fi

# Restore stock sleep behavior (harmless no-op if already 0).
/usr/bin/pmset -a disablesleep 0
echo "ok: disablesleep cleared (pmset -a disablesleep 0)"

if [ -f "$SUDOERS_FILE" ]; then
    rm -f "$SUDOERS_FILE"
    echo "removed: $SUDOERS_FILE"
else
    echo "ok: $SUDOERS_FILE not present — nothing to remove"
fi

echo "Done. NapCat's privileged setup is removed; the app will show 'Setup Required' if used again."
