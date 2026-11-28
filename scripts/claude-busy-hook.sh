#!/bin/bash
# napcat-hook-version: 9
trap exit\ 0 EXIT
[ "$(/usr/bin/tail -n 1 "$0" 2>/dev/null)" = "exit 0" ] || exit 0; trap - EXIT
# NapCat "Claude is busy" companion hook (Track B, slices B1 + B3; Track C, C1;
# B-2).
#
# The version stamp above is machine-read: NapCat reads only the first 1 KiB
# of the INSTALLED copy and compares the stamp with the version it expects
# (ClaudeBusyConstants.hookVersion, parity-linted), so the menu can say when
# the installed copy is out of date. Keep it on line 2; bump it whenever this
# script's behavior changes. The two lines under it are the damaged-file
# guard (see HARD UX-SAFETY LAYERS below); keep them on lines 3 and 4.
#
# Registered in ~/.claude/settings.json for eight entries (six events, plus
# PreToolUse and PostToolUse matched to the AskUserQuestion tool — hook v9)
# and maintains a per-session "work is in flight" marker under
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
#     synthetic event token `waiting` (`waiting-question` while a question is
#     pending, hook v9) so NapCat can tell "waiting on you" from a
#     background-task keep without new marker grammar;
#   * RESUME types (work continues — quota auto-resume fired, an elicitation
#     answered/completed) KEEP it with the real event name;
#   * everything else — the idle / auth / agent-completed types and ANY
#     unknown, missing, non-string or malformed type — falls through to the
#     B3 background-task check; then, if the marker is POST-STOP (see B-2
#     below), it is IGNORED — the marker is left exactly as it is (hook v5);
#     otherwise it CLEARS (the original behavior).
# The type is UNTRUSTED input: it must pass a strict whole-string check before
# it is matched or logged; a value failing it is logged only as `invalid`,
# never echoed.
#
# Why a post-Stop CLEAR-class Notification never clears (hook v5): a marker
# that outlived its Stop exists only because background work was still
# running (or the session is `waiting-after-stop` on top of that). A
# Notification payload does NOT carry `background_tasks` — that array rides
# only on Stop and SubagentStop — so the B3 check above always reads "none
# running" for it and the else-clear would delete a marker whose background
# work is still in flight (an idle_prompt while a background subagent works
# did exactly that). Post-Stop clears belong to the turn-ending and subagent
# events — Stop, StopFailure, SessionEnd and SubagentStop (Stop and
# SubagentStop carry the task registry). In flight, a CLEAR-class
# Notification still clears (the missed-Stop safety valve); with no marker,
# the clear is a no-op.
#
# B-2 — the marker's event token ENCODES THE PHASE of the main turn:
#   IN-FLIGHT  = UserPromptSubmit, Notification, waiting, question,
#                waiting-question (the last two since hook v9)
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
# Notification writes `Notification` in flight and `Stop` otherwise; any other
# post-Stop Notification leaves the marker untouched (logged
# `reason=poststop-clear-notification`, hook v5 — see C1 above).
#
# Hook v7 — the marker's sixth field `ep` is the EPISODE START (epoch
# seconds): when the session became busy. A write that starts a NEW episode
# (no marker, or one without a usable `ep`) records this run's own clock; every
# in-episode rewrite (Notification, waiting, SubagentStop, a kept Stop, or a
# UserPromptSubmit while the marker persists) carries the existing value over,
# but only when it passes this script's own strict read (marker_episode).
# NapCat uses it for the run minutes, so a NapCat restart mid-run no longer
# re-anchors them. The phase probe below only reads the event token, so it
# is unaffected by the extra field.
#
# Hook v8 — a SILENT check of how a turn ended, counted in hook.log only. On
# a Stop that the reconcile KEEPS because background work is still running
# (the main turn is over, so a question asked there raises no waiting
# notification), the hook reads the END of Claude's final message (the
# payload's `last_assistant_message`) to judge whether it asks something,
# and appends ONE line to hook.log:
#   ask-check session=<id> result=asks|no|absent|unreadable
# Nothing reads that line yet. The marker, its grammar and every other path
# are exactly as in v7. No other event and no other Stop reads the field,
# and the transcript is never opened. The message itself is never written
# anywhere: not to hook.log, not to the marker, not to a file of its own
# (see final_message_check).
#
# Hook v9 — a DIRECT QUESTION (Claude Code's AskUserQuestion tool). PreToolUse
# and PostToolUse are registered with the matcher AskUserQuestion and are
# OBSERVE-ONLY: like every event here they print nothing and exit 0, so the
# tool call goes ahead exactly as it would without them. Beyond the fields
# read for every event (the event name, the session id, background_tasks),
# the hook reads only their tool name, which must be exactly AskUserQuestion
# (any other is ignored, so a registration without the matcher marks
# nothing); the question, its options and the answer are never read.
#   * PreToolUse writes the IN-FLIGHT token `question` (a question is about
#     to be asked) when the marker is in flight, absent or unreadable; after
#     Stop it leaves the marker alone.
#   * A WAITING-type Notification while the marker says `question` or
#     `waiting-question` writes `waiting-question` instead of `waiting`, so
#     NapCat's waiting alert can say it is a question.
#   * PostToolUse (the question was answered) rewrites either question token
#     as `Notification`, which ends the waiting episode; any other marker is
#     left alone, and none is created.
# Every other event overwrites or clears the two tokens exactly as it does
# any in-flight token. A v8 marker never holds them, so it is handled as
# before.
#
# HARD UX-SAFETY LAYERS (a buggy hook must never be able to break the user's
# Claude Code experience — lint-enforced by ClaudeBusyHookScriptTests):
#   * FORCED EXIT 0 on every path. All work happens in main(); the file ends
#     with an unconditional `exit 0`, and there is no bare non-zero exit
#     anywhere. A non-zero status (a value of 2 in particular) would BLOCK the
#     user's prompt / force a turn to continue — impossible from here.
#   * DAMAGED-FILE GUARD (lines 3 and 4, the first code that runs). A copy of
#     this file cut short (an interrupted copy, a full disk) would stop at a
#     syntax error, which bash reports as status 2. Line 4 compares the
#     file's last line with the final `exit 0` and, when they differ, exits 0
#     before anything else runs: no read of stdin, no write, no log. Line 3
#     covers a cut inside line 4 itself: until line 4 clears it, an EXIT trap
#     turns any status into 0. Only a cut inside line 3 can still end in
#     another status (a word of it cut short), and it runs nothing else
#     either. So the file must END with the line `exit 0`, and no other line
#     may begin with it (lint-enforced).
#   * STDOUT IS SILENCED before any logic runs (exec >/dev/null): Claude injects
#     a command hook's stdout into the model context, so nothing here may print
#     to stdout. Diagnostics go to a private hook.log, never stdout.
#   * NO errexit is ever enabled; no network calls; no waiting/blocking.
#   * Layer 6 KILL SWITCH: the first action after the damaged-file guard
#     checks for a DISABLED flag and, if present, no-ops immediately.
#   * Layer 4 FIRE-AND-FORGET: the marker write is backgrounded and atomic, so
#     a stalled filesystem cannot delay the prompt; the script returns at once.
#
# Input and housekeeping hygiene:
#   * stdin is size-capped, then validated as JSON with
#     `plutil -convert json` — NOT `-convert xml1`, which rejects any JSON
#     `null` (plist has no null), so a nullable field added to a payload would
#     silently drop the whole event. A null-valued field reads as absent.
#     Before that gate every `\u0000` escape is rewritten as the escape for
#     `#` (U+0023, hook v6): newer macOS plutil rejects the whole document on
#     that escape ("Unsupported escaped (unicode) null"), so a NUL in ANY
#     field — even one this hook never reads — would otherwise drop the event.
#     Every surrogate escape (`\uD800`-`\uDFFF`) is likewise rewritten as the
#     escape for U+FFFD, since that plutil rejects a LONE one the same way.
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
# Stock macOS only: bash 3.2, plutil, date, stat, mktemp, head, tail, grep,
# tr, sed. No jq, no sudo.

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
EP_MARKER_RE='^v1 ts=[0-9]+ event=[^ ]+ pid=[0-9]+ src=[^ ]+ ep=([^ ]+)$'
EP_RE='^[1-9][0-9]{0,9}$'
WAITING_EVENT=waiting
WAITING_AFTER_STOP_EVENT=waiting-after-stop
# Hook v9 — the two question tokens, and the one tool name they are about.
QUESTION_EVENT=question
WAITING_QUESTION_EVENT=waiting-question
QUESTION_TOOL=AskUserQuestion
MAX_STDIN=262144
NL=$'\n'
CR=$'\r'
# Hook v8 — the final-message check's bounds: the shell reads at most the
# last ASK_TAIL_BYTES bytes of the message, and judges at most the last
# ASK_TAIL_LINES non-empty lines of those.
ASK_TAIL_BYTES=400
ASK_TAIL_LINES=3
# A fenced code block's fence: up to three spaces, then ``` or ~~~.
FENCE_RE='^ {0,3}(```|~~~)'
# U+FF1F FULLWIDTH QUESTION MARK, as UTF-8.
FW_QMARK=$'\xef\xbc\x9f'
# Closing characters stripped after a question mark, besides the ASCII ones:
# U+201D and U+2019 (right double and single quotation marks), U+FF09
# (fullwidth right parenthesis) and U+300D (right corner bracket).
RDQUO=$'\xe2\x80\x9d'
RSQUO=$'\xe2\x80\x99'
FW_RPAREN=$'\xef\xbc\x89'
RCORNER=$'\xe3\x80\x8d'

# Layer 6 — kill switch. FIRST action after the damaged-file guard (which reads
# only this file): if the user paused detection, do nothing (no reads, no
# writes, no log) and succeed. Placed before every write in the file so it can
# never be bypassed.
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
# Hook v7: the sixth field `ep` (the episode start) is the CURRENT marker's
# value when marker_episode accepts it — an in-episode rewrite keeps it —
# otherwise this write's own ts, which starts a new episode. The read happens
# here, inside the backgrounded write, so it adds nothing to the prompt path.
#   $1 dest  $2 ts  $3 event  $4 src
write_marker() {
  local tmp ep
  ep=$(marker_episode "$1")
  [ -n "$ep" ] || ep=$2
  tmp=$(mktemp "$STATE_DIR/.marker.XXXXXX" 2>/dev/null) || return 0
  printf 'v1 ts=%s event=%s pid=%s src=%s ep=%s\n' "$2" "$3" "$PPID" "$4" "$ep" >"$tmp" 2>/dev/null
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
# `#` first (a byte NTYPE_RE rejects ⇒ `invalid`). Since hook v6 the stdin
# capture in main() already maps the `\u0000` escape to `#`, so no NUL should
# reach this point; the mapping here stays as defence in depth. pipefail keeps
# plutil's own status as the pipeline's, so a non-string still takes the `?`
# branch.
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
    UserPromptSubmit|Notification|waiting|question|waiting-question)
      printf inflight ;;
    Stop|StopFailure|SessionEnd|SubagentStop|waiting-after-stop)
      printf poststop ;;
    *)
      printf none ;;
  esac
  return 0
}

# Hook v7 — read-only, VALIDATED episode-start probe of the CURRENT marker.
# Prints the marker's `ep` value only when the first line is the complete
# six-field grammar (EP_MARKER_RE) AND the value passes the strict whole-string
# EP_RE check (1-10 digits, no leading zero); prints nothing otherwise (no
# marker, a FIFO or other non-regular file, a v6 marker without the field, an
# extra field, or a malformed value), so the caller anchors a fresh episode.
# Same read discipline as marker_phase: a REGULAR file only, at most 256
# bytes, NULs mapped to `#`, first line only. The value is never logged.
#   $1 marker path
marker_episode() {
  local line ep
  [ -f "$1" ] || return 0
  line=$(head -c 256 "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#')
  line=${line%%"$NL"*}
  [[ $line =~ $EP_MARKER_RE ]] || return 0
  ep=${BASH_REMATCH[1]}
  [[ $ep =~ $EP_RE ]] || return 0
  printf '%s' "$ep"
  return 0
}

# Hook v9 — read-only, VALIDATED question probe of the CURRENT marker. Prints
# `yes` when the first line's event token is exactly `question` or
# `waiting-question`, and `no` otherwise (no marker, a FIFO or other
# non-regular file, an unparseable line, any other token). Same read
# discipline as marker_phase: a REGULAR file only, at most 256 bytes, NULs
# mapped to `#`, first line only; an exact match leaves no room for a CR or
# a spliced token. The token itself is never printed or logged.
#   $1 marker path
marker_question() {
  local line tok
  [ -f "$1" ] || { printf no; return 0; }
  line=$(head -c 256 "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#')
  line=${line%%"$NL"*}
  [[ $line =~ $MARKER_RE ]] || { printf no; return 0; }
  tok=${BASH_REMATCH[1]}
  case "$tok" in
    "$QUESTION_EVENT"|"$WAITING_QUESTION_EVENT") printf yes ;;
    *) printf no ;;
  esac
  return 0
}

# Hook v9 — read-only, VALIDATED tool probe: succeeds iff the payload's
# `tool_name` is a string that is exactly QUESTION_TOOL. Prints nothing; the
# value never reaches hook.log. `-expect string` refuses every non-string;
# plutil's raw output ends in one newline, and the `x` sentinel keeps a
# newline that is part of the VALUE (as in notification_type), so
# "AskUserQuestion<LF>" fails; NULs are mapped to `#` first (bash 3.2 would
# drop them). Absent, not a string, or unparseable ⇒ fails.
#   $1 payload file
question_tool() {
  local t
  t=$( (set -o pipefail; plutil -extract tool_name raw -expect string -o - "$1" 2>/dev/null | LC_ALL=C /usr/bin/tr '\000' '#') && printf x ) || return 1
  [ "$t" = "$QUESTION_TOOL${NL}x" ]
}

# Hook v8 — the PURE judgement: no file, no other process, and no output but
# one word. $1 is the end of Claude's final message, at most its last
# ASK_TAIL_BYTES bytes (the caller cuts it). Walking up from the last line,
# it prints `asks` when one of the last ASK_TAIL_LINES non-empty lines
# outside fenced code blocks ends with `?` or the full-width question mark,
# once trailing ASCII whitespace and closing characters are stripped: the
# ASCII ) ] } " ' * _ ~ and backtick, and the four non-ASCII closers above.
# Otherwise it prints `no`.
# It matches bytes: LC_ALL is C inside this function only (bash puts the
# caller's locale back on return), so an inherited UTF-8 locale can neither
# widen [[:space:]] beyond ASCII whitespace nor change what one `?` in a
# pattern strips.
# Code blocks: every fence line (FENCE_RE) switches between prose and code,
# and is not judged itself. A message ends in prose, so walking up the first
# fence met is a closing one: a `?` inside any block closed within the
# bound never counts, and when a block's opening fence lies beyond the cut,
# every line read above its closing fence is code.
# A line is judged by its END: the first line, cut by the bound, still
# counts; a question mark the bound leaves outside, or cuts through (a
# full-width one with its first bytes outside), does not.
# Known false positives: a question mark that ends a line but asks nothing
# of the user, such as a rhetorical heading ("Why did it fail?") followed by
# its answer, a quoted question, or a code span, path or table row ending in
# `?`; a line inside a code block whose fence is indented four or more
# spaces (one in a list item); a `?` line inside a code block that is never
# closed (the message ends in code, so walking up, its lines are judged as
# prose until its opening fence, which is taken for a closing one); and a
# `?` line between two ``` lines inside a ~~~ block (or the reverse). Known
# false negatives: a question followed by ASK_TAIL_LINES or more non-empty
# lines (an option list of three or more items after it), by an emoji, by
# "(y/n)" or other text on the same line, or by a space that is not ASCII (a
# no-break space, say); a question asked without a question mark, or with
# one this rule does not know, such as the Arabic question mark (U+061F); a
# question above a code block that is never closed, or above a ~~~ block
# holding a ``` line (or the reverse), which the walk takes for a fence; and
# anything beyond the bound.
#   $1 text
tail_asks() {
  local LC_ALL=C
  local text=$1 line more=yes counted=0 code=no
  while [ "$more" = yes ]; do
    case "$text" in
      *"$NL"*) line=${text##*"$NL"}; text=${text%"$NL"*} ;;
      *) line=$text; more=no ;;
    esac
    if [[ $line =~ $FENCE_RE ]]; then
      if [ "$code" = no ]; then code=yes; else code=no; fi
      continue
    fi
    [ "$code" = no ] || continue
    while :; do
      case "$line" in
        *[[:space:]]|*[]\)\}\*_~\`\"\']) line=${line%?} ;;
        *"$RDQUO") line=${line%"$RDQUO"} ;;
        *"$RSQUO") line=${line%"$RSQUO"} ;;
        *"$FW_RPAREN") line=${line%"$FW_RPAREN"} ;;
        *"$RCORNER") line=${line%"$RCORNER"} ;;
        *) break ;;
      esac
    done
    [ -n "$line" ] || continue
    case "$line" in
      *'?'|*"$FW_QMARK") printf asks; return 0 ;;
    esac
    counted=$((counted + 1))
    [ "$counted" -lt "$ASK_TAIL_LINES" ] || break
  done
  printf no
  return 0
}

# Hook v8 — the final-message check, read-only. Called from ONE place in
# main(): a Stop that the reconcile keeps because background work is still
# running, while the payload still exists (inside its traps). Prints exactly
# one closed word: `asks` or `no` (tail_asks); `absent` when there is no
# value at the key, or a JSON null; `unreadable` when the value is not a
# string. A payload that fails the stdin gate (invalid JSON or UTF-8, or one
# cut at MAX_STDIN) never gets this far: the event is ignored as before.
# The message reaches the shell only through this pipe: plutil decodes the
# string, `tail -c` keeps its last ASK_TAIL_BYTES bytes (plus plutil's own
# newline), so the shell never holds more than that however long the
# message is, and any NUL is mapped to `#` before the shell sees it (bash
# 3.2 drops NULs inside $(…); the v6 stdin mapping should leave none). The
# text is held in this function's one variable only: never written to a
# file, logged or printed.
# pipefail keeps plutil's own status as the pipeline's, so a non-string or
# missing value takes the second branch, whose probe prints to /dev/null
# only (a dictionary would print its keys).
#   $1 payload file
final_message_check() {
  local t
  t=$(set -o pipefail; plutil -extract last_assistant_message raw -expect string -o - "$1" 2>/dev/null | /usr/bin/tail -c "$((ASK_TAIL_BYTES + 1))" | LC_ALL=C /usr/bin/tr '\000' '#') || {
    if plutil -extract last_assistant_message raw -o - "$1" >/dev/null 2>&1; then
      printf unreadable
    else
      printf absent
    fi
    return 0
  }
  tail_asks "$t"
  return 0
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null

  local now src payload event logevent session marker bg_running ntype tclass tinfo phase pinfo token asked tool
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
  # Map two JSON escapes BEFORE the gate (hook v6): newer macOS plutil rejects
  # the whole document on either, which would drop the event and could leave a
  # marker stuck.
  #   * `\u0000` becomes the escape for `#` (U+0023) — "Unsupported escaped
  #     (unicode) null".
  #   * Every surrogate escape (`\uD800`-`\uDFFF`) becomes the escape for
  #     U+FFFD: a LONE one is rejected, and JSON.stringify emits one when a
  #     string is cut mid-emoji. A valid pair is mapped too (two U+FFFD) — an
  #     accepted tradeoff, since no field this hook matches (event, session,
  #     type, task status) can legitimately contain one, and the final-message
  #     check (hook v8) only looks for a question mark at a line's end, which
  #     neither the pair nor its U+FFFD is.
  # Each rewrite is six characters for six, so the payload never outgrows the
  # cap, and the two patterns cannot overlap. A literal `\\u0000` or `\\ud83d`
  # text is rewritten too — harmless, since no field this hook matches can
  # legitimately contain a backslash, and in the final message the rewrite
  # never adds or removes a question mark or a line break.
  head -c "$MAX_STDIN" | LC_ALL=C /usr/bin/sed -E -e 's/\\u0000/\\u0023/g' -e 's/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/\\ufffd/g' >"$payload" 2>/dev/null
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
  # Hook v8 — only a Stop that the reconcile below keeps because background
  # work is still running reads the final message: for a Stop, that is
  # exactly a valid session with bg_running=yes (no branch before that keep
  # can take a Stop). It is read here, while the payload exists, so the
  # check stays inside the payload's traps; its one word is logged in that
  # keep branch.
  asked=""
  [ "$event" = Stop ] && [ "$bg_running" = yes ] && valid_session "$session" && asked=$(final_message_check "$payload")
  # Only a Notification carries a type worth reading (no extra plutil process
  # on the latency-sensitive UserPromptSubmit path).
  ntype=""
  [ "$event" = Notification ] && ntype=$(notification_type "$payload")
  # Hook v9 — only the two tool events read the tool name, and only to
  # compare it with QUESTION_TOOL; nothing else of their payload is read
  # beyond the fields every event reads above.
  tool=""
  if [ "$event" = PreToolUse ] || [ "$event" = PostToolUse ]; then
    question_tool "$payload" && tool=$QUESTION_TOOL
  fi
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
      # waiting > resume > background-task keep (B3) > post-Stop ignore >
      # clear. Any other type (idle_prompt, auth_success, agent_completed,
      # unknown, `invalid`, `?`) leaves tclass empty, so it falls through to
      # the background-task check, is then ignored post-Stop (hook v5), and
      # otherwise clears, as before C1.
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
      # otherwise the turn is done and the marker is cleared — except that a
      # post-Stop Notification never clears. Precedence: waiting > resume >
      # main-turn-in-flight > background task > (SubagentStop, no marker)
      # ignore > (Notification, post-Stop) ignore > clear.
      if [ "$tclass" = waiting ]; then
        token=$WAITING_EVENT
        [ "$phase" = poststop ] && token=$WAITING_AFTER_STOP_EVENT
        # Hook v9 — a wait on a direct question keeps saying so (both
        # question tokens are in flight, so a post-Stop marker never reads).
        [ "$phase" = inflight ] && [ "$(marker_question "$marker")" = yes ] && token=$WAITING_QUESTION_EVENT
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
        # Hook v8 — set on a Stop only (above), and only a closed word is
        # ever logged.
        case "$asked" in
          asks|no|absent|unreadable) log "ask-check session=$session result=$asked" ;;
        esac
      elif [ "$event" = SubagentStop ] && [ "$phase" = none ]; then
        log "ignore reason=no-marker event=$event$pinfo"
      elif [ "$event" = Notification ] && [ "$phase" = poststop ]; then
        # Hook v5. Reached only with tclass EMPTY (a CLEAR-class, unknown or
        # malformed type) — a waiting or resume type took a branch above —
        # and with bg_running=no. A Notification payload never carries
        # `background_tasks`, so that "no" says nothing: the post-Stop marker
        # exists because background work was running, and only Stop /
        # StopFailure / SessionEnd / SubagentStop may clear it (Stop and
        # SubagentStop carry the task registry). No rewrite, no clear.
        log "ignore reason=poststop-clear-notification session=$session type=$ntype pid=$PPID src=$src"
      else
        rm -f "$marker" 2>/dev/null
        log "clear session=$session event=$event$tinfo$pinfo"
      fi
      ;;
    PreToolUse|PostToolUse)
      # Hook v9 — observe-only (see the header): never a clear, never a new
      # marker on PostToolUse, and nothing here can hold up the tool call.
      if [ "$tool" != "$QUESTION_TOOL" ]; then
        log "ignore reason=other-tool event=$event"
      elif [ "$event" = PreToolUse ]; then
        phase=$(marker_phase "$marker")
        if [ "$phase" = poststop ]; then
          log "ignore reason=poststop-question session=$session event=$event"
        else
          ( write_marker "$marker" "$now" "$QUESTION_EVENT" "$src" ) &
          log "keep session=$session event=$event phase=$phase reason=question-asked pid=$PPID src=$src"
        fi
      elif [ "$(marker_question "$marker")" = yes ]; then
        ( write_marker "$marker" "$now" Notification "$src" ) &
        log "keep session=$session event=$event reason=question-answered pid=$PPID src=$src"
      else
        log "ignore reason=no-question session=$session event=$event"
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
