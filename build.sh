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
		*) echo "opção desconhecida: $arg" >&2; exit 2 ;;
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

if [ -d "$ROOT/renderer/node_modules" ]; then
	step "renderer (esbuild)"
	(cd "$ROOT/renderer" && node build.mjs)
	# Generated from what esbuild actually bundled, so the notices cannot drift
	# from the binary they have to travel with.
	node "$ROOT/Support/licences.mjs"
else
	echo "aviso: renderer/node_modules em falta — a saltar o bundle JS" >&2
fi

# ------------------------------------------------------------------ swift

step "swift build ($CONFIG)"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

# --------------------------------------------------------------- assemble

step "montar $APP_NAME.app"
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
if [ -f "$ROOT/Support/AppIcon.icns" ]; then
	cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "aviso: sem ícone — corre 'swift Support/make-icon.swift'" >&2
fi

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
	step "assinar (ad-hoc)"
	TIMESTAMP="--timestamp=none"
	EXTRA=""
else
	step "assinar ($SIGN_IDENTITY)"
	TIMESTAMP="--timestamp"
	EXTRA="--options=runtime"
fi

# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP $EXTRA \
	--entitlements "$ROOT/Support/QuickLook.entitlements" "$APPEX" >/dev/null 2>&1
# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP $EXTRA "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && echo "assinatura ok"

# --------------------------------------------------------------- install

if [ "$INSTALL" -eq 1 ]; then
	step "instalar em $INSTALL_DIR"
	mkdir -p "$INSTALL_DIR"
	# A stale copy confuses Launch Services more than a missing one.
	rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
	cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"

	step "registar no Launch Services"
	"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"
	echo "registado"
	printf '\n\033[1;32m✓ %s instalado em %s\033[0m\n' "$APP_NAME" "$INSTALL_DIR/$APP_NAME.app"
else
	printf '\n\033[1;32m✓ %s\033[0m\n' "$APP"
fi
