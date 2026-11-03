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

# --------------------------------------------- the agent files, as an agent runs them

# The skill and commands tell the agent to ask `command -v imark`, run `imark`
# when that finds it, and run the script inside the app (or the plugin) only
# when it does not — never after `imark` has run, whatever it returned. Below,
# the three lines are taken verbatim out of the files and run in a clean
# environment, and this script applies that rule between them. That proves the
# lines and the rule; whether a real agent follows the rule is not something a
# shell test can show.

# Installed by the app, from a bundle in a folder with a space in its name.
SPACED="$HOME_DIR/My Apps/Imark.app/Contents/Resources"
mkdir -p "$SPACED"
cp "$CLI" "$SPACED/imark"
cp -R "$APP/Contents/Resources/agent" "$SPACED/agent"
AGENT_HOME="$HOME_DIR/agent home"
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.codex"
IMARK_TEST_HOME="$AGENT_HOME" IMARK_TEST_RESOURCES="$SPACED" "$CLI" skills install >/dev/null
check "the app installs the files into a fixture home" $?
cmp -s "$AGENT_HOME/.codex/skills/imark-comments/SKILL.md" \
  "$AGENT_HOME/.claude/skills/imark-comments/SKILL.md"
check "Claude Code and Codex got the same skill" $?

# The plugin, as Claude Code loads it: a copy of plugin/ somewhere with a space
# in its path, and ${CLAUDE_PLUGIN_ROOT} replaced by that path.
ROOT_DIR="$HOME_DIR/plugin cache/imark"
mkdir -p "$ROOT_DIR" "$HOME_DIR/plugin view"
cp -R plugin/. "$ROOT_DIR"
for template in plugin/commands/imark-review.md plugin/commands/imark-notes.md \
  plugin/skills/imark-comments/SKILL.md; do
  text="$(cat "$template")"
  printf '%s\n' "${text//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT_DIR}" > "$HOME_DIR/plugin view/${template##*/}"
done
# The installer finds the script path again only where it is quoted, so a bare
# placeholder would make every installed copy look edited and stop it updating.
ALL="$(cat plugin/commands/*.md plugin/skills/imark-comments/SKILL.md | grep -o 'CLAUDE_PLUGIN_ROOT' | wc -l)"
QUOTED="$(cat plugin/commands/*.md plugin/skills/imark-comments/SKILL.md \
  | grep -o '"${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs"' | wc -l)"
[ "$ALL" -gt 0 ] && [ "$ALL" -eq "$QUOTED" ]
check "every placeholder in the templates is the quoted script path" $?
grep -qF 'node \"${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs\" plan-hook' plugin/hooks/hooks.json
check "the plan hook still runs the plugin's own script" $?

line() { grep -m1 "^$2" "$1"; }   # line <file> <prefix> → the first line starting so
for set in "installed|$AGENT_HOME/.claude/commands|$AGENT_HOME/.codex/skills/imark-comments|$SPACED/agent" \
  "plugin|$HOME_DIR/plugin view|$HOME_DIR/plugin view|$ROOT_DIR/scripts"; do
  IFS='|' read -r name commands skill script <<< "$set"
  for file in "$commands/imark-review.md|review|\$ARGUMENTS" "$commands/imark-notes.md|notes|\$ARGUMENTS" \
    "$skill/SKILL.md|notes|<file.md>"; do
    IFS='|' read -r path verb args <<< "$file"
    [ "$(line "$path" 'command ')" = 'command -v imark' ] \
      && [ "$(line "$path" 'imark ')" = "imark $verb $args" ] \
      && [ "$(line "$path" 'node ')" = "node \"$script/imark.mjs\" $verb $args" ]
    check "$name ${path##*/}: looks, runs imark, else the quoted script" $?
  done
done

DOCS="$HOME_DIR/docs with space"
mkdir -p "$DOCS"
DOC="$DOCS/it's a plan (v2).md"
printf '# T\n\nOpen line.\n\n<!-- imark quote="Open line" by="m" at="2026-08-27T10:00Z"\nStill open.\n-->\n\nDone line.\n\n<!-- imark quote="Done line" by="m" at="2026-08-27T10:00Z" resolved="2026-08-28"\nAlready done.\n-->\n' \
  > "$DOC"

# Every directory put on a PATH below. The base has only the system and node,
# and is checked to have no imark of its own: the missing cases mean nothing if
# some other imark answers them.
NODE_DIR="$(dirname "$(command -v node)")"
BASE="/usr/bin:/bin:$NODE_DIR"
WITH="$HOME_DIR/bin with space"
WITHOUT="$HOME_DIR/empty bin"
DANGLING="$HOME_DIR/moved bin"
FAILS127="$HOME_DIR/bin failing 127"
FAILS3="$HOME_DIR/bin failing 3"
mkdir -p "$WITH" "$WITHOUT" "$DANGLING" "$FAILS127" "$FAILS3"
ln -s "$SPACED/imark" "$WITH/imark"
ln -s "$HOME_DIR/gone/Imark.app/Contents/Resources/imark" "$DANGLING/imark"
# An imark that is there and fails — including with 127, the status a shell
# also uses for a command it cannot find.
for code in 127 3; do
  dir="$FAILS3"; [ "$code" = 127 ] && dir="$FAILS127"
  printf '#!/bin/sh\necho "imark: failing on purpose" >&2\nexit %s\n' "$code" > "$dir/imark"
  chmod +x "$dir/imark"
done
env -i PATH="$BASE" /bin/bash -c 'command -v imark' >/dev/null
[ $? -ne 0 ]; check "the base PATH has no imark of its own" $?
# Nothing from the caller's environment either: no BASH_ENV, no zsh startup.
snippet() {   # snippet <shell> <PATH> <file> <prefix> <arguments> → runs that line
  local text; text="$(line "$3" "$4")"
  text="${text//\$ARGUMENTS/$5}"
  text="${text//<file.md>/$5}"
  env -i HOME="$HOME_DIR" PATH="$2" IMARK_TEST_NO_OPEN=1 IMARK_PENDING_DIR="$PENDING" \
    $1 -c "$text"   # $1 may carry a flag: zsh -f
}
follow() {   # follow <shell> <PATH> <file> <arguments> → the rule the files state
  if snippet "$1" "$2" "$3" 'command ' '' >/dev/null; then
    echo imark > "$HOME_DIR/route"
    snippet "$1" "$2" "$3" 'imark ' "$4"
  else
    echo script > "$HOME_DIR/route"
    snippet "$1" "$2" "$3" 'node ' "$4"
  fi
}
route() { cat "$HOME_DIR/route"; }
requests() { ls "$PENDING"/*.json 2>/dev/null | wc -l | tr -d ' '; }
ARGS="\"$DOC\" --all"   # what the user typed after the slash command
PENDING="$HOME_DIR/pending"

for name in installed plugin; do
  if [ "$name" = installed ]; then
    NOTES_MD="$AGENT_HOME/.claude/commands/imark-notes.md"
    REVIEW_MD="$AGENT_HOME/.claude/commands/imark-review.md"
    SKILL_MD="$AGENT_HOME/.codex/skills/imark-comments/SKILL.md"
  else
    NOTES_MD="$HOME_DIR/plugin view/imark-notes.md"
    REVIEW_MD="$HOME_DIR/plugin view/imark-review.md"
    SKILL_MD="$HOME_DIR/plugin view/SKILL.md"
  fi
  for shell in bash "zsh -f"; do
    s="$name, ${shell% -f}"
    OUT="$(follow "$shell" "$WITH:$BASE" "$NOTES_MD" "$ARGS")"; CODE=$?
    [ "$CODE" -eq 0 ] && [ "$(route)" = imark ] && [[ "$OUT" == *'Still open.'* ]] \
      && [[ "$OUT" == *'Already done.'* ]]
    check "$s, imark on the PATH: it runs, with a spaced quoted path and --all" $?
    EXPECTED="$OUT"
    OUT="$(follow "$shell" "$WITH:$BASE" "$SKILL_MD" "\"$DOC\"")"
    [ "$(route)" = imark ] && [[ "$OUT" == *'Still open.'* ]] && [[ "$OUT" != *'Already done.'* ]]
    check "$s, the skill's line: no --all, no resolved note" $?
    for bin in "$WITHOUT" "$DANGLING"; do
      b="$(basename "$bin")"
      OUT="$(follow "$shell" "$bin:$BASE" "$NOTES_MD" "$ARGS")"; CODE=$?
      [ "$CODE" -eq 0 ] && [ "$(route)" = script ] && [ "$OUT" = "$EXPECTED" ]
      check "$s, $b: command -v finds nothing, the script gives the same notes" $?
    done
    for case in "$FAILS127|127" "$FAILS3|3"; do
      bin="${case%|*}" want="${case#*|}"
      OUT="$(follow "$shell" "$bin:$BASE" "$NOTES_MD" "$ARGS" 2>&1)"; CODE=$?
      [ "$CODE" -eq "$want" ] && [ "$(route)" = imark ] && [[ "$OUT" == *'failing on purpose'* ]] \
        && [[ "$OUT" != *'Still open.'* ]]
      check "$s, imark found but exits $want: that is the answer, the script never runs" $?
    done
    OUT="$(follow "$shell" "$WITH:$BASE" "$NOTES_MD" "\"$DOCS/not there.md\"" 2>&1)"; CODE=$?
    [ "$CODE" -ne 0 ] && [ "$(route)" = imark ]
    check "$s, the real imark failing on a missing file is not retried" $?
  done

  # Reviews, never opening a window: --no-wait leaves the request in a pending
  # folder of the test's own and returns.
  for case in "$WITH|imark|1" "$WITHOUT|script|1" "$DANGLING|script|1" "$FAILS127|imark|0" "$FAILS3|imark|0"; do
    IFS='|' read -r bin want count <<< "$case"
    b="$(basename "$bin")"
    rm -rf "$PENDING"
    OUT="$(follow bash "$bin:$BASE" "$REVIEW_MD" "\"$DOC\" --no-wait" 2>&1)"; CODE=$?
    if [ "$count" = 1 ]; then
      [ "$CODE" -eq 0 ] && [[ "$OUT" == *"$DOC"* ]]
    else
      [ "$CODE" -ne 0 ]
    fi && [ "$(route)" = "$want" ] && [ "$(requests)" = "$count" ]
    check "$name review, $b: via $want, $count request(s)" $?
  done
done
rm -rf "$PENDING"

echo
if [ "$failures" -eq 0 ]; then echo "all good"; else echo "$failures failing"; fi
[ "$failures" -eq 0 ]
