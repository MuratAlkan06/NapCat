#!/bin/bash
# NapCat "Claude is busy" companion hook (Track B, slices B1 + B3).
#
# Registered in ~/.claude/settings.json for six events and maintains a
# per-session "work is in flight" marker under
#   $HOME/Library/Application Support/NapCat/claude-busy/<session_id>
# NapCat READS these markers; it never sends anything. This script only writes
# its own state directory.
#
# UserPromptSubmit SETS the marker. The turn-ending / idle events
# (Stop, StopFailure, SessionEnd, Notification and — B3 — SubagentStop)
# RECONCILE it: if the hook payload's `background_tasks` array still holds any
# element with status "running" (a background SUBAGENT is still working after
# the main turn ended), the marker is KEPT; otherwise it is cleared. This fixes
# the orchestrator-plus-background-subagents case where the main Stop fired
# while work was still in flight. `background_tasks` rides on Stop and on
# SubagentStop (empirically confirmed on this machine); an absent, non-array or
# unparseable field is treated as NONE running (fail toward the original
# clear-on-Stop behavior — never a crash).
#
# HARD UX-SAFETY LAYERS (a buggy hook must never be able to break the user's
# Claude Code experience — lint-enforced by ClaudeBusyHookScriptTests):
#   * FORCED EXIT 0 on every path. All work happens in main(); the file ends
#     with an unconditional `exit 0`, and there is no bare non-zero exit
#     anywhere. A non-zero status (a value of 2 in particular) would BLOCK the
#     user's prompt / force a turn to continue — impossible from here.
#   * STDOUT IS SILENCED before any logic runs (exec >/dev/null): Claude injects
#     a command hook's stdout into the model context, so nothing here may print
#     to stdout. Diagnostics go to a private hook.log, never stdout.
#   * NO errexit is ever enabled; no network calls; no waiting/blocking.
#   * Layer 6 KILL SWITCH: the FIRST action checks for a DISABLED flag and, if
#     present, no-ops immediately.
#   * Layer 4 FIRE-AND-FORGET: the marker write is backgrounded and atomic, so
#     a stalled filesystem cannot delay the prompt; the script returns at once.
#
# REGISTRATION MUST BE EXEC FORM (the security control): the installer prints
#   /usr/bin/env -i HOME=<home> /bin/bash <this script>
# `env -i` strips $BASH_ENV and every exported BASH_FUNC_* function before bash
# starts, closing the pre-interpreter code-execution hole that a bare
# shell-form script path would reopen (the [redacted-tool] A5/A8 lesson). A side
# effect of env -i is that the agent manager's env vars are stripped, so `src` is
# best-effort (recorded `unknown` when SUPERCONDUCTOR_MANAGED_AGENT is absent);
# `src` is DEBUG-ONLY and never a policy input.
#
# Stock macOS only: bash 3.2, plutil, date, stat, mktemp, head, grep. No jq,
# no sudo.

umask 077

# Untrusted inherited PATH: pin it so every bare-name call resolves to a stock
# binary, not something planted ahead of it.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Silence stdout (and stderr) before anything runs: nothing this hook emits can
# reach Claude's context. Diagnostics are appended to hook.log by explicit path.
exec >/dev/null 2>&1

STATE_DIR="$HOME/Library/Application Support/NapCat/claude-busy"
DISABLED_FLAG="$STATE_DIR/DISABLED"
LOG_FILE="$STATE_DIR/hook.log"
CAP=43200
SESSION_RE='^[0-9a-f][0-9a-f-]{7,63}$'
MAX_STDIN=262144
NL=$'\n'
CR=$'\r'

# Layer 6 — kill switch. FIRST action: if the user paused detection, do nothing
# (no reads, no writes, no log) and succeed. Placed before every write in the
# file so it can never be bypassed.
if [ -e "$DISABLED_FLAG" ]; then
  exit 0
fi

log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Same rules as the Swift side: lowercase-hex-and-dash, 8-64 chars, no newline
# or CR (path-traversal / log-forgery guard). Only names passing this are read,
# written or swept.
valid_session() {
  case "${1:-}" in
    ""|*"$NL"*|*"$CR"*) return 1 ;;
  esac
  [[ ${1:-} =~ $SESSION_RE ]]
}

# Layer 4 — atomic, fire-and-forget marker write. Called BACKGROUNDED so a
# stalled filesystem cannot delay the prompt. mktemp in the SAME directory + mv
# is a rename(2), so a reader never sees a half-written marker.
#   $1 dest  $2 ts  $3 event  $4 src
write_marker() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.marker.XXXXXX" 2>/dev/null) || return 0
  printf 'v1 ts=%s event=%s pid=%s src=%s\n' "$2" "$3" "$PPID" "$4" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# Every invocation sweeps siblings older than the 12h cap. Only session-id-
# shaped names are ever considered, so hook.log, DISABLED and the dot-prefixed
# temp files are never touched.
#   $1 now (unix epoch)
sweep_markers() {
  local f base mtime age
  for f in "$STATE_DIR"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    valid_session "$base" || continue
    mtime=$(stat -f %m "$f" 2>/dev/null) || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    age=$(( $1 - mtime ))
    [ "$age" -gt "$CAP" ] && rm -f "$f" 2>/dev/null
  done
}

# B3 — read-only background-task probe. Claude Code's Stop / SubagentStop hook
# payloads carry a `background_tasks` array; while an orchestrator's background
# SUBAGENT is still running after the main turn ended, that array holds an
# element with status "running". Extract it with plutil (no jq) and scan for the
# exact `"status":"running"` token. The closing quote is REQUIRED so neighbours
# like "not_running", "running_slow" or "agent_status" can never false-positive,
# and any interior quote in a hostile string value is backslash-escaped by
# plutil so it cannot forge the token. Absent / non-array / unparseable
# background_tasks ⇒ non-zero ⇒ treated as NONE running (fail toward clear).
#   $1 payload file
has_running_background_task() {
  local tasks
  tasks=$(plutil -extract background_tasks json -o - "$1" 2>/dev/null) || return 1
  printf '%s' "$tasks" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"'
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null

  local now src payload event session marker bg_running
  now=$(date +%s)
  src=unknown
  [ -n "${SUPERCONDUCTOR_MANAGED_AGENT:-}" ] && src=sc

  sweep_markers "$now"

  # Size-cap stdin before parsing (mirror the [redacted-tool] stdin bound).
  payload=$(mktemp "$STATE_DIR/.payload.XXXXXX" 2>/dev/null) || return 0
  head -c "$MAX_STDIN" >"$payload" 2>/dev/null
  if ! plutil -convert xml1 -o /dev/null "$payload" 2>/dev/null; then
    rm -f "$payload" 2>/dev/null
    log "ignore reason=stdin-not-json"
    return 0
  fi
  event=$(plutil -extract hook_event_name raw -o - "$payload" 2>/dev/null) || event=""
  session=$(plutil -extract session_id raw -o - "$payload" 2>/dev/null) || session=""
  bg_running=no
  has_running_background_task "$payload" && bg_running=yes
  rm -f "$payload" 2>/dev/null

  if ! valid_session "$session"; then
    log "ignore reason=bad-session event=${event:-?}"
    return 0
  fi

  marker="$STATE_DIR/$session"
  case "${event:-}" in
    UserPromptSubmit)
      ( write_marker "$marker" "$now" "$event" "$src" ) &
      log "set session=$session pid=$PPID src=$src"
      ;;
    Stop|StopFailure|SessionEnd|Notification|SubagentStop)
      # Reconcile: a still-running background subagent keeps the session busy
      # (work in flight); otherwise the turn is done and the marker is cleared.
      if [ "$bg_running" = yes ]; then
        ( write_marker "$marker" "$now" "$event" "$src" ) &
        log "keep session=$session event=$event reason=background-task-running pid=$PPID src=$src"
      else
        rm -f "$marker" 2>/dev/null
        log "clear session=$session event=$event"
      fi
      ;;
    *)
      log "ignore reason=unhandled-event event=${event:-?}"
      ;;
  esac
  return 0
}

main
exit 0
