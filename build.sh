#!/bin/bash
# Builds Imark.app and installs it so Launch Services picks up the file
# associations and the Quick Look extension.
#
#   ./build.sh            build + install to ~/Applications
#   ./build.sh --no-install   build into dist/ only
#   ./build.sh --debug        debug configuration (faster compile)

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

CONFIG="release"
INSTALL=1
# A side-by-side build with its own name and bundle id, so work in progress
# never replaces the copy you actually use.
DEV=0
for arg in "$@"; do
	case "$arg" in
		--debug) CONFIG="debug" ;;
		--no-install) INSTALL=0 ;;
		--dev) DEV=1; CONFIG="debug" ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

if [ "$DEV" -eq 1 ]; then
	APP_NAME="Imark Dev"
	BUNDLE_ID="pt.miguelsilva.imark.dev"
else
	APP_NAME="Imark"
	BUNDLE_ID="pt.miguelsilva.imark"
fi

APP="$ROOT/dist/$APP_NAME.app"
INSTALL_DIR="${IMARK_INSTALL_DIR:-/Applications}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Ad-hoc is enough for this machine. Set IMARK_SIGN_IDENTITY to a Developer ID
# ("Developer ID Application: Name (TEAMID)") to produce a build that runs on
# someone else's Mac without Gatekeeper complaining.
SIGN_IDENTITY="${IMARK_SIGN_IDENTITY:--}"

step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- renderer

# Resources/ is generated, so a fresh clone has no bundle at all. Skipping the
# renderer here used to be a warning, which meant a clean checkout could build,
# sign and ship an app that renders nothing, with no sign anything went wrong.
if [ ! -d "$ROOT/renderer/node_modules" ]; then
	echo "error: renderer/node_modules is missing — the app would ship without" >&2
	echo "       its renderer and show a blank window. Run:" >&2
	echo "           cd renderer && npm ci" >&2
	exit 1
fi

step "renderer (esbuild)"
(cd "$ROOT/renderer" && node build.mjs)
# Generated from what esbuild actually bundled, so the notices cannot drift
# from the binary they have to travel with.
node "$ROOT/Support/licences.mjs"

# ------------------------------------------------------------------ swift

step "swift build ($CONFIG)"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

# --------------------------------------------------------------- assemble

step "assemble $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/PlugIns/ImarkQuickLook.appex/Contents/MacOS"

cp "$BIN/Imark" "$APP/Contents/MacOS/Imark"
cp "$ROOT/Support/Imark-Info.plist" "$APP/Contents/Info.plist"
if [ "$DEV" -eq 1 ]; then
	# Renamed and re-identified in place: two bundles with the same id would
	# fight over Launch Services and you would never know which one opened.
	/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" \
		-c "Set :CFBundleDisplayName $APP_NAME" \
		-c "Set :CFBundleIdentifier $BUNDLE_ID" \
		"$APP/Contents/Info.plist" >/dev/null
	# Handler rank is left alone: both builds stay "Alternate", so the dev copy
	# shows up in Open With for testing without ever stealing the default.
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -d "$ROOT/Resources" ]; then
	cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
fi
# The one file the window is useless without, checked in the assembled bundle
# rather than in the tree it was copied from.
[ -f "$APP/Contents/Resources/bundle.js" ] \
	|| { echo "error: the bundle is not in the app — the renderer did not build" >&2; exit 1; }
if [ -f "$ROOT/Support/AppIcon.icns" ]; then
	cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "warning: no icon — run 'swift Support/make-icon.swift'" >&2
fi

# The agent integration travels inside the app: the script that does the work,
# and the skill and commands that point a coding agent at it. One source — the
# same files the plugin ships — so the two can never drift apart, and the paths
# inside them are rewritten to this bundle when somebody installs them.
mkdir -p "$APP/Contents/Resources/agent/commands"
cp "$ROOT/plugin/scripts/imark.mjs" "$APP/Contents/Resources/agent/imark.mjs"
cp "$ROOT/plugin/skills/imark-comments/SKILL.md" "$APP/Contents/Resources/agent/SKILL.md"
cp "$ROOT"/plugin/commands/*.md "$APP/Contents/Resources/agent/commands/"

# The app rewrites those copies on the first launch of a new version, and it has
# to know which files out there are its own before it overwrites anything. So
# every version it ships gets its hash recorded here, once, and the record
# travels in the bundle. A build that forgot this would ship an app that
# recognises nothing and therefore refreshes nothing.
SHIPPED="$ROOT/Support/shipped-agent-files.txt"
record_shipped() {
	local name="$1" file="$2" hash
	hash="$(shasum -a 256 "$file" | cut -d' ' -f1)"
	grep -qF "$hash  $name" "$SHIPPED" || printf '%s  %s\n' "$hash" "$name" >> "$SHIPPED"
}
record_shipped "SKILL.md" "$ROOT/plugin/skills/imark-comments/SKILL.md"
for command in "$ROOT"/plugin/commands/*.md; do
	record_shipped "commands/$(basename "$command")" "$command"
done
cp "$SHIPPED" "$APP/Contents/Resources/agent/shipped.txt"

# macOS shows Credits.html in the standard About panel on its own, so the
# third-party notices travel with the binary without a line of UI code.
if [ -f "$ROOT/Support/Credits.html" ]; then
	cp "$ROOT/Support/Credits.html" "$APP/Contents/Resources/Credits.html"
fi

APPEX="$APP/Contents/PlugIns/ImarkQuickLook.appex"
cp "$BIN/ImarkQuickLook" "$APPEX/Contents/MacOS/ImarkQuickLook"
cp "$ROOT/Support/QuickLook-Info.plist" "$APPEX/Contents/Info.plist"
if [ "$DEV" -eq 1 ]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.quicklook" \
		-c "Set :CFBundleDisplayName $APP_NAME Quick Look" \
		"$APPEX/Contents/Info.plist" >/dev/null
fi

# The extension is sandboxed and cannot count on reading the containing app's
# Resources, so it gets its own copy of the renderer.
mkdir -p "$APPEX/Contents/Resources"
if [ -d "$ROOT/Resources" ]; then
	cp -R "$ROOT/Resources/." "$APPEX/Contents/Resources/"
fi

# ----------------------------------------------------------------- sign

# Inner bundles must be sealed before the outer one, or the outer signature
# is invalidated the moment the extension changes.
if [ "$SIGN_IDENTITY" = "-" ]; then
	step "sign (ad-hoc)"
	TIMESTAMP="--timestamp=none"
	EXTRA=""
else
	step "sign ($SIGN_IDENTITY)"
	TIMESTAMP="--timestamp"
	EXTRA="--options=runtime"
fi

# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP $EXTRA \
	--entitlements "$ROOT/Support/QuickLook.entitlements" "$APPEX" >/dev/null 2>&1
# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP $EXTRA "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && echo "signature ok"

# --------------------------------------------------------------- install

if [ "$INSTALL" -eq 1 ]; then
	step "install into $INSTALL_DIR"
	mkdir -p "$INSTALL_DIR"
	# A stale copy confuses Launch Services more than a missing one.
	rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
	cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"

	step "register with Launch Services"
	"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"
	echo "registered"
	printf '\n\033[1;32m✓ %s installed at %s\033[0m\n' "$APP_NAME" "$INSTALL_DIR/$APP_NAME.app"
else
	printf '\n\033[1;32m✓ %s\033[0m\n' "$APP"
fi
