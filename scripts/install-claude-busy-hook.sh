#!/bin/bash
# NapCat "Claude is busy" hook installer (Track B, slice B1).
#
# USER-RUN, sudo-free:   ./scripts/install-claude-busy-hook.sh
# Agents must NEVER run this and must NEVER edit ~/.claude/settings.json.
#
# What it does:
#   1. copies claude-busy-hook.sh to the STABLE path
#      ~/.claude/hooks/napcat-busy-hook.sh (NOT under dist/, so `make clean`
#      never removes it) and chmods it 755;
#   2. creates the marker directory 700 if absent;
#   3. PRINTS the exact EXEC-FORM registration JSON to paste into
#      ~/.claude/settings.json BY HAND. This installer NEVER edits settings.json.
#
# EXEC FORM is the security control: `/usr/bin/env -i HOME=<home> /bin/bash
# <script>` strips $BASH_ENV and every exported BASH_FUNC_* before bash starts.
# Registering the bare script path (shell form) would reopen that
# pre-interpreter code-execution hole (the [redacted-tool] A5/A8 lesson), so the
# printed registration is exec form only.

umask 022

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/claude-busy-hook.sh"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_DEST="$HOOK_DIR/napcat-busy-hook.sh"
MARKER_DIR="$HOME/Library/Application Support/NapCat/claude-busy"

if [ ! -f "$SRC" ]; then
    echo "error: $SRC not found — run this from the NapCat checkout." >&2
    exit 1
fi

mkdir -p "$HOOK_DIR" || { echo "error: could not create $HOOK_DIR" >&2; exit 1; }
if ! /usr/bin/install -m 755 "$SRC" "$HOOK_DEST"; then
    echo "error: could not install the hook to $HOOK_DEST" >&2
    exit 1
fi
echo "installed: $HOOK_DEST (755)"

mkdir -p "$MARKER_DIR" && chmod 700 "$MARKER_DIR"
echo "ready:     $MARKER_DIR (700)"

# The exec-form command object, verbatim, with this user's absolute paths.
EXEC_CMD='{"type":"command","command":"/usr/bin/env","args":["-i","HOME='"$HOME"'","/bin/bash","'"$HOOK_DEST"'"],"timeout":5}'

cat <<JSON

Add these six entries to the "hooks" object in ~/.claude/settings.json
(merge with any existing hooks; do not remove yours). Paste EXACTLY — the
exec form (/usr/bin/env -i …) is a security requirement, not cosmetic:

  "UserPromptSubmit": [ { "hooks": [ $EXEC_CMD ] } ],
  "Stop": [ { "hooks": [ $EXEC_CMD ] } ],
  "StopFailure": [ { "hooks": [ $EXEC_CMD ] } ],
  "SubagentStop": [ { "hooks": [ $EXEC_CMD ] } ],
  "SessionEnd": [ { "hooks": [ $EXEC_CMD ] } ],
  "Notification": [ { "matcher": "idle_prompt", "hooks": [ $EXEC_CMD ] } ]

JSON

echo "UPDATE: SubagentStop is NEW in this version. If you registered an earlier"
echo "        NapCat hook, ADD the SubagentStop entry above — it keeps NapCat"
echo "        'busy' while a background subagent is still running after the main"
echo "        turn ends. A NEW Claude Code session is needed to load it."
echo "NOTE: hooks load at session start — open a NEW Claude Code session for"
echo "      this to take effect. Pause anytime by creating:"
echo "          $MARKER_DIR/DISABLED"
echo "      (or use NapCat's menu → Pause detection). Remove with"
echo "      scripts/uninstall-claude-busy-hook.sh."
exit 0
