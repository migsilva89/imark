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
APPCAST="$ROOT/dist/appcast.xml"

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

	# The app, the Quick Look extension and the two plugin manifests all carry
	# the version, and nothing complains when one of them stays behind — the
	# marketplace just keeps offering an old number for a new build.
	Support/bump.sh --check >/dev/null \
		|| die "the version is not the same in every file — see above"

	# The suites, because a signed and notarised broken build is worse than an
	# unsigned one: it carries somebody's name and opens without a warning.
	# The web-view suites exercise the generated bundle, not renderer/src. Build
	# it first so a clean checkout cannot test whatever Resources/ happened to
	# contain from an older branch.
	(cd renderer && node build.mjs) >/dev/null 2>&1 \
		|| die "the renderer failed to build"
	swiftc -parse-as-library Sources/Imark/Comments.swift Sources/Imark/NoteColour.swift \
		Support/test-comments.swift -o /tmp/imark-release-test >/dev/null 2>&1 \
		&& /tmp/imark-release-test >/dev/null || die "the comment tests failed"
	node Support/test-export.mjs >/dev/null 2>&1 || die "the export test failed"
	node Support/test-notes.mjs >/dev/null 2>&1 || die "the note anchoring tests failed"
	node Support/test-invocation.mjs >/dev/null 2>&1 || die "the plugin invocation tests failed"
	node Support/test-math.mjs >/dev/null 2>&1 || die "the math tests failed"
	Support/test-tap.sh >/dev/null 2>&1 || die "the Homebrew cask tests failed"
	swift build >/dev/null 2>&1
	TEST_BIN="$(swift build --show-bin-path)"
	swiftc -parse-as-library -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
			-Xlinker -rpath -Xlinker "$TEST_BIN" \
			$(find Sources/Imark -name '*.swift' ! -name main.swift) \
			$(find Sources/ImarkRender -name '*.swift') \
			Support/test-undo.swift -o /tmp/imark-release-undo >/dev/null 2>&1 \
		&& /tmp/imark-release-undo >/dev/null || die "the undo tests failed"
	swiftc -parse-as-library -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
			-Xlinker -rpath -Xlinker "$TEST_BIN" \
			$(find Sources/Imark -name '*.swift' ! -name main.swift) \
			$(find Sources/ImarkRender -name '*.swift') \
			Support/test-editor.swift -o /tmp/imark-release-editor >/dev/null 2>&1 \
		&& /tmp/imark-release-editor >/dev/null || die "the editor tests failed"
	swift Support/test-plus.swift >/dev/null 2>&1 || die "the margin button tests failed"
	swift Support/test-pieces.swift >/dev/null 2>&1 || die "the list and table note tests failed"
	swift Support/test-front-matter.swift >/dev/null 2>&1 || die "the front matter tests failed"
	Support/test-review.sh >/dev/null 2>&1 || die "the review round trip tests failed"
	# test-setup.sh needs an assembled app, so it runs after the build instead.

	echo "clean tree, on main, in sync, tests pass"
fi

# ------------------------------------------------------------------- build

step "build"
if [ -n "$SIGN_IDENTITY" ]; then
	IMARK_SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh --no-install
else
	./build.sh --no-install
fi

# The install-and-remove suite, against the app that was just assembled rather
# than whatever happens to sit in /Applications on this machine.
if [ "${1:-}" != "--force" ]; then
	step "installer checks"
	IMARK_APP="$APP" Support/test-setup.sh >/dev/null 2>&1 \
		|| die "the agent setup tests failed"
	IMARK_APP="$APP" Support/test-cli.sh >/dev/null 2>&1 \
		|| die "the command line tests failed"
	IMARK_APP="$APP" Support/test-update.sh >/dev/null 2>&1 \
		|| die "the update bundle tests failed"
	echo "setup ok"
fi

# --------------------------------------------------------------------- dmg

step "disk image"
rm -rf "$STAGE" "$DMG"
rm -f "$APPCAST"
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
	step "sign the image"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

	if [ -z "$NOTARY_PROFILE" ]; then
		echo
		echo "warning: signed but not notarised. Set IMARK_NOTARY_PROFILE to have" >&2
		echo "       Apple stamp it — without that Gatekeeper still warns on" >&2
		echo "       somebody else's machine." >&2
	else
		# Waits for the verdict rather than returning a ticket to chase, and
		# staples it so the app opens on a machine with no network.
		step "notarise (this takes a while — Apple is looking at it)"
		xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$DMG"
		xcrun stapler validate "$DMG"

		step "update feed"
		Support/appcast.sh "$DMG"
	fi
fi

step "done"
printf '\033[1;32m✓ %s (%s)\033[0m\n' "$DMG" "$(du -h "$DMG" | cut -f1)"

# The one thing a built image does not do by itself. Homebrew reads a cask in
# another repository, and it goes on installing the previous version until that
# file is written — which is the one way somebody downloads an old Imark while
# being told it is the new one. The site is not on this list: imark-site reads
# the releases here twice an hour and rebuilds itself when the number moves.
if [ -f "$APPCAST" ]; then
	cat <<-EOF

	then, to publish:
	  gh release create v$VERSION "$DMG" "$APPCAST" --title "Imark $VERSION" --notes "…"
	  Support/tap.sh          point Homebrew at it
	EOF
else
	cat <<-EOF

	this build is for local testing. A signed and notarised release also writes
	$APPCAST, which must be published beside the disk image.
	EOF
fi
