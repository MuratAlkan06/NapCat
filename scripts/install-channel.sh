#!/bin/bash
# NapCat remote approvals: registers the channel server bundled in NapCat.app
# with Claude Code (F4, slice I1a).
#
# USER-RUN, as yourself (never as root):
#     ./scripts/install-channel.sh [/path/to/NapCat.app]
# The bundle defaults to /Applications/NapCat.app. Agents must NEVER run this.
#
# What it does, in order, stopping at the first failure:
#   1. checks the bundle path: a real directory, not a symlink;
#   2. verifies the helper, Contents/MacOS/napcat-channel, BEFORE anything else
#      uses it: `codesign --verify --strict` on the helper, its signing
#      identifier, then the app's own seal (which covers the helper); only then
#      does it read the bundle's Info.plist (NapCat's bundle identifier and its
#      NapCatChannelVersion);
#   3. registers the helper with Claude Code at user scope under the name
#      "napcat", through Claude Code's own command line:
#          claude mcp add --scope user --transport stdio napcat -- <helper>
#      Idempotent: an entry that already runs this helper is kept, one that
#      runs another NapCat copy's helper is replaced, and any other server
#      named "napcat" is left alone (the script stops);
#   4. writes a receipt, mode 0600, holding the channel version and the
#      helper path: ~/Library/Application Support/NapCat/approvals/
#      channel-registration. It refuses a symlinked folder or receipt;
#   5. prints the flag each Claude Code session needs to load the channel.
#
# It never edits Claude Code's configuration files or a shell profile by hand
# (only Claude Code's own `claude mcp` commands change its configuration),
# never prints another server's settings, and needs no administrator rights.
# Undo with ./scripts/uninstall-channel.sh.

set -euo pipefail
# Your own PATH, kept only to find and run Claude Code, your own tool (an npm
# install of it needs `node` from your PATH). Every other command here runs on
# the pinned PATH below.
CALLER_PATH="$PATH"
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022
unset CDPATH

die() {
    echo "install-channel: error: $*" >&2
    exit 1
}

# The registration's name: the server's own MCP name, ApprovalChannel.serverName.
SERVER_NAME="napcat"
# The helper's signing identifier: byte-identical to CHANNEL_IDENTIFIER in the
# Makefile (ChannelInstallStructureTests).
CHANNEL_IDENTIFIER="com.muratalkan.napcat.channel"
BUNDLE_IDENTIFIER="com.muratalkan.napcat"
HELPER_IN_BUNDLE="Contents/MacOS/napcat-channel"
# The app's seam folder (SeamPaths.directoryRelativePath); the receipt sits in it.
APPROVALS_DIR="$HOME/Library/Application Support/NapCat/approvals"
RECEIPT="$APPROVALS_DIR/channel-registration"

[ "$#" -le 1 ] || die "usage: $0 [/path/to/NapCat.app]"
[ "$(id -u)" -ne 0 ] || die "run this as yourself, not as root: Claude Code keeps one configuration per user."
case "$HOME" in
    /*) [ -d "$HOME" ] || die "your home directory $HOME does not exist." ;;
    *) die "HOME is not an absolute path." ;;
esac

# --- 1. The bundle path ---
APP="${1:-/Applications/NapCat.app}"
case "$APP" in
    /*) ;;
    *) APP="$PWD/$APP" ;;
esac
# Trailing slashes would make the symlink test follow a link.
while [ "${APP%/}" != "$APP" ] && [ "$APP" != "/" ]; do
    APP="${APP%/}"
done
if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    die "$APP is not a bundle directory (a symlink is refused)."
fi
# The physical path, so the registration names no symlinked folder above it.
APP="$(cd -P -- "$APP" && pwd -P)" || die "cannot resolve $APP."
# The path goes into Claude Code's configuration and a line of the receipt.
case "$APP" in
    *[[:cntrl:]]*) die "the bundle path contains a control character." ;;
esac
HELPER="$APP/$HELPER_IN_BUNDLE"
# A short path, so the receipt always fits the 1 KiB NapCat reads of it.
path_bytes() {
    local LC_ALL=C
    echo "${#1}"
}
[ "$(path_bytes "$HELPER")" -le 1000 ] || die "the helper path is longer than 1000 bytes."

# --- 2. The helper's signature, before anything uses it ---
if [ ! -f "$HELPER" ] || [ -L "$HELPER" ]; then
    die "$APP has no channel server at $HELPER_IN_BUNDLE (it predates the bundled server, or is not NapCat)."
fi
codesign --verify --strict "$HELPER" || die "$HELPER fails codesign --verify --strict. Nothing was registered."
HELPER_SIGNATURE="$(codesign -d --verbose=2 "$HELPER" 2>&1)" || die "codesign cannot describe $HELPER."
grep -qxF "Identifier=$CHANNEL_IDENTIFIER" <<< "$HELPER_SIGNATURE" \
    || die "$HELPER is not signed as $CHANNEL_IDENTIFIER. Nothing was registered."
codesign --verify --strict "$APP" || die "$APP fails codesign --verify --strict. Nothing was registered."

# The bundle is NapCat, and names its channel version (read after the seal
# that covers Info.plist verified).
INFO_PLIST="$APP/Contents/Info.plist"
FOUND_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST" 2> /dev/null)" || FOUND_BUNDLE_IDENTIFIER=""
[ "$FOUND_BUNDLE_IDENTIFIER" = "$BUNDLE_IDENTIFIER" ] || die "$APP is not NapCat (its bundle identifier is not $BUNDLE_IDENTIFIER)."
CHANNEL_VERSION="$(plutil -extract NapCatChannelVersion raw -o - "$INFO_PLIST" 2> /dev/null)" || CHANNEL_VERSION=""
[[ "$CHANNEL_VERSION" =~ ^[1-9][0-9]{0,8}$ ]] || die "$APP names no channel version (NapCatChannelVersion in its Info.plist)."

# --- 3. The registration ---
CLAUDE_BIN="$(/usr/bin/env PATH="$CALLER_PATH" /usr/bin/which claude 2> /dev/null)" || CLAUDE_BIN=""
case "$CLAUDE_BIN" in
    /*) [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="" ;;
    *) CLAUDE_BIN="" ;;
esac
[ -n "$CLAUDE_BIN" ] || die "cannot find the claude command on your PATH. Run this from the shell you start Claude Code in."

# Claude Code on your own PATH, run from / so that no project- or local-scope
# "napcat" entry of the folder you ran this from can stand in for the
# user-scope one this script manages.
claude_cli() {
    (cd / && /usr/bin/env PATH="$CALLER_PATH" "$CLAUDE_BIN" "$@")
}

# The command of the server registered as "napcat": the one "Command:" line
# `claude mcp get napcat` prints for a stdio server. That output is written
# for people, not scripts, so anything else (no such line, or more than one)
# reads as unknown (status 1), and the caller then changes nothing it cannot
# see. The output itself is never printed: it may hold another server's
# environment.
registered_command() {
    local output found
    output="$(claude_cli mcp get "$SERVER_NAME" 2> /dev/null)" || return 1
    found="$(sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' <<< "$output" | sed 's/[[:space:]]*$//')"
    case "$found" in
        "" | *$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$found"
}

# Whether $1 is the path of a NapCat bundle's channel server.
is_napcat_helper() {
    case "$1" in
        /*.app/"$HELPER_IN_BUNDLE") return 0 ;;
        *) return 1 ;;
    esac
}

CURRENT="$(registered_command)" || CURRENT=""
if [ "$CURRENT" = "$HELPER" ]; then
    echo "ok:         \"$SERVER_NAME\" already runs $HELPER (user scope); registration unchanged."
elif [ -n "$CURRENT" ] && ! is_napcat_helper "$CURRENT"; then
    die "another MCP server is registered as \"$SERVER_NAME\"; it was left alone and nothing changed. Inspect it with: claude mcp get $SERVER_NAME"
else
    if [ -n "$CURRENT" ]; then
        # Another NapCat copy's helper (the app moved, or a second copy).
        claude_cli mcp remove "$SERVER_NAME" --scope user > /dev/null \
            || die "could not remove the registration for $CURRENT (is it outside user scope?). Nothing was added."
        echo "removed:    the registration for another NapCat copy, $CURRENT"
    fi
    # When an entry named "napcat" exists that `claude mcp get` showed no
    # command for, this add refuses (it already exists) and changes nothing.
    claude_cli mcp add --scope user --transport stdio "$SERVER_NAME" -- "$HELPER" > /dev/null \
        || die "claude mcp add refused (its message is above); no receipt was written. Inspect an existing entry with: claude mcp get $SERVER_NAME"
    echo "registered: \"$SERVER_NAME\" at user scope, running $HELPER"
fi

# --- 4. The receipt ---
# The approvals folder is NapCat's seam folder too: a real directory of yours
# that nobody else can enter, the app's own rule.
[ ! -L "$APPROVALS_DIR" ] || die "$APPROVALS_DIR is a symlink; refusing to write the receipt through it."
mkdir -p "${APPROVALS_DIR%/*}" || die "cannot create ${APPROVALS_DIR%/*}."
[ -d "$APPROVALS_DIR" ] || mkdir -m 700 "$APPROVALS_DIR" || die "cannot create $APPROVALS_DIR."
if [ -L "$APPROVALS_DIR" ] || [ ! -d "$APPROVALS_DIR" ] || [ "$(stat -f %u "$APPROVALS_DIR")" != "$(id -u)" ]; then
    die "$APPROVALS_DIR is not a directory of yours; refusing to write the receipt there."
fi
chmod 700 "$APPROVALS_DIR"
if [ -L "$RECEIPT" ] || { [ -e "$RECEIPT" ] && [ ! -f "$RECEIPT" ]; }; then
    die "$RECEIPT is a symlink or not a regular file; refusing to write through it."
fi
RECEIPT_TMP="$(mktemp "$APPROVALS_DIR/.channel-registration.XXXXXXXX")"
trap 'rm -f "$RECEIPT_TMP"' EXIT
printf 'version=%s\npath=%s\n' "$CHANNEL_VERSION" "$HELPER" > "$RECEIPT_TMP"
chmod 600 "$RECEIPT_TMP"
# rename(2) replaces the receipt itself, never a file a link points to.
mv -f "$RECEIPT_TMP" "$RECEIPT"
echo "receipt:    $RECEIPT (0600; channel version $CHANNEL_VERSION)"

# --- 5. The per-session flag ---
echo ""
echo "Start each Claude Code session that should send its permission prompts to"
echo "NapCat with this flag (Claude Code asks you to confirm it at start):"
echo ""
echo "    claude --dangerously-load-development-channels server:$SERVER_NAME"
echo ""
echo "Add it to the command you start Claude Code with yourself; this script edits"
echo "no shell profile. Without the flag, Claude Code still starts the server in"
echo "each session, where it stays idle."
echo "If you move or rename NapCat.app, run this script again: the registration"
echo "names this path. Undo with ./scripts/uninstall-channel.sh."
exit 0
