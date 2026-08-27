#!/bin/bash
# The assembled app contains a loadable, signed Sparkle framework and the
# immutable public half of the key that verifies every update.

set -uo pipefail
cd "$(dirname "$0")/.."

APP="${IMARK_APP:-dist/Imark.app}"
INFO="$APP/Contents/Info.plist"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
failures=0

check() {
	local name="$1"
	shift
	if "$@"; then echo "OK   $name"; else failures=$((failures + 1)); echo "FAIL $name"; fi
}

check "Sparkle is embedded" test -f "$FRAMEWORK/Versions/B/Sparkle"
check "the updater is embedded" test -d "$FRAMEWORK/Versions/B/Updater.app"
check "unused sandbox services are absent" test ! -e "$FRAMEWORK/XPCServices"
check "the framework and its helpers are signed" codesign --verify --deep --strict "$FRAMEWORK"
check "the app can find the embedded framework" sh -c \
	"otool -l '$APP/Contents/MacOS/Imark' | grep -q '@loader_path/../Frameworks'"
check "the feed has one stable address" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' '$INFO')\" = \
	'https://github.com/migsilva89/imark/releases/latest/download/appcast.xml'"
check "updates require the public signing key" sh -c \
	"test -n \"\$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' '$INFO')\""
check "the archive is verified before extraction" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' '$INFO')\" = true"
check "the feed itself must also be signed" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' '$INFO')\" = true"

echo
if [ "$failures" -eq 0 ]; then echo "all good"; else echo "$failures failing"; fi
[ "$failures" -eq 0 ]
