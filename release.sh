#!/bin/bash
# Builds a .dmg somebody else can install by dragging.
#
#   ./release.sh                                  unsigned — fine for a friend
#                                                 who will click through once
#   IMARK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./release.sh
#                                                 signed, ready to notarise
#   IMARK_NOTARY_PROFILE=imark ./release.sh        signed, notarised, stapled
#
# The notary profile is stored once, and never in this repository:
#
#   xcrun notarytool store-credentials imark \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
# Without a Developer ID the disk image still works. On macOS 15 and later the
# person opening it has to go to System Settings › Privacy & Security › Open
# Anyway the first time — Control-clicking no longer skips that.

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

SIGN_IDENTITY="${IMARK_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${IMARK_NOTARY_PROFILE:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Imark-Info.plist)"

APP="$ROOT/dist/Imark.app"
STAGE="$ROOT/dist/dmg"
DMG="$ROOT/dist/Imark-$VERSION.dmg"

step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------------- gate
#
# A release is the one build somebody else runs, so it is the one that must not
# come from a working tree only this machine has seen. Skipped with --force for
# the case where you know exactly what you are doing and why.

if [ "${1:-}" != "--force" ]; then
	step "checks"

	[ -z "$(git status --porcelain)" ] \
		|| die "uncommitted changes — a release has to be a commit somebody can go back to"

	BRANCH="$(git rev-parse --abbrev-ref HEAD)"
	[ "$BRANCH" = "main" ] || die "on $BRANCH, not main"

	git fetch --quiet origin main 2>/dev/null || true
	if git rev-parse --quiet --verify origin/main >/dev/null; then
		[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
			|| die "main and origin/main have diverged — push or pull first"
	fi

	# The suites, because a signed and notarised broken build is worse than an
	# unsigned one: it carries somebody's name and opens without a warning.
	swiftc -parse-as-library Sources/Imark/Comments.swift Sources/Imark/NoteColour.swift \
		Support/test-comments.swift -o /tmp/imark-release-test >/dev/null 2>&1 \
		&& /tmp/imark-release-test >/dev/null || die "the comment tests failed"
	node Support/test-export.mjs >/dev/null 2>&1 || die "the export test failed"

	echo "clean tree, on main, in sync, tests pass"
fi

# ------------------------------------------------------------------- build

step "build"
if [ -n "$SIGN_IDENTITY" ]; then
	IMARK_SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh --no-install
else
	./build.sh --no-install
fi

# --------------------------------------------------------------------- dmg

step "disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The symlink is the whole installer: drag the app onto it and it is installed.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
	-volname "Imark $VERSION" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null
rm -rf "$STAGE"

# ------------------------------------------------------------------ notarise

if [ -z "$SIGN_IDENTITY" ]; then
	echo
	echo "warning: without IMARK_SIGN_IDENTITY the image is not signed." >&2
	echo "       whoever opens it has to go to Settings › Privacy & Security" >&2
	echo "       › Open Anyway, once." >&2
else
	step "assinar a imagem"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

	if [ -z "$NOTARY_PROFILE" ]; then
		echo
		echo "warning: assinada mas não notarizada. Define IMARK_NOTARY_PROFILE" >&2
		echo "       para a Apple a carimbar — sem isso o Gatekeeper continua" >&2
		echo "       a avisar noutra máquina." >&2
	else
		# Waits for the verdict rather than returning a ticket to chase, and
		# staples it so the app opens on a machine with no network.
		step "notarizar (isto demora, é a Apple a olhar)"
		xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$DMG"
		xcrun stapler validate "$DMG"
	fi
fi

step "done"
printf '\033[1;32m✓ %s (%s)\033[0m\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
