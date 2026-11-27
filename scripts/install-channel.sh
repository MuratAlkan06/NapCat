#!/bin/bash
# NapCat remote approvals: registers the channel server bundled in NapCat.app
# with Claude Code (F4, slice I1a).
#
# USER-RUN, as yourself (never as root):
#     ./scripts/install-channel.sh [/path/to/NapCat.app]
# The bundle defaults to /Applications/NapCat.app. Agents must NEVER run this.
#
# What it does, in order, stopping at the first failure:
#   1. checks the bundle path: a real directory, not a symlink, whose name
#      ends in .app;
#   2. verifies the helper, Contents/MacOS/napcat-channel, BEFORE anything else
#      uses it: `codesign --verify --strict` on the helper, its signing
#      identifier, then the app's own seal (which covers the helper); then the
#      team: the app and the helper must name the same team, NapCat's own
#      (TEAM_IDENTIFIER below), and each must satisfy a code requirement for
#      its own identifier that only a Developer ID Application certificate
#      Apple issued to that team meets, so an ad-hoc build, an Apple
#      Development build, or another team's, is refused; only then does it
#      read the bundle's Info.plist (NapCat's bundle identifier and its
#      NapCatChannelVersion);
#   3. checks the receipt's folder, BEFORE anything is registered, so that a
#      refusal here leaves no registration behind: the approvals folder
#      must be a real directory of yours, not a symlink (it is created if
#      missing, and its mode forced to 0700, before Claude Code is found or
#      read, so a run that stops before registering may leave that folder
#      behind), and the receipt in it, if any, a regular file, not a symlink;
#   4. registers the helper with Claude Code at user scope under the name
#      "napcat", through Claude Code's own command line:
#          claude mcp add --scope user --transport stdio napcat -- <helper>
#      Idempotent: an entry that already runs this helper is kept, one that
#      runs another NapCat copy's helper is replaced, and any other server
#      named "napcat" is left alone (the script stops). Another copy's helper
#      means exactly <bundle>.app/Contents/MacOS/napcat-channel, with
#      <bundle>.app an absolute path that has no empty, "." or ".."
#      component (the only shape this script registers); a command that is
#      merely close to that is another server. The entry is read with
#      `claude mcp get napcat`, and only two answers are acted on (a stdio
#      entry's one Command: line, or Claude Code's not-found line); anything
#      else stops the script with nothing registered or removed, rather than
#      risk a second registration;
#   5. writes the receipt, mode 0600, holding the channel version and the
#      helper path: ~/Library/Application Support/NapCat/approvals/
#      channel-registration (replaced by rename, never written through);
#   6. prints the flag each Claude Code session needs to load the channel.
#
# It never edits Claude Code's configuration files or a shell profile by hand
# (only Claude Code's own `claude mcp` commands change its configuration),
# never prints another server's settings, and needs no administrator rights.
# Undo with ./scripts/uninstall-channel.sh.
#
# Exit status: 0 once the helper is registered (or already was) and the
# receipt is written; 1 when it refuses or a step fails, after one
# "install-channel: error:" line that says why and what changed (most say
# "Nothing was registered."); a system command that fails unexpectedly
# stops it with that command's own non-zero status.

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
# The start of the one line `claude mcp get` prints, with status 1, when no
# server has that name (Claude Code 2.1.326; the hint after it, which may
# name other servers, goes unread).
NOT_FOUND_PREFIX="No MCP server named \"$SERVER_NAME\"."
# The helper's signing identifier: byte-identical to CHANNEL_IDENTIFIER in the
# Makefile (ChannelInstallStructureTests).
CHANNEL_IDENTIFIER="com.muratalkan.napcat.channel"
BUNDLE_IDENTIFIER="com.muratalkan.napcat"
# NapCat's signing team: byte-identical to com.apple.developer.team-identifier
# in Resources/NapCat.entitlements (ChannelInstallStructureTests).
TEAM_IDENTIFIER="HJSC985877"
HELPER_IN_BUNDLE="Contents/MacOS/napcat-channel"
# The app's seam folder (SeamPaths.directoryRelativePath); the receipt sits in it.
APPROVALS_DIR="$HOME/Library/Application Support/NapCat/approvals"
RECEIPT="$APPROVALS_DIR/channel-registration"

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
# Command substitution drops trailing newlines, so a bundle name ending in one
# would resolve to its sibling; the sentinel keeps every byte pwd printed for
# the control-character test below.
APP="$(cd -P -- "$APP" && pwd -P && echo .)" || die "cannot resolve $APP."
APP="${APP%??}"
# The path goes into Claude Code's configuration and a line of the receipt.
case "$APP" in
    *[[:cntrl:]]*) die "the bundle path contains a control character." ;;
esac
HELPER="$APP/$HELPER_IN_BUNDLE"
# So the registration is one that uninstall-channel.sh, and a later run of this
# script, recognise as NapCat's.
is_napcat_helper "$HELPER" || die "$APP is not a bundle whose name ends in .app, as NapCat.app does. Nothing was registered."
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
APP_SIGNATURE="$(codesign -d --verbose=2 "$APP" 2>&1)" || die "codesign cannot describe $APP."

# The team a description names: its one TeamIdentifier line when that is an
# Apple team ID (ten capital letters and digits); nothing for an ad-hoc or
# unsigned build ("not set") or no such line; status 1 for anything else.
signature_team() {
    local LC_ALL=C team
    team="$(sed -n 's/^TeamIdentifier=//p' <<< "$1")"
    case "$team" in
        "" | "not set") return 0 ;;
    esac
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || return 1
    printf '%s\n' "$team"
}

# How an error names a team, or the lack of one.
team_label() {
    if [ -n "$1" ]; then
        echo "team $1"
    else
        echo "no team (an ad-hoc or unsigned build)"
    fi
}

HELPER_TEAM="$(signature_team "$HELPER_SIGNATURE")" || die "codesign names a malformed team for $HELPER. Nothing was registered."
APP_TEAM="$(signature_team "$APP_SIGNATURE")" || die "codesign names a malformed team for $APP. Nothing was registered."
[ "$HELPER_TEAM" = "$APP_TEAM" ] \
    || die "$HELPER is signed for $(team_label "$HELPER_TEAM"), but $APP for $(team_label "$APP_TEAM"). Nothing was registered."
[ "$APP_TEAM" = "$TEAM_IDENTIFIER" ] \
    || die "$APP and its helper are signed for $(team_label "$APP_TEAM"), not NapCat's team $TEAM_IDENTIFIER. Nothing was registered."
# Those lines are what each signature claims. Each must also satisfy a
# requirement anchored at Apple, for its own identifier: a Developer ID
# Application certificate (the leaf's field 1.2.840.113635.100.6.1.13),
# issued by Apple's Developer ID Certification Authority (field
# 1.2.840.113635.100.6.2.6), to NapCat's team, as Apple's TN3127 spells
# a Developer ID signature. An Apple Development certificate of the same
# team does not satisfy it.
TEAM_REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\""
codesign --verify --strict -R "=identifier \"$CHANNEL_IDENTIFIER\" and $TEAM_REQUIREMENT" "$HELPER" \
    || die "$HELPER is not signed as $CHANNEL_IDENTIFIER with a Developer ID Application certificate Apple issued to team $TEAM_IDENTIFIER. Nothing was registered."
codesign --verify --strict -R "=identifier \"$BUNDLE_IDENTIFIER\" and $TEAM_REQUIREMENT" "$APP" \
    || die "$APP is not signed as $BUNDLE_IDENTIFIER with a Developer ID Application certificate Apple issued to team $TEAM_IDENTIFIER. Nothing was registered."

# The bundle is NapCat, and names its channel version (read after the seal
# that covers Info.plist verified).
INFO_PLIST="$APP/Contents/Info.plist"
FOUND_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST" 2> /dev/null)" || FOUND_BUNDLE_IDENTIFIER=""
[ "$FOUND_BUNDLE_IDENTIFIER" = "$BUNDLE_IDENTIFIER" ] || die "$APP is not NapCat (its bundle identifier is not $BUNDLE_IDENTIFIER)."
CHANNEL_VERSION="$(plutil -extract NapCatChannelVersion raw -o - "$INFO_PLIST" 2> /dev/null)" || CHANNEL_VERSION=""
[[ "$CHANNEL_VERSION" =~ ^[1-9][0-9]{0,8}$ ]] || die "$APP names no channel version (NapCatChannelVersion in its Info.plist)."

# --- 3. The receipt's folder, before anything is registered ---
# The approvals folder is NapCat's seam folder too: a real directory of yours
# that nobody else can enter, the app's own rule. Checked before Claude Code
# is called, so that a folder refused here leaves no registration behind.
[ ! -L "$APPROVALS_DIR" ] || die "$APPROVALS_DIR is a symlink; refusing to write the receipt through it. Nothing was registered."
mkdir -p "${APPROVALS_DIR%/*}" || die "cannot create ${APPROVALS_DIR%/*}. Nothing was registered."
[ -d "$APPROVALS_DIR" ] || mkdir -m 700 "$APPROVALS_DIR" || die "cannot create $APPROVALS_DIR. Nothing was registered."
if [ -L "$APPROVALS_DIR" ] || [ ! -d "$APPROVALS_DIR" ] || [ "$(stat -f %u "$APPROVALS_DIR")" != "$(id -u)" ]; then
    die "$APPROVALS_DIR is not a directory of yours; refusing to write the receipt there. Nothing was registered."
fi
chmod 700 "$APPROVALS_DIR"
if [ -L "$RECEIPT" ] || { [ -e "$RECEIPT" ] && [ ! -f "$RECEIPT" ]; }; then
    die "$RECEIPT is a symlink or not a regular file; refusing to write through it. Nothing was registered."
fi

# --- 4. The registration ---
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

# What `claude mcp get napcat` says of the server registered as "napcat". Its
# output is written for people, not scripts, so only two answers are read:
#   - status 0 and exactly one "Command:" line (a stdio server): prints that
#     command;
#   - status 1 and nothing but one line that starts with $NOT_FOUND_PREFIX:
#     prints nothing (no server has the name).
# Anything else (no Command: line or two, a not-found line among other
# lines, another status, a format this script predates) is unknown: status
# 1, and the caller changes nothing. The output itself is never printed: it
# may hold another server's environment, or name other servers.
registered_command() {
    local output found status=0
    output="$(claude_cli mcp get "$SERVER_NAME" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        found="$(sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' <<< "$output" | sed 's/[[:space:]]*$//')"
        case "$found" in
            "" | *$'\n'*) return 1 ;;
        esac
        printf '%s\n' "$found"
        return 0
    fi
    [ "$status" -eq 1 ] || return 1
    output="$(sed '/^[[:space:]]*$/d' <<< "$output")"
    case "$output" in
        *$'\n'*) return 1 ;;
        "$NOT_FOUND_PREFIX"*) return 0 ;;
    esac
    return 1
}

CURRENT="$(registered_command)" \
    || die "cannot read the \"$SERVER_NAME\" entry: claude mcp get answered in a way this script does not recognise (a server that is not a stdio server, or a newer Claude Code's format). Nothing was registered or removed. Inspect it with: claude mcp get $SERVER_NAME"
if [ "$CURRENT" = "$HELPER" ]; then
    echo "ok:         \"$SERVER_NAME\" already runs $HELPER (user scope); registration unchanged."
elif [ -n "$CURRENT" ] && ! is_napcat_helper "$CURRENT"; then
    die "another MCP server is registered as \"$SERVER_NAME\"; it was left alone and nothing was registered. Inspect it with: claude mcp get $SERVER_NAME"
else
    if [ -n "$CURRENT" ]; then
        # Another NapCat copy's helper (the app moved, or a second copy).
        claude_cli mcp remove "$SERVER_NAME" --scope user > /dev/null \
            || die "could not remove the registration for $CURRENT (is it outside user scope?). Nothing was added."
        echo "removed:    the registration for another NapCat copy, $CURRENT"
    fi
    # Claude Code's own rule backs that reading up: an add refuses a name
    # that already exists at user scope, and changes nothing.
    claude_cli mcp add --scope user --transport stdio "$SERVER_NAME" -- "$HELPER" > /dev/null \
        || die "claude mcp add refused (its message is above); no receipt was written. Inspect an existing entry with: claude mcp get $SERVER_NAME"
    echo "registered: \"$SERVER_NAME\" at user scope, running $HELPER"
fi

# --- 5. The receipt ---
RECEIPT_TMP="$(mktemp "$APPROVALS_DIR/.channel-registration.XXXXXXXX")"
trap 'rm -f "$RECEIPT_TMP"' EXIT
printf 'version=%s\npath=%s\n' "$CHANNEL_VERSION" "$HELPER" > "$RECEIPT_TMP"
chmod 600 "$RECEIPT_TMP"
# rename(2) replaces the receipt itself, never a file a link points to.
mv -f "$RECEIPT_TMP" "$RECEIPT"
echo "receipt:    $RECEIPT (0600; channel version $CHANNEL_VERSION)"

# --- 6. The per-session flag ---
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
