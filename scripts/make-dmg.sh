#!/bin/bash
# NapCat release packaging: wraps dist/NapCat.app into a compressed, read-only
# disk image and writes its SHA-256 next to it:
#
#   dist/NapCat-<version>.dmg
#   dist/NapCat-<version>.dmg.sha256   (shasum format: `shasum -a 256 -c` it)
#
# Run by `make release-artifacts` after the bundle is built and signed with
# whatever SIGN_IDENTITY make was given. This script signs nothing, never uses
# sudo, and takes no arguments: every path is fixed relative to the repository
# root, and <version> is CFBundleShortVersionString from Resources/Info.plist,
# accepted only as plain MAJOR.MINOR.PATCH (so it can never steer a path).
#
# The image holds exactly three entries: NapCat.app, an /Applications symlink
# to drag it onto, and "READ ME.txt". The layout and every file's bytes are
# reproducible run to run from the same bundle; the .dmg container itself is
# not (hdiutil stamps volume creation times into it), so compare two images by
# mounting them and diffing their contents, not by checksum.
#
# Stock macOS tools only: bash 3.2, plutil, codesign, ditto, hdiutil, shasum.

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
umask 022

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DIST="$REPO_ROOT/dist"
APP="$DIST/NapCat.app"
SOURCE_PLIST="$REPO_ROOT/Resources/Info.plist"
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

die() {
    echo "make-dmg: error: $*" >&2
    exit 1
}

if [ "$#" -ne 0 ]; then
    die "takes no arguments (usage: ./scripts/make-dmg.sh, or make release-artifacts)"
fi

# dist/ and the bundle must be real directories: a symlink would make this
# script read from, and write into, somewhere outside the checkout.
if [ ! -d "$DIST" ] || [ -L "$DIST" ]; then
    die "$DIST is missing or a symlink — run 'make' first."
fi
if [ ! -d "$APP" ] || [ -L "$APP" ]; then
    die "$APP is missing or a symlink — run 'make' first."
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_PLIST")"
if ! [[ "$VERSION" =~ $VERSION_PATTERN ]]; then
    die "CFBundleShortVersionString in Resources/Info.plist is not MAJOR.MINOR.PATCH."
fi
# A bundle built before the last version bump would ship under the wrong name.
BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
if [ "$BUNDLE_VERSION" != "$VERSION" ]; then
    die "dist/NapCat.app is $BUNDLE_VERSION but Resources/Info.plist says $VERSION — run 'make' first."
fi
# Never package a bundle whose signature (ad-hoc or real) does not check out.
codesign --verify --strict "$APP" || die "dist/NapCat.app fails codesign --verify — run 'make' again."

NAME="NapCat-$VERSION"
DMG="$DIST/$NAME.dmg"
CHECKSUM="$DMG.sha256"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/napcat-dmg.XXXXXXXX")"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE="$WORK/stage"
mkdir "$STAGE"

# --noextattr/--noacl/--norsrc: copy the bundle's bytes and modes, not local
# Finder or quarantine metadata. The signature lives in the bundle's files, so
# it survives the copy (checked again below).
ditto --noextattr --noacl --norsrc "$APP" "$STAGE/NapCat.app"
codesign --verify --strict "$STAGE/NapCat.app" || die "the staged copy of NapCat.app fails codesign --verify."
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME.txt" <<EOF
NapCat $VERSION
================

NapCat is a small macOS menu bar app: a pixel-art cat that shows your Mac's
power state at a glance. It can keep the Mac awake with the lid closed, and
on Apple Silicon it can pause charging at a battery limit you choose.
Requires macOS 14 (Sonoma) or later.

Install
-------
1. Drag NapCat onto the Applications folder in this window.
2. Eject this disk image.
3. Open NapCat from Applications. The cat appears in the menu bar
   (there is no Dock icon).

One-time setup for Stay Awake and the charge limit
--------------------------------------------------
NapCat runs as you and never asks for, stores, or uses your password. Stay
Awake and the charge limit change system settings that only root can
change, so they work only after a one-time setup that you run yourself in
Terminal. Until then NapCat still shows the battery percentage and charging
state, and the switches explain that setup is required.

The setup script is not in this disk image. It lives in the source
repository, together with the SMC helper it builds and installs. You need
an administrator account and the Xcode Command Line Tools
(xcode-select --install):

    git clone --branch v$VERSION https://github.com/MuratAlkan06/NapCat.git
    cd NapCat
    make smc
    sudo ./scripts/setup.sh

It installs a sudoers file that allows your user a fixed list of exact
commands (pmset disablesleep on/off, and pausing/resuming charging through
the SMC helper), the helper itself as a root-owned file (Apple Silicon
only), and a login-time failsafe that turns sleep back on. Read the script
before you run it. Remove everything again with:

    sudo ./scripts/uninstall.sh

The trade-off: once setup is installed, anything running as your user can
run those same few commands without a password. The worst they can do is
keep the Mac awake or pause and resume charging. The README's "Security
model" section explains the design:
https://github.com/MuratAlkan06/NapCat#security-model

Optional: phone alerts for Claude Code
--------------------------------------
NapCat can send a push to your phone through ntfy when a long Claude Code
run finishes or waits for you, or when the lid closes mid-task. Set them
up in the NapCat menu: open Details, click "ntfy settings...", then turn
on "Lid alert" or "Session alerts". Both need the Claude hook, which you
install from a clone of the repository (the same clone as above):

    ./scripts/install-claude-busy-hook.sh

Source, issues and license (MIT): https://github.com/MuratAlkan06/NapCat
EOF

# hdiutil on hosted CI runners occasionally fails with "Resource busy";
# retry a bounded number of times.
IMAGE="$WORK/$NAME.dmg"
attempt=1
until hdiutil create -quiet -volname "NapCat $VERSION" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -o "$IMAGE"; do
    if [ "$attempt" -ge 3 ]; then
        die "hdiutil create failed $attempt times."
    fi
    attempt=$((attempt + 1))
    rm -f "$IMAGE"
    sleep 5
done
hdiutil verify -quiet "$IMAGE" || die "hdiutil verify rejected the new image."

# The checksum names the bare file, so `shasum -a 256 -c` works in whatever
# folder the .dmg and .sha256 are downloaded to.
(cd "$WORK" && shasum -a 256 "$NAME.dmg") > "$WORK/$NAME.dmg.sha256"

# rm -f fails (and set -e stops) on a directory in the way; on a symlink it
# removes the link itself, so the mv below can never write through one.
rm -f "$DMG" "$CHECKSUM"
mv "$IMAGE" "$DMG"
mv "$WORK/$NAME.dmg.sha256" "$CHECKSUM"

echo "make-dmg: wrote dist/$NAME.dmg"
echo "make-dmg: wrote dist/$NAME.dmg.sha256"
cat "$CHECKSUM"
