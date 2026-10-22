#!/bin/bash
# napcat-hook-version: 4
# NapCat "Claude is busy" companion hook (Track B, slices B1 + B3; Track C, C1;
# B-2).
#
# The version stamp above is machine-read: NapCat reads only the first 1 KiB
# of the INSTALLED copy and compares the stamp with the version it expects
# (ClaudeBusyConstants.hookVersion, parity-linted), so the menu can say when
# the installed copy is out of date. Keep it on line 2; bump it whenever this
# script's behavior changes.
#
# Registered in ~/.claude/settings.json for six events and maintains a
# per-session "work is in flight" marker under
#   $HOME/Library/Application Support/NapCat/claude-busy/<session_id>
# NapCat only READS these markers (it never writes one). The pushes the app
# sends (the lid alert, session alerts) are built from the app's own state in
# a closed vocabulary — no marker content ever reaches a message. This script
# sends nothing and only writes its own state directory.
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
# C1 — a Notification is reconciled by its `notification_type` FIRST (the
# Notification entry is registered WITHOUT a matcher so every type arrives):
#   * WAITING types (Claude is blocked on the user — a permission prompt, an
#     MCP elicitation, a background session needing input, a usage-limit wait
#     that will not continue on its own) KEEP the marker, rewritten with the
#     synthetic event token `waiting` so NapCat can tell "waiting on you" from
#     a background-task keep without new marker grammar;
#   * RESUME types (work continues — quota auto-resume fired, an elicitation
#     answered/completed) KEEP it with the real event name;
#   * everything else — the idle / auth / agent-completed types and ANY
#     unknown, missing, non-string or malformed type — falls through to the
#     B3 background-task check and otherwise CLEARS (the original behavior).
# The type is UNTRUSTED input: it must pass a strict whole-string check before
# it is matched or logged; a value failing it is logged only as `invalid`,
# never echoed.
#
# B-2 — the marker's event token ENCODES THE PHASE of the main turn:
#   IN-FLIGHT  = UserPromptSubmit, Notification, waiting
#   POST-STOP  = Stop, StopFailure, SessionEnd, SubagentStop, waiting-after-stop
# (A `SessionEnd` marker exists only when background work outlived the
# session: the main turn is over, so it is POST-STOP and the last subagent
# ending clears it.)
# A Notification or SubagentStop first reads the CURRENT marker's token
# (marker_phase; absent / unparseable / unlisted ⇒ "none") and reconciles by
# it: a SubagentStop while the main turn is IN FLIGHT (a foreground subagent
# finished) KEEPS the marker, rewritten as `Notification` — it never clears a
# running turn, and a waiting episode ends so a later wait can notify again;
# post-Stop it is B3 unchanged (keep while background work runs, else clear);
# with no marker it never creates one unless background work runs. A WAITING
# Notification after Stop writes `waiting-after-stop` (the phase survives the
# wait), a RESUME one writes `Stop`, and a background-task keep of any other
# Notification writes `Notification` in flight and `Stop` otherwise.
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
# Input and housekeeping hygiene:
#   * stdin is size-capped, then validated as JSON with
#     `plutil -convert json` — NOT `-convert xml1`, which rejects any JSON
#     `null` (plist has no null), so a nullable field added to a payload would
#     silently drop the whole event. A null-valued field reads as absent.
#   * The payload temp file is removed on every path; while it exists a trap
#     removes it on EXIT, and on TERM/INT removes it and exits 0 (a hook killed
#     at Claude's timeout never strands it, and still exits 0). The 60 s temp
#     sweep stays the backstop (SIGKILL cannot be trapped).
#   * hook.log is rotated before an append once it exceeds LOG_MAX bytes (one
#     generation kept, hook.log.1), so it never grows without bound.
#
# REGISTRATION MUST BE EXEC FORM (the security control): the installer prints
#   /usr/bin/env -i HOME=<home> /bin/bash <this script>
# `env -i` strips $BASH_ENV and every exported BASH_FUNC_* function before bash
# starts, closing the pre-interpreter code-execution hole that a bare
# shell-form script path would reopen. A side effect of env -i is that env vars
# set by other agent-session managers are stripped too, so `src` is
# best-effort (recorded `unknown` when SUPERCONDUCTOR_MANAGED_AGENT is absent);
# `src` is DEBUG-ONLY and never a policy input.
#
# Stock macOS only: bash 3.2, plutil, date, stat, mktemp, head, grep, tr. No
# jq, no sudo.

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
TMP_CAP=60
LOG_MAX=1048576
SESSION_RE='^[0-9a-f][0-9a-f-]{7,63}$'
NTYPE_RE='^[a-z_]{1,32}$'
EVENT_RE='^[A-Za-z]{1,32}$'
TOKEN_RE='^[A-Za-z-]{1,32}$'
MARKER_RE='^v1 ts=[0-9]+ event=([^ ]+)( |$)'
WAITING_EVENT=waiting
WAITING_AFTER_STOP_EVENT=waiting-after-stop
MAX_STDIN=262144
NL=$'\n'
CR=$'\r'

# Layer 6 — kill switch. FIRST action: if the user paused detection, do nothing
# (no reads, no writes, no log) and succeed. Placed before every write in the
# file so it can never be bypassed.
if [ -e "$DISABLED_FLAG" ]; then
  exit 0
fi

# Appends one diagnostics line. A log larger than LOG_MAX bytes (1 MiB) is
# first rotated to hook.log.1 (one generation, overwritten), so the pair stays
# bounded at about 2 MiB. Neither name is session-id shaped or a temp-file
# name, so the sweep never touches them.
log() {
  local size
  size=$(stat -f %z "$LOG_FILE" 2>/dev/null) || size=0
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -gt "$LOG_MAX" ] && mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
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

# The event name is UNTRUSTED too: only a plain-letters name (1-32 chars, no
# newline or CR) is ever written to hook.log; anything else is logged as
# `invalid`, never echoed (log-forgery guard on the two ignore paths).
valid_event() {
  case "${1:-}" in
    ""|*"$NL"*|*"$CR"*) return 1 ;;
  esac
  [[ ${1:-} =~ $EVENT_RE ]]
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
# temp files are never touched by that pass.
# A second pass removes this hook's own temp files (`.payload.*`, `.marker.*`)
# once they are older than TMP_CAP seconds: a run killed at Claude's 5 s hook
# timeout leaves its temp file behind, and nothing else would ever reclaim it.
# A live temp file normally exists for milliseconds (well inside that 5 s
# timeout), so the 60 s floor leaves a concurrent run's files alone. No other
# name is matched (never hook.log, never DISABLED).
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
  for f in "$STATE_DIR"/.payload.* "$STATE_DIR"/.marker.*; do
    [ -f "$f" ] || continue
    mtime=$(stat -f %m "$f" 2>/dev/null) || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    age=$(( $1 - mtime ))
    [ "$age" -gt "$TMP_CAP" ] && rm -f "$f" 2>/dev/null
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

# C1 — read-only, VALIDATED notification-type probe. Prints exactly one of:
#   * the type itself, iff it is a STRING passing the whole-string NTYPE_RE
#     check (lowercase letters and underscore, 1-32 chars);
#   * `invalid` — a string is present but fails that check (the raw value is
#     never printed, so it can never reach hook.log or a `case`);
#   * `?` — absent, not a string, or unparseable.
# `-expect string` makes plutil refuse every non-string (a dictionary would
# otherwise print its KEYS in raw form, an array its count). plutil's raw
# output ends in one newline; the `x` sentinel stops $(…) from also stripping
# a newline that is part of the VALUE, so a "permission_prompt<LF>" value
# fails the newline guard instead of silently passing as permission_prompt.
# bash 3.2 silently DROPS NUL bytes inside $(…), so a "permission\u0000_prompt"
# value would otherwise collapse into permission_prompt: every NUL is mapped to
# `#` first (a byte NTYPE_RE rejects ⇒ `invalid`). pipefail keeps plutil's own
# status as the pipeline's, so a non-string still takes the `?` branch.
# On failure plutil writes its error to stdout, so the capture is discarded.
#   $1 payload file
notification_type() {
  local t
  t=$( (set -o pipefail; plutil -extract notification_type raw -expect string -o - "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#') && printf x ) || { printf '?'; return 0; }
  t=${t%x}
  t=${t%"$NL"}
  case "$t" in
    *"$NL"*|*"$CR"*) printf invalid; return 0 ;;
  esac
  if [[ $t =~ $NTYPE_RE ]]; then
    printf '%s' "$t"
  else
    printf invalid
  fi
  return 0
}

# B-2 — read-only, VALIDATED phase probe of the CURRENT marker. Prints exactly
# one of `inflight`, `poststop` or `none`. Only a REGULAR file is read (a FIFO
# planted under the marker's name would block the read; `-f` refuses it), and
# at most 256 bytes of it. NULs are mapped to `#` first (bash 3.2 drops them
# inside $(…), which could splice a token together), only the first line is
# parsed, and the event token (the field after `v1 ts=…`) must pass the strict
# whole-string TOKEN_RE check. Absent, unparseable, or a token in neither
# phase list ⇒ `none`. The token itself is never printed or logged.
#   $1 marker path
marker_phase() {
  local line tok
  [ -f "$1" ] || { printf none; return 0; }
  line=$(head -c 256 "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#')
  line=${line%%"$NL"*}
  [[ $line =~ $MARKER_RE ]] || { printf none; return 0; }
  tok=${BASH_REMATCH[1]}
  case "$tok" in
    *"$CR"*) printf none; return 0 ;;
  esac
  [[ $tok =~ $TOKEN_RE ]] || { printf none; return 0; }
  case "$tok" in
    UserPromptSubmit|Notification|waiting)
      printf inflight ;;
    Stop|StopFailure|SessionEnd|SubagentStop|waiting-after-stop)
      printf poststop ;;
    *)
      printf none ;;
  esac
  return 0
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null

  local now src payload event logevent session marker bg_running ntype tclass tinfo phase pinfo token
  now=$(date +%s)
  src=unknown
  [ -n "${SUPERCONDUCTOR_MANAGED_AGENT:-}" ] && src=sc

  sweep_markers "$now"

  # Size-cap stdin before parsing (an oversized payload is truncated, never
  # read in full).
  payload=$(mktemp "$STATE_DIR/.payload.XXXXXX" 2>/dev/null) || return 0
  # While the payload exists: removed on EXIT; on TERM/INT removed, then exit
  # 0 (a trapped signal would otherwise RESUME the script). Cleared once the
  # payload is gone, so the rest of the run keeps the default dispositions.
  trap 'rm -f "$payload" 2>/dev/null' EXIT
  trap 'rm -f "$payload" 2>/dev/null; exit 0' TERM INT
  head -c "$MAX_STDIN" >"$payload" 2>/dev/null
  # JSON validity, not plist convertibility: `-convert xml1` rejects any JSON
  # null, so one nullable field would drop the whole event.
  if ! plutil -convert json -o /dev/null "$payload" 2>/dev/null; then
    rm -f "$payload" 2>/dev/null
    trap - EXIT TERM INT
    log "ignore reason=stdin-not-json"
    return 0
  fi
  event=$(plutil -extract hook_event_name raw -o - "$payload" 2>/dev/null) || event=""
  # The only form of the event name the ignore paths may log: `?` when absent,
  # the name itself when it passes valid_event, `invalid` otherwise.
  logevent=${event:-?}
  [ -n "$event" ] && ! valid_event "$event" && logevent=invalid
  session=$(plutil -extract session_id raw -o - "$payload" 2>/dev/null) || session=""
  bg_running=no
  has_running_background_task "$payload" && bg_running=yes
  # Only a Notification carries a type worth reading (no extra plutil process
  # on the latency-sensitive UserPromptSubmit path).
  ntype=""
  [ "$event" = Notification ] && ntype=$(notification_type "$payload")
  rm -f "$payload" 2>/dev/null
  trap - EXIT TERM INT

  if ! valid_session "$session"; then
    log "ignore reason=bad-session event=$logevent"
    return 0
  fi

  marker="$STATE_DIR/$session"
  case "${event:-}" in
    UserPromptSubmit)
      ( write_marker "$marker" "$now" "$event" "$src" ) &
      log "set session=$session pid=$PPID src=$src"
      ;;
    Stop|StopFailure|SessionEnd|Notification|SubagentStop)
      # C1 — classify a Notification by its (validated) type. Precedence:
      # waiting > resume > background-task keep (B3) > clear. Any other type
      # (idle_prompt, auth_success, agent_completed, unknown, `invalid`, `?`)
      # leaves tclass empty, so it falls through to the background-task check
      # and otherwise clears, as before C1.
      tclass=""
      tinfo=""
      if [ "$event" = Notification ]; then
        tinfo=" type=$ntype"
        case "$ntype" in
          permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|quota_auto_resume_stale|quota_auto_resume_disabled)
            tclass=waiting ;;
          quota_auto_resume_fired|elicitation_complete|elicitation_response)
            tclass=resume ;;
        esac
      fi
      # B-2 — a Notification or SubagentStop reconciles by the phase the
      # CURRENT marker encodes (Stop / StopFailure / SessionEnd do not need
      # it); only those two event lines carry `phase=`.
      phase=""
      pinfo=""
      if [ "$event" = Notification ] || [ "$event" = SubagentStop ]; then
        phase=$(marker_phase "$marker")
        pinfo=" phase=$phase"
      fi
      # Reconcile: a session blocked on the user, or whose work resumes, or
      # whose main turn is still in flight when a subagent ends, or with a
      # still-running background subagent stays busy (work in flight);
      # otherwise the turn is done and the marker is cleared. Precedence:
      # waiting > resume > main-turn-in-flight > background task > clear.
      if [ "$tclass" = waiting ]; then
        token=$WAITING_EVENT
        [ "$phase" = poststop ] && token=$WAITING_AFTER_STOP_EVENT
        ( write_marker "$marker" "$now" "$token" "$src" ) &
        log "keep session=$session event=$event$tinfo$pinfo reason=waiting-on-user pid=$PPID src=$src"
      elif [ "$tclass" = resume ]; then
        token=$event
        [ "$phase" = poststop ] && token=Stop
        ( write_marker "$marker" "$now" "$token" "$src" ) &
        log "keep session=$session event=$event$tinfo$pinfo reason=work-continues pid=$PPID src=$src"
      elif [ "$event" = SubagentStop ] && [ "$phase" = inflight ]; then
        ( write_marker "$marker" "$now" Notification "$src" ) &
        log "keep session=$session event=$event$pinfo reason=main-turn-in-flight pid=$PPID src=$src"
      elif [ "$bg_running" = yes ]; then
        token=$event
        if [ "$event" = Notification ] && [ "$phase" != inflight ]; then
          token=Stop
        fi
        ( write_marker "$marker" "$now" "$token" "$src" ) &
        log "keep session=$session event=$event$tinfo$pinfo reason=background-task-running pid=$PPID src=$src"
      elif [ "$event" = SubagentStop ] && [ "$phase" = none ]; then
        log "ignore reason=no-marker event=$event$pinfo"
      else
        rm -f "$marker" 2>/dev/null
        log "clear session=$session event=$event$tinfo$pinfo"
      fi
      ;;
    *)
      log "ignore reason=unhandled-event event=$logevent"
      ;;
  esac
  return 0
}

main
exit 0
