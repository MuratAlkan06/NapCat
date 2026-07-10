#!/bin/bash
# napcat-watchdog.sh — NapCat crash-failsafe layer (b), ADR §6 in PLAN.md.
#
# Usage: napcat-watchdog.sh <app-pid>
#
# Spawned by WatchdogController ONLY while stay-awake is enabled. Receives the
# app PID explicitly as $1 — NOT $PPID: the spawned child gets reparented to
# launchd when the app dies, so $PPID would be useless.
#
# Polls the app PID every 5 seconds; when the app is gone (crash, kill -9),
# reverts disablesleep via the exact sudoers-permitted argv, removes the
# pidfile, and exits. On a clean disable/quit the app SIGTERMs this script
# before the revert would ever run.

set -u

APP_PID="${1:-}"
PIDFILE="$HOME/Library/Application Support/NapCat/watchdog.pid"

if [ -z "$APP_PID" ]; then
    echo "usage: napcat-watchdog.sh <app-pid>" >&2
    exit 64
fi

while kill -0 "$APP_PID" 2>/dev/null; do
    sleep 5
done

# App died without a clean disable — revert stay-awake.
# This argv must byte-match /etc/sudoers.d/napcat (PLAN.md §4).
/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0

# ADR §6b: also re-enable charging, in case the app died while paused at the
# charge limit. Best effort — silent no-op when setup.sh has not installed
# the helper, and never blocks pidfile cleanup. CHTE first (modern key
# family); on failure fall back to CH0B/CH0C (older systems). All three argv
# strings must byte-match /etc/sudoers.d/napcat (PLAN.md §4).
if [ -x /usr/local/napcat/smc ]; then
    if ! /usr/bin/sudo -n /usr/local/napcat/smc -k CHTE -w 00000000; then
        /usr/bin/sudo -n /usr/local/napcat/smc -k CH0B -w 00 || true
        /usr/bin/sudo -n /usr/local/napcat/smc -k CH0C -w 00 || true
    fi
fi

rm -f "$PIDFILE"
exit 0
