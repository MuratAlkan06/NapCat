#!/bin/bash
# NapCat release check: the entitlements and provisioning profile a built
# bundle carries. The release workflow runs it on the Developer ID bundle
# before notarization, and its dry run on ad-hoc signed bundles built through
# the entitled path and on the plain ad-hoc build.
#
#   ./scripts/check-release-entitlements.sh entitled <app> <entitlements.plist>
#       <app>'s signature verifies; its signed entitlements equal the plist
#       exactly; Contents/embedded.provisionprofile is a regular 0644 file
#       whose decoded profile names the plist's application identifier, has
#       not expired, and grants every entitlement the plist claims (a profile
#       value may be a list, or "*", or end in a ".*" wildcard, as Developer
#       ID profiles do); and, checked last, the signature is not ad-hoc.
#   ./scripts/check-release-entitlements.sh unentitled <app>
#       <app>'s signature verifies, and it carries no entitlements and no
#       embedded provisioning profile (what a plain ad-hoc `make` produces).
#
# Read-only: it signs, installs and changes nothing. It prints entitlement key
# names, the plist's own application identifier and the profile's expiry date,
# never the profile's contents. Exits non-zero on the first failed check.
#
# Stock macOS tools only: bash 3.2, codesign, security, plutil, jq (macOS 15+).

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
LC_ALL=C; export LC_ALL
umask 077

die() {
    echo "check-release-entitlements: error: $*" >&2
    exit 1
}

usage() {
    die "usage: $0 entitled <app> <entitlements.plist> | unentitled <app>"
}

[ "$#" -ge 2 ] || usage
MODE="$1"
APP="$2"
case "$MODE" in
    entitled) [ "$#" -eq 3 ] || usage ;;
    unentitled) [ "$#" -eq 2 ] || usage ;;
    *) usage ;;
esac
command -v jq > /dev/null || die "jq is missing (macOS 15 and later ship it as /usr/bin/jq)."
if [ ! -d "$APP" ] || [ -L "$APP" ]; then
    die "$APP is not a bundle directory."
fi
PROFILE="$APP/Contents/embedded.provisionprofile"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/napcat-entitlements.XXXXXXXX")"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

codesign --verify --strict "$APP" || die "$APP fails codesign --verify --strict."
# The signed entitlements as an XML plist; no output at all means none.
codesign -d --entitlements - --xml "$APP" > "$WORK/signed.plist" 2> /dev/null \
    || die "codesign cannot read the entitlements of $APP."

if [ "$MODE" = "unentitled" ]; then
    if [ -s "$WORK/signed.plist" ] \
        && [ "$(plutil -convert json -o - "$WORK/signed.plist" | jq -c .)" != "{}" ]; then
        die "$APP carries entitlements: $(plutil -convert json -o - "$WORK/signed.plist" | jq -r 'keys | join(", ")')."
    fi
    if [ -e "$PROFILE" ] || [ -L "$PROFILE" ]; then
        die "$APP embeds a provisioning profile."
    fi
    echo "check-release-entitlements: $APP carries no entitlements and embeds no provisioning profile."
    exit 0
fi

EXPECTED="$3"
[ -f "$EXPECTED" ] || die "$EXPECTED is not a file."
plutil -convert json -o "$WORK/expected.json" "$EXPECTED" || die "$EXPECTED is not a property list."
APP_ID="$(jq -r '."com.apple.application-identifier" // empty' "$WORK/expected.json")"
[ -n "$APP_ID" ] || die "$EXPECTED names no com.apple.application-identifier."

[ -s "$WORK/signed.plist" ] || die "$APP carries no entitlements."
plutil -convert json -o "$WORK/signed.json" "$WORK/signed.plist" \
    || die "the signed entitlements of $APP are not a property list."
if ! jq -e -n --slurpfile signed "$WORK/signed.json" --slurpfile expected "$WORK/expected.json" \
    '$signed[0] == $expected[0]' > /dev/null; then
    die "the signed entitlements of $APP differ from $EXPECTED (signed keys: $(jq -r 'keys | join(", ")' "$WORK/signed.json"))."
fi

if [ ! -f "$PROFILE" ] || [ -L "$PROFILE" ]; then
    die "$APP has no Contents/embedded.provisionprofile."
fi
[ "$(stat -f %Lp "$PROFILE")" = "644" ] || die "Contents/embedded.provisionprofile is not mode 0644."
security cms -D -i "$PROFILE" -o "$WORK/profile.plist" 2> /dev/null \
    || die "Contents/embedded.provisionprofile is not a CMS-signed provisioning profile."
# A profile also holds dates and data, which JSON cannot represent, and macOS
# 15's plutil refuses `-extract ... json` from such a plist. So the Entitlements
# are extracted as XML first, and only they are converted to JSON.
plutil -extract Entitlements xml1 -o "$WORK/granted.plist" "$WORK/profile.plist" 2> /dev/null \
    || die "the embedded provisioning profile has no Entitlements dictionary."
plutil -convert json -o "$WORK/granted.json" "$WORK/granted.plist" 2> /dev/null \
    || die "the embedded provisioning profile's Entitlements are not convertible to JSON."

GRANTED_ID="$(jq -r '."com.apple.application-identifier" // empty' "$WORK/granted.json")"
[ "$GRANTED_ID" = "$APP_ID" ] \
    || die "the embedded provisioning profile is not for $APP_ID (the application identifier in $EXPECTED)."

EXPIRES="$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist" 2> /dev/null)" \
    || die "the embedded provisioning profile has no ExpirationDate."
[[ "$EXPIRES" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "the embedded provisioning profile's ExpirationDate is not an ISO 8601 UTC date."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$EXPIRES" > "$NOW" ]] || die "the embedded provisioning profile expired at $EXPIRES."

# Every claimed entitlement must be granted: a claimed list item by item, each
# value equal to the profile's value, to one item of a profile list, or
# matched by a profile wildcard ("*", or a prefix ending in "*").
UNGRANTED="$(jq -r -n --slurpfile claimed "$WORK/expected.json" --slurpfile granted "$WORK/granted.json" '
    def fits($p; $v):
        $p == $v
        or (($p | type) == "string" and ($v | type) == "string"
            and ($p | endswith("*")) and ($v | startswith($p[:-1])));
    def covers($p; $v):
        if ($p | type) == "array" then any($p[]; fits(.; $v)) else fits($p; $v) end;
    def grants($p; $v):
        if ($v | type) == "array" then all($v[]; covers($p; .)) else covers($p; $v) end;
    $claimed[0] as $c
    | $granted[0] as $g
    | $c | keys[]
    | select(. as $k | (($g | has($k)) | not) or (grants($g[$k]; $c[$k]) | not))
')"
if [ -n "$UNGRANTED" ]; then
    die "the embedded provisioning profile does not grant: $(printf '%s' "$UNGRANTED" | tr '\n' ' ')"
fi

# Restricted entitlements on an ad-hoc signature make AMFI kill the app.
# Checked last, so a bundle refused only for being ad-hoc signed passed every
# check above (the release dry run relies on that).
SIGNATURE_INFO="$(codesign -d --verbose=2 "$APP" 2>&1)" || die "codesign cannot describe the signature of $APP."
if grep -qx 'Signature=adhoc' <<< "$SIGNATURE_INFO"; then
    die "$APP is ad-hoc signed; entitlements need a real signing identity."
fi

echo "check-release-entitlements: $APP is signed with exactly the entitlements in $EXPECTED:"
jq -r 'keys[] | "  " + .' "$WORK/expected.json"
echo "check-release-entitlements: its embedded provisioning profile is for $APP_ID, expires $EXPIRES, and grants every one of them."
