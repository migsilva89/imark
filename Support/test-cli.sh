#!/bin/bash
#
# The `imark` command: the script itself, and the link that puts it on the PATH.
#
#   Support/test-cli.sh
#
# Needs an assembled app — the script it links to lives in the bundle. Installs
# into a throwaway home, never the real one.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${IMARK_APP:-dist/Imark.app}"
CLI="$APP/Contents/Resources/imark"
[ -x "$CLI" ] || { echo "FAIL $CLI is missing — run ./build.sh first"; exit 1; }

failures=0
check() {
  if [ "$2" = "0" ]; then echo "OK   $1"; else failures=$((failures + 1)); echo "FAIL $1"; fi
}

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
export IMARK_TEST_HOME="$HOME_DIR"

# ------------------------------------------------------------- the script

"$CLI" --help >/dev/null 2>&1; check "--help explains itself" $?
V="$("$CLI" --version 2>/dev/null)"
[ -n "$V" ]; check "--version answers with the app's own version" $?

# `open` reports a missing file by launching the app with an empty window, which
# looks like it worked. The check has to happen here or not at all.
"$CLI" "$HOME_DIR/not-there.md" >/dev/null 2>&1
[ $? -ne 0 ]; check "a missing file is an error, not a blank window" $?

"$CLI" --nonsense >/dev/null 2>&1
[ $? -eq 2 ]; check "an unknown option says so" $?

# Reached through a link, as it always is once installed: the script has to
# find its own bundle from wherever the link lives.
ln -s "$(cd "$(dirname "$CLI")" && pwd)/imark" "$HOME_DIR/imark"
[ "$("$HOME_DIR/imark" --version 2>/dev/null)" = "$V" ]
check "it finds its app through a symlink" $?

printf '# T\n\nA line.\n\n<!-- imark quote="A line" by="m" at="2026-08-27T10:00Z"\nA note.\n-->\n' \
  > "$HOME_DIR/doc.md"
"$CLI" notes "$HOME_DIR/doc.md" 2>/dev/null | grep -q "A note."
check "notes reaches the agent script in the bundle" $?

# --------------------------------------------------------------- skills

# Copy resources so simulating a newer release cannot alter the app under test.
mkdir -p "$HOME_DIR/Resources"
cp -R "$APP/Contents/Resources/agent" "$HOME_DIR/Resources/agent"
export IMARK_TEST_RESOURCES="$HOME_DIR/Resources"
"$CLI" skills --help | grep -q 'Exit codes:'
check "skills help documents exit codes" $?
"$CLI" --help | grep -q 'imark skills'
check "main help includes skills" $?
"$CLI" skills --force >/dev/null 2>&1
[ $? -eq 2 ]; check "unsupported force is rejected" $?
"$CLI" skills install extra >/dev/null 2>&1
[ $? -eq 2 ]; check "extra arguments are rejected" $?
OUTPUT="$("$HOME_DIR/imark" skills)"; CODE=$?
[ "$CODE" -eq 1 ] && [[ "$OUTPUT" == *'Claude Code: not found'* ]] && [[ "$OUTPUT" == *'Codex: not found'* ]]
check "empty home reports absent agents through the symlink" $?
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$HOME_DIR/.cursor"
printf 'keep settings' > "$HOME_DIR/.claude/settings.json"
OUTPUT="$("$CLI" skills)"; CODE=$?
[ "$CODE" -eq 1 ] && [[ "$OUTPUT" == *'SKILL.md: missing'* ]] && [[ "$OUTPUT" == *'Cursor: present (not supported)'* ]]
check "missing skills and unsupported agents are reported" $?
"$CLI" skills update >/dev/null
[ $? -eq 1 ] && [ ! -e "$HOME_DIR/.codex/skills" ]
check "update does not install missing files" $?
"$CLI" skills install >/dev/null; check "install succeeds" $?
OUTPUT="$("$CLI" skills)"; CODE=$?
[ "$CODE" -eq 0 ] && [[ "$OUTPUT" == *'SKILL.md: current'* ]] && [[ "$OUTPUT" != *': missing'* ]]
check "installed skills and commands are current" $?
printf '\nNew release.\n' >> "$HOME_DIR/Resources/agent/SKILL.md"
OUTPUT="$("$CLI" skills)"; CODE=$?
[ "$CODE" -eq 1 ] && [[ "$OUTPUT" == *'SKILL.md: outdated'* ]]
check "shipped copies become outdated" $?
printf 'My instructions\n' > "$HOME_DIR/.claude/skills/imark-comments/SKILL.md"
OUTPUT="$("$CLI" skills update)"; CODE=$?
[ "$CODE" -eq 0 ] && [[ "$OUTPUT" == *'Updated 1 file(s).'* ]] && [[ "$OUTPUT" == *'Kept edited file:'* ]]
check "update refreshes old copies and reports edits kept" $?
"$CLI" skills install >/dev/null
[ "$(cat "$HOME_DIR/.claude/skills/imark-comments/SKILL.md")" = 'My instructions' ]
check "install also preserves edits" $?
[ "$(cat "$HOME_DIR/.claude/settings.json")" = 'keep settings' ] && [ ! -e "$HOME_DIR/.claude/plugins" ] && [ ! -e "$HOME_DIR/.codex/commands" ]
check "settings and plugin directories are untouched" $?
rm "$HOME_DIR/Resources/agent/imark.mjs"
"$CLI" skills >/dev/null 2>&1
[ $? -eq 1 ]; check "missing bundle resources fail cleanly" $?
unset IMARK_TEST_RESOURCES

# --------------------------------------------------------------- the link

swiftc -parse-as-library Sources/Imark/CommandLineTool.swift Support/test-cli.swift \
  -o /tmp/imark-cli-test 2>/dev/null || { echo "FAIL did not compile"; exit 1; }

IMARK_TEST_HOME="$HOME_DIR" \
IMARK_TEST_RESOURCES="$(cd "$(dirname "$CLI")" && pwd)" \
  /tmp/imark-cli-test
[ $? -eq 0 ] || failures=$((failures + 1))

echo
if [ "$failures" -eq 0 ]; then echo "all good"; else echo "$failures failing"; fi
[ "$failures" -eq 0 ]
