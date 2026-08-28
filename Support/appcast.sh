#!/bin/bash
# Signs one finished disk image and writes the Sparkle feed published beside it.
# The private EdDSA key stays in the login keychain under the `imark` account;
# only its public half is in the app's Info.plist.
#
# The feed points at a second, identically-built copy of the image, published
# under the `-update` name. Same bytes, same signature, different GitHub asset —
# which is the only way to tell an update apart from a first install, since
# GitHub counts downloads per asset and nothing else.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Imark-Info.plist)"
DMG="${1:-$ROOT/dist/Imark-$VERSION.dmg}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE="$TOOLS/generate_appcast"
KEYS="$TOOLS/generate_keys"
OUTPUT="$ROOT/dist/appcast.xml"
UPDATE_DMG="$ROOT/dist/Imark-$VERSION-update.dmg"

[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -x "$GENERATE" ] || {
	echo "error: Sparkle's release tools are missing — run swift package resolve" >&2
	exit 1
}

EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Support/Imark-Info.plist)"
ACTUAL="$("$KEYS" --account imark -p)"
[ "$ACTUAL" = "$EXPECTED" ] || {
	echo "error: the Sparkle key in the keychain does not match the app" >&2
	exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DMG" "$STAGE/$(basename "$UPDATE_DMG")"

"$GENERATE" \
	--account imark \
	--download-url-prefix "https://github.com/migsilva89/imark/releases/download/v$VERSION/" \
	--full-release-notes-url "https://imarkmd.com/changelog" \
	--link "https://imarkmd.com" \
	--maximum-versions 1 \
	--maximum-deltas 0 \
	-o "$STAGE/appcast.xml" \
	"$STAGE"

cp "$STAGE/appcast.xml" "$OUTPUT"
cp "$DMG" "$UPDATE_DMG"
xmllint --noout "$OUTPUT"
grep -q 'sparkle:edSignature=' "$OUTPUT" \
	|| { echo "error: the update in appcast.xml is not signed" >&2; exit 1; }
grep -q '<!-- sparkle-signatures:' "$OUTPUT" \
	|| { echo "error: appcast.xml itself is not signed" >&2; exit 1; }
grep -q "$(basename "$UPDATE_DMG")" "$OUTPUT" \
	|| { echo "error: the feed does not point at the update copy" >&2; exit 1; }

echo "update feed → $OUTPUT"
echo "update image → $UPDATE_DMG"
