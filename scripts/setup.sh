#!/bin/bash
# NapCat privileged setup — v1.0 (stay-awake + charge limiting + failsafe
# LaunchAgent).
#
# USER-RUN ONLY, as root:   sudo ./scripts/setup.sh
# Agents must NEVER run this script (PLAN.md hard rule).
#
# Installs:
#   - /usr/local/napcat/smc   (root:wheel 755; expects the caller to have run
#     `make smc` — validates dist/smc exists and is an arm64 Mach-O; NOPASSWD
#     targets must never be user-writable, which is why the bundle path is
#     not used)
#   - /etc/sudoers.d/napcat   (0440 root:wheel) with EXACTLY the eight
#     exact-argument entries from PLAN.md §4, scoped to the invoking user.
#   - ~/Library/LaunchAgents/com.napcat.failsafe.plist (owned by the invoking
#     USER, not root, and written AS that user via `sudo -u`; setup refuses a
#     symlinked ~/Library or ~/Library/LaunchAgents before writing anything)
#     — crash-failsafe layer (c), ADR §6c: RunAtLoad runs
#     `sudo -n pmset -a disablesleep 0` once at login, covering the
#     crash-then-reboot case the in-session watchdog cannot. The agent is
#     INSTALLED but deliberately NOT loaded into the running session:
#     loading it now would fire the revert immediately and could cancel an
#     active Stay Awake session; it takes effect at the next login.
#     No race with the app: NapCat NEVER auto-enables stay-awake at launch
#     (launch reconciliation only ever reverts), so the agent's one-shot
#     login-time revert always settles before any user-initiated enable.
#
# On Intel Macs only the two pmset entries (and the LaunchAgent) are
# installed — charge limiting is Apple Silicon-only in v1 (PLAN.md locked
# decision); Stay Awake still works.
#
# Idempotent — safe to re-run.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/napcat"
SMC_DIR="/usr/local/napcat"
SMC_DEST="$SMC_DIR/smc"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMC_SRC="$REPO_ROOT/dist/smc"
AGENT_LABEL="com.napcat.failsafe"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo ./scripts/setup.sh" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "error: could not determine the invoking user (SUDO_USER unset or root)." >&2
    echo "       Run via sudo from your own account, not from a root shell." >&2
    exit 1
fi
# Security hardening (P2 review carryover): the value lands inside a sudoers
# rule, so it must look like a real macOS short name AND actually exist.
if ! printf '%s' "$TARGET_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    echo "error: SUDO_USER '$TARGET_USER' is not a valid macOS short user name — refusing." >&2
    exit 1
fi
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "error: user '$TARGET_USER' does not exist on this system — refusing." >&2
    exit 1
fi

# Security hardening (pre-publication audit F2, 2026-10-19): resolve and vet
# the failsafe LaunchAgent destination BEFORE anything is written. Everything
# under $TARGET_HOME is controlled by the invoking user — and so by any
# process running as that user, no password needed. A root-run
# `install -d -o USER "$AGENT_DIR"` follows a symlinked directory, so a planted
# ~/Library/LaunchAgents -> /usr/local/napcat would make root chown the
# NOPASSWD target's directory to the user. Two layers:
#   1. refuse loudly (exit nonzero, nothing installed) if ~/Library,
#      ~/Library/LaunchAgents or the agent plist itself is a symlink;
#   2. root never writes under the user's home: the LaunchAgent directory and
#      file are written AS the user (`sudo -u`, below), so even a symlink
#      planted after this check reaches only what the user could already write.
TARGET_UID="$(/usr/bin/id -u "$TARGET_USER")"
TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/sed 's/^NFSHomeDirectory: //')"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "error: could not determine home directory for '$TARGET_USER' (got '$TARGET_HOME')." >&2
    exit 1
fi
TARGET_GROUP="$(/usr/bin/id -gn "$TARGET_USER")"
AGENT_DIR="$TARGET_HOME/Library/LaunchAgents"
AGENT_FILE="$AGENT_DIR/$AGENT_LABEL.plist"

refuse_symlink() {
    if [ -L "$1" ]; then
        echo "error: $1 is a symlink — refusing to install the LaunchAgent through it" >&2
        echo "       (a symlink here could redirect the install outside your home directory)." >&2
        echo "       Remove it or replace it with a real directory/file, then re-run setup." >&2
        exit 1
    fi
}
refuse_symlink "$TARGET_HOME/Library"
refuse_symlink "$AGENT_DIR"
refuse_symlink "$AGENT_FILE"
# The agent is written as the user, so an existing LaunchAgents directory must
# be theirs — refuse now rather than fail after the sudoers file is installed.
if [ -d "$AGENT_DIR" ] && [ "$(/usr/bin/stat -f '%u' "$AGENT_DIR")" -ne "$TARGET_UID" ]; then
    echo "error: $AGENT_DIR is not owned by '$TARGET_USER' — the LaunchAgent is" >&2
    echo "       written as that user, so the directory must be theirs. Fix with:" >&2
    echo "           sudo chown $TARGET_USER:$TARGET_GROUP '$AGENT_DIR'" >&2
    exit 1
fi

# Security hardening (P3b review carryover, applied in P5): every directory
# the sudoers NOPASSWD path resolves through must be attacker-immutable. If
# /usr/local were non-root-owned or group/other-writable (e.g. chowned by an
# old Intel-era Homebrew install), a local process could swap out the napcat
# directory wholesale and plant its own `smc` — instant root via the
# NOPASSWD entry. Refuse to install rather than create that hole.
assert_root_owned_dir() {
    local dir="$1"
    if [ -L "$dir" ]; then
        echo "error: $dir is a symlink — refusing to install a NOPASSWD target through it." >&2
        exit 1
    fi
    if [ ! -d "$dir" ]; then
        echo "error: $dir is not a directory." >&2
        exit 1
    fi
    local owner perms
    owner="$(/usr/bin/stat -f '%u' "$dir")"
    perms="$(/usr/bin/stat -f '%Lp' "$dir")"
    if [ "$owner" -ne 0 ]; then
        echo "error: $dir is not owned by root (uid $owner) — refusing to install" >&2
        echo "       a NOPASSWD sudo target under it. Fix with:" >&2
        echo "           sudo chown root:wheel '$dir'" >&2
        exit 1
    fi
    if [ $(( 8#$perms & 8#022 )) -ne 0 ]; then
        echo "error: $dir is group- or other-writable (mode $perms) — refusing to" >&2
        echo "       install a NOPASSWD sudo target under it. Fix with:" >&2
        echo "           sudo chmod go-w '$dir'" >&2
        exit 1
    fi
}

# Apple Silicon detection — same source of truth as the app (ADR §9):
# hw.optional.arm64 missing (Intel) or 0 → no charge limiting.
IS_ARM64="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"

if [ "$IS_ARM64" = "1" ]; then
    # --- smc helper (charge limiting) ---
    if [ ! -f "$SMC_SRC" ]; then
        echo "error: $SMC_SRC not found — run 'make smc' (or plain 'make') first." >&2
        exit 1
    fi
    if ! /usr/bin/file "$SMC_SRC" | grep -q "Mach-O 64-bit executable arm64"; then
        echo "error: $SMC_SRC is not an arm64 Mach-O executable:" >&2
        /usr/bin/file "$SMC_SRC" >&2
        exit 1
    fi
    if [ -e /usr/local ] || [ -L /usr/local ]; then
        assert_root_owned_dir /usr/local
    fi
    /usr/bin/install -d -m 755 -o root -g wheel "$SMC_DIR"
    assert_root_owned_dir "$SMC_DIR"
    if [ -f "$SMC_DEST" ] && cmp -s "$SMC_SRC" "$SMC_DEST"; then
        echo "ok: $SMC_DEST already up to date — nothing changed."
    else
        /usr/bin/install -m 755 -o root -g wheel "$SMC_SRC" "$SMC_DEST"
        echo "installed: $SMC_DEST (755 root:wheel)"
    fi
else
    echo "note: Intel Mac detected — charge limiting is unavailable in v1;"
    echo "      installing the stay-awake (pmset) entries only."
fi

TMP="$(mktemp)"
# Explicitly under /tmp (sticky, traversable): the agent is installed AS the
# user below, so the user must be able to read this root-owned temp file.
TMP_AGENT="$(mktemp /tmp/napcat-failsafe.XXXXXX)"
trap 'rm -f "$TMP" "$TMP_AGENT"' EXIT

# Exact-argument entries — the app execs these argv strings verbatim
# (PLAN.md §4). SetupScriptTests parses this block at test time and locks
# every entry to a PrivilegedCommand argv (per architecture branch, no
# wildcards). Do not reword.
{
    cat <<EOF
# NapCat privileged commands (v1.0).
# Managed by NapCat scripts/setup.sh — do not edit by hand.
# Remove with: sudo ./scripts/uninstall.sh
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
EOF
    if [ "$IS_ARM64" = "1" ]; then
        cat <<EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 02
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 02
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 01000000
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 00
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 00
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 00000000
EOF
    fi
} > "$TMP"

if ! /usr/sbin/visudo -cf "$TMP"; then
    echo "error: generated sudoers file failed visudo validation — aborting, nothing installed." >&2
    exit 1
fi

if [ -f "$SUDOERS_FILE" ] && cmp -s "$TMP" "$SUDOERS_FILE"; then
    echo "ok: $SUDOERS_FILE already up to date for user '$TARGET_USER' — nothing changed."
else
    /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"
    echo "installed: $SUDOERS_FILE (0440 root:wheel)"
fi

# --- crash-failsafe LaunchAgent (layer c, ADR §6c) ---
# Owned by the TARGET USER (a per-user LaunchAgent, not a root daemon): it
# runs in the user's gui session and only needs the pmset NOPASSWD entry
# above — no privileged surface beyond what the sudoers file already grants.
# See the header comment for why it is installed but NOT loaded here.
# $TARGET_HOME, $AGENT_DIR and $AGENT_FILE were resolved and symlink-vetted
# before the first write (audit F2, top of script).
# SetupScriptTests parses this plist at test time: its ProgramArguments must
# equal `sudo -n` + the stay-awake-off PrivilegedCommand argv exactly.
cat > "$TMP_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.napcat.failsafe</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/sudo</string>
		<string>-n</string>
		<string>/usr/bin/pmset</string>
		<string>-a</string>
		<string>disablesleep</string>
		<string>0</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF

if ! /usr/bin/plutil -lint -s "$TMP_AGENT"; then
    echo "error: generated LaunchAgent plist failed plutil lint — aborting before install." >&2
    exit 1
fi

# Every write under the user's home runs AS the user (audit F2): root never
# creates, chowns or writes through a path the user controls.
/bin/chmod 0644 "$TMP_AGENT"   # fixed, non-secret plist content
/usr/bin/sudo -u "$TARGET_USER" /usr/bin/install -d -m 755 -g "$TARGET_GROUP" "$AGENT_DIR"
if [ -f "$AGENT_FILE" ] && /usr/bin/sudo -u "$TARGET_USER" /usr/bin/cmp -s "$TMP_AGENT" "$AGENT_FILE"; then
    echo "ok: $AGENT_FILE already up to date — nothing changed."
else
    /usr/bin/sudo -u "$TARGET_USER" /usr/bin/install -m 0644 -g "$TARGET_GROUP" "$TMP_AGENT" "$AGENT_FILE"
    echo "installed: $AGENT_FILE (0644 $TARGET_USER:$TARGET_GROUP)"
    echo "           Takes effect at the next login (RunAtLoad); deliberately not"
    echo "           loaded now so an active Stay Awake session is not reverted."
fi

echo "User '$TARGET_USER' may now run without a password:"
grep "^$TARGET_USER" "$SUDOERS_FILE" | sed -e "s/^$TARGET_USER ALL=(root) NOPASSWD: /    /"
echo "NapCat is ready — reopen the menu (no app restart needed for charge limiting)."
echo "Verify with:"
echo "    sudo -n /usr/bin/pmset -a disablesleep 0 && echo OK"
if [ "$IS_ARM64" = "1" ]; then
    echo "    $SMC_DEST -k CHTE -r    # unprivileged read must print the key"
fi
echo "    plutil -lint '$AGENT_FILE'"
