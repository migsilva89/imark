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
# The two plists carry the version twice: CFBundleShortVersionString, which is
# the one people say out loud, and CFBundleVersion, the build number underneath
# it. Both are written to the same value on purpose. Left alone, the build
# number stayed at 1 forever, and the About panel — and therefore every bug
# report copied out of it — read "0.4.0 (1)", where the "(1)" told nobody
# anything. Equal numbers make macOS show the version on its own.
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

	# The build number is only in the plists, and only ever wrong by being
	# left behind, so it is checked against the version rather than listed
	# separately.
	for f in "${FILES[@]:0:2}"; do
		BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$f")"
		[ "$BUILD" = "$APP" ] || MISMATCH="$MISMATCH $f(build)=$BUILD"
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
		// A plist says it twice — the version and the build number under it —
		// and both are set to the same string. A manifest says it once.
		const plist = [
			/(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/,
			/(<key>CFBundleVersion<\/key>\s*<string>)[^<]*(<\/string>)/,
		]
		const json = [/("version"\s*:\s*")[^"]*(")/]
		const patterns = plist[0].test(text) ? plist : json
		let out = text
		for (const pattern of patterns) {
			const matches = out.match(new RegExp(pattern.source, "g")) || []
			if (matches.length !== 1) {
				console.error(`${file}: expected one ${pattern.source}, found ${matches.length}`)
				process.exit(1)
			}
			out = out.replace(pattern, `$1${version}$2`)
		}
		fs.writeFileSync(file, out)
	' "$f" "$VERSION"
done

printf '\033[1;32m✓ %s in the app, Quick Look, the plugin and the marketplace\033[0m\n' "$VERSION"
echo "  next: git commit -am \"$VERSION\" && git push, then ./release.sh"
