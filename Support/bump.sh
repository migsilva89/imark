#!/bin/bash
# Sets the version everywhere it is written down.
#
#   Support/bump.sh 0.2.4     write it
#   Support/bump.sh --check   say whether the four agree, change nothing
#
# The version lives in four files: the app, the Quick Look extension, and the
# two manifests Claude Code reads to install the plugin. They are read by
# different things — Gatekeeper, Finder, the marketplace — and nothing notices
# when one of them falls behind. So one command writes all four, and the
# release gate refuses a build where they disagree.
#
# The site needs nothing: it reads the version, the notes and the .dmg size off
# the GitHub release. These four files are the part no server can work out.

set -euo pipefail
cd "$(dirname "$0")/.."

# Each file with the pattern that finds its version, and nothing else in it.
# Edited in place by regex rather than rewritten by PlistBuddy or JSON.stringify,
# because both of those reorder keys and drop comments — a diff nobody asked for
# on top of the one line that changed.
FILES=(
	"Support/Imark-Info.plist"
	"Support/QuickLook-Info.plist"
	"plugin/.claude-plugin/plugin.json"
	".claude-plugin/marketplace.json"
)

version_of() {
	node -e '
		const fs = require("fs")
		const text = fs.readFileSync(process.argv[1], "utf8")
		const m = text.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/)
			|| text.match(/"version"\s*:\s*"([^"]*)"/)
		if (!m) { console.error("no version in " + process.argv[1]); process.exit(1) }
		console.log(m[1])
	' "$1"
}

# ------------------------------------------------------------------- check

if [ "${1:-}" = "--check" ] || [ $# -eq 0 ]; then
	APP="$(version_of "${FILES[0]}")"
	MISMATCH=""
	for f in "${FILES[@]:1}"; do
		[ "$(version_of "$f")" = "$APP" ] || MISMATCH="$MISMATCH $f=$(version_of "$f")"
	done

	if [ -n "$MISMATCH" ]; then
		printf '\033[1;31m✗ the app says %s, but:%s\033[0m\n' "$APP" "$MISMATCH" >&2
		echo "  run Support/bump.sh $APP to bring them into line" >&2
		exit 1
	fi
	echo "$APP everywhere"
	exit 0
fi

# ------------------------------------------------------------------- write

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { echo "not a version: $VERSION (expected 1.2.3)" >&2; exit 1; }

for f in "${FILES[@]}"; do
	node -e '
		const fs = require("fs")
		const [file, version] = process.argv.slice(1)
		const text = fs.readFileSync(file, "utf8")
		// One replacement per file, and it fails loudly rather than writing a
		// file where the version silently stayed where it was.
		const plist = /(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/
		const json = /("version"\s*:\s*")[^"]*(")/
		const pattern = plist.test(text) ? plist : json
		const matches = text.match(new RegExp(pattern.source, "g")) || []
		if (matches.length !== 1) {
			console.error(`${file}: expected one version, found ${matches.length}`)
			process.exit(1)
		}
		fs.writeFileSync(file, text.replace(pattern, `$1${version}$2`))
	' "$f" "$VERSION"
done

printf '\033[1;32m✓ %s in the app, Quick Look, the plugin and the marketplace\033[0m\n' "$VERSION"
echo "  next: git commit -am \"$VERSION\" && git push, then ./release.sh"
