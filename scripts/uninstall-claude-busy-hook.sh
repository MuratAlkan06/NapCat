#!/bin/bash
# NapCat "Claude is busy" hook uninstaller (Track B, slice B1).
#
# USER-RUN, sudo-free:   ./scripts/uninstall-claude-busy-hook.sh
# Agents must NEVER run this and must NEVER edit ~/.claude/settings.json.
#
# Removes the installed hook file and the marker directory, and PRINTS the
# registration lines to delete by hand. Idempotent and error-collecting — safe
# to run any number of times, including when nothing was installed. This
# uninstaller NEVER edits settings.json.

umask 022

HOOK_DEST="$HOME/.claude/hooks/napcat-busy-hook.sh"
MARKER_DIR="$HOME/Library/Application Support/NapCat/claude-busy"
FAILURES=()

# 1. Remove the installed hook file.
if [ -f "$HOOK_DEST" ]; then
    if rm -f "$HOOK_DEST"; then
        echo "removed: $HOOK_DEST"
    else
        FAILURES+=("could not remove $HOOK_DEST")
    fi
else
    echo "ok: $HOOK_DEST not present — nothing to remove"
fi

# 2. Remove the marker directory (markers, hook.log, DISABLED flag, temps).
if [ -d "$MARKER_DIR" ]; then
    if rm -rf "$MARKER_DIR"; then
        echo "removed: $MARKER_DIR"
    else
        FAILURES+=("could not remove $MARKER_DIR")
    fi
else
    echo "ok: $MARKER_DIR not present — nothing to remove"
fi

cat <<'NOTE'

Now DELETE the NapCat hook entries from ~/.claude/settings.json by hand
(this uninstaller never edits that file). Remove the five entries whose
command runs ".../napcat-busy-hook.sh":

  "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "Notification"

If those events have no other hooks, remove the whole key. Restart Claude
Code afterwards so the removal takes effect.
NOTE

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "" >&2
    echo "uninstall finished WITH ERRORS:" >&2
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "Done. NapCat's Claude detection hook is removed."
exit 0
