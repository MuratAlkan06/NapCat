#!/bin/bash
# NapCat remote approvals: reverses scripts/install-channel.sh (F4, slice I1a).
#
# USER-RUN, as yourself (never as root):
#     ./scripts/uninstall-channel.sh
# Agents must NEVER run this.
#
# Undoes exactly what the installer created:
#   1. the Claude Code registration named "napcat", at user scope, removed
#      through Claude Code's own command line
#          claude mcp remove napcat --scope user
#      ONLY when it runs a NapCat bundle's channel server at a path of the
#      one shape the installer registers
#      (<bundle>.app/Contents/MacOS/napcat-channel; see is_napcat_helper)
#      AND the receipt records that same path. Any other server named
#      "napcat" is left alone. A NapCat helper the receipt does not record
#      (no receipt, an unreadable one, or one naming another path) is left
#      alone too, and reported as an error: this script cannot show the
#      installer registered it, so it names the command that removes it.
#      The entry is read with `claude mcp get napcat`, and only its two
#      known answers count (a stdio entry's one Command: line, or Claude
#      Code's not-found line); any other answer is an error, never "nothing
#      to remove";
#   2. the receipt, ~/Library/Application Support/NapCat/approvals/
#      channel-registration (a symlink there is reported, never followed).
#      It is kept while a registration step above fails, so that a later
#      run can still match the registration against it. A symlinked
#      approvals folder, which the installer refuses, is reported too: no
#      receipt is read or removed through it.
# The approvals folder itself stays: it is NapCat's seam folder too.
#
# Idempotent and error-collecting: every step is attempted, and it is safe to
# run when nothing was installed. It never edits Claude Code's configuration
# files or a shell profile by hand, never prints another server's settings,
# and needs no administrator rights.
#
# Exit status: 0 when nothing the installer made is left (or none was
# there); 1 for a wrong argument, as root, or when any step failed or was
# left undone, each listed under "uninstall-channel finished WITH ERRORS".

set -euo pipefail
# Your own PATH, kept only to find and run Claude Code, your own tool (an npm
# install of it needs `node` from your PATH). Every other command here runs on
# the pinned PATH below.
CALLER_PATH="$PATH"
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022
unset CDPATH

# The registration's name: the server's own MCP name, ApprovalChannel.serverName.
SERVER_NAME="napcat"
# The start of the one line `claude mcp get` prints, with status 1, when no
# server has that name (Claude Code 2.1.326; the hint after it, which may
# name other servers, goes unread).
NOT_FOUND_PREFIX="No MCP server named \"$SERVER_NAME\"."
HELPER_IN_BUNDLE="Contents/MacOS/napcat-channel"
# The app's seam folder (SeamPaths.directoryRelativePath); the receipt sits in it.
APPROVALS_DIR="$HOME/Library/Application Support/NapCat/approvals"
RECEIPT="$APPROVALS_DIR/channel-registration"
FAILURES=()

if [ "$#" -ne 0 ]; then
    echo "usage: $0" >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as yourself, not as root: Claude Code keeps one configuration per user." >&2
    exit 1
fi

# --- 1. The registration ---
CLAUDE_BIN="$(/usr/bin/env PATH="$CALLER_PATH" /usr/bin/which claude 2> /dev/null)" || CLAUDE_BIN=""
case "$CLAUDE_BIN" in
    /*) [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="" ;;
    *) CLAUDE_BIN="" ;;
esac

# Claude Code on your own PATH, run from / so that no project- or local-scope
# "napcat" entry of the folder you ran this from can stand in for the
# user-scope one the installer made.
claude_cli() {
    (cd / && /usr/bin/env PATH="$CALLER_PATH" "$CLAUDE_BIN" "$@")
}

# What `claude mcp get napcat` says of the server registered as "napcat". Its
# output is written for people, not scripts, so only two answers are read:
#   - status 0 and exactly one "Command:" line (a stdio server): prints that
#     command;
#   - status 1 and nothing but one line that starts with $NOT_FOUND_PREFIX:
#     prints nothing (no server has the name).
# Anything else (no Command: line or two, a not-found line among other
# lines, another status, a format this script predates) is unknown: status
# 1, and the caller changes nothing. The output itself is never printed: it
# may hold another server's environment, or name other servers. It is read
# byte by byte (sed under LC_ALL=C), so a byte that is not UTF-8 reads the
# same in every locale, and a sed that fails stops the read.
registered_command() {
    local output found status=0
    output="$(claude_cli mcp get "$SERVER_NAME" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        found="$(LC_ALL=C sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' <<< "$output" | LC_ALL=C sed 's/[[:space:]]*$//')" || return 1
        case "$found" in
            "" | *$'\n'*) return 1 ;;
        esac
        printf '%s\n' "$found"
        return 0
    fi
    [ "$status" -eq 1 ] || return 1
    output="$(LC_ALL=C sed '/^[[:space:]]*$/d' <<< "$output")" || return 1
    case "$output" in
        *$'\n'*) return 1 ;;
        "$NOT_FOUND_PREFIX"*) return 0 ;;
    esac
    return 1
}

# Whether $1 is a NapCat bundle's channel server at a path of the one shape
# this script registers: <bundle>/Contents/MacOS/napcat-channel exactly, where
# <bundle> is an absolute path as `pwd -P` prints one (no empty, "." or ".."
# component, no control character) and its own name ends in .app, after at
# least one other character.
is_napcat_helper() {
    local bundle="${1%/"$HELPER_IN_BUNDLE"}"
    [ "$bundle/$HELPER_IN_BUNDLE" = "$1" ] || return 1
    case "$bundle" in
        *[[:cntrl:]]* | *//* | */./* | */../*) return 1 ;;
        /*) ;;
        *) return 1 ;;
    esac
    case "${bundle##*/}" in
        ?*.app) return 0 ;;
        *) return 1 ;;
    esac
}

# The helper path the receipt records: its one "path=" line, read from at
# most its first 1 KiB, as NapCat reads it, byte by byte (sed under
# LC_ALL=C, the same in every locale). Status 1 (nothing printed) when
# the approvals folder is a symlink, the receipt is missing, a symlink or
# not a regular file, or it holds no single path line.
receipt_path() {
    local found
    if [ -L "$APPROVALS_DIR" ] || [ -L "$RECEIPT" ] || [ ! -f "$RECEIPT" ]; then
        return 1
    fi
    found="$(head -c 1024 "$RECEIPT" | LC_ALL=C sed -n 's/^path=//p')" || return 1
    case "$found" in
        "" | *$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$found"
}

# Set when a registration may be left that the receipt still names.
KEEP_RECEIPT=""
if [ -z "$CLAUDE_BIN" ]; then
    FAILURES+=("cannot find the claude command on your PATH; if 'claude mcp get $SERVER_NAME' shows a NapCat helper, remove it with: claude mcp remove $SERVER_NAME --scope user")
    KEEP_RECEIPT=1
elif ! CURRENT="$(registered_command)"; then
    FAILURES+=("cannot read the \"$SERVER_NAME\" entry: claude mcp get answered in a way this script does not recognise (a server that is not a stdio server, or a newer Claude Code's format); nothing was removed. Inspect it with: claude mcp get $SERVER_NAME; if it runs a NapCat helper you registered, remove it with: claude mcp remove $SERVER_NAME --scope user")
    KEEP_RECEIPT=1
else
    RECORDED="$(receipt_path)" || RECORDED=""
    if [ -z "$CURRENT" ]; then
        echo "ok: no \"$SERVER_NAME\" registration; nothing to remove"
    elif ! is_napcat_helper "$CURRENT"; then
        echo "left alone: the server registered as \"$SERVER_NAME\" does not run a NapCat helper"
    elif [ "$RECORDED" != "$CURRENT" ]; then
        if [ -z "$RECORDED" ]; then
            FAILURES+=("left alone: \"$SERVER_NAME\" runs $CURRENT, but no readable receipt records it, so this script cannot show the installer registered it; if it is yours, remove it with: claude mcp remove $SERVER_NAME --scope user")
        elif is_napcat_helper "$RECORDED"; then
            FAILURES+=("left alone: \"$SERVER_NAME\" runs $CURRENT, but the receipt records $RECORDED; if it is yours, remove it with: claude mcp remove $SERVER_NAME --scope user")
        else
            # The recorded path is printed only in the one shape the installer writes.
            FAILURES+=("left alone: \"$SERVER_NAME\" runs $CURRENT, but the receipt records a path that is not a NapCat helper's (not shown); if it is yours, remove it with: claude mcp remove $SERVER_NAME --scope user")
        fi
        KEEP_RECEIPT=1
    elif claude_cli mcp remove "$SERVER_NAME" --scope user > /dev/null; then
        echo "removed: the \"$SERVER_NAME\" registration (user scope) for $CURRENT"
    else
        FAILURES+=("could not remove the \"$SERVER_NAME\" registration for $CURRENT (its message is above); is it outside user scope? Inspect it with: claude mcp get $SERVER_NAME")
        KEEP_RECEIPT=1
    fi
fi

# --- 2. The receipt ---
if [ -L "$APPROVALS_DIR" ]; then
    FAILURES+=("$APPROVALS_DIR is a symlink, which the installer refuses; no receipt was read or removed through it, check it by hand")
elif [ -n "$KEEP_RECEIPT" ]; then
    if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
        echo "kept: $RECEIPT, for the registration step reported below"
    fi
elif [ -L "$RECEIPT" ]; then
    FAILURES+=("$RECEIPT is a symlink, which the installer never writes; left alone, check it and remove it by hand")
elif [ -f "$RECEIPT" ]; then
    if rm -f "$RECEIPT"; then
        echo "removed: $RECEIPT"
    else
        FAILURES+=("could not remove $RECEIPT")
    fi
elif [ -e "$RECEIPT" ]; then
    FAILURES+=("$RECEIPT is not a regular file, which the installer never writes; left alone")
else
    echo "ok: $RECEIPT not present; nothing to remove"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "" >&2
    echo "uninstall-channel finished WITH ERRORS:" >&2
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "Done. Start new Claude Code sessions without --dangerously-load-development-channels server:$SERVER_NAME."
exit 0
