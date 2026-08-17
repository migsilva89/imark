#!/bin/bash
#
# Installs the agent files, brings them up to date, and removes them again, in a
# throwaway home.
#
#   Support/test-setup.sh
#
# Never in the real one: this writes into ~/.claude, and a test that touched
# somebody's actual configuration to prove it works would be the bug.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${IMARK_APP:-/Applications/Imark.app}"
if [ ! -d "$APP/Contents/Resources/agent" ]; then
  echo "FAIL $APP is missing the agent files — run ./build.sh first"
  exit 1
fi

swiftc -parse-as-library Sources/Imark/AgentSetup.swift Support/test-setup.swift \
  -o /tmp/imark-setup-test 2>/dev/null || { echo "FAIL did not compile"; exit 1; }

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT

# The bundle the test reads from is a copy of the app's. Checking the refresh
# means playing the app carrying something newer than what is on disk, which is
# editing the bundle — and the app in /Applications is not the test's to edit.
mkdir -p "$HOME_DIR/Resources"
cp -R "$APP/Contents/Resources/agent" "$HOME_DIR/Resources/agent"

# One real file from a past release, carrying the path an app installed
# somewhere else would have written into it. That is the case in the bug report
# and the case the manifest of shipped hashes exists for, so the test uses the
# genuine article rather than a stand-in. Skipped where the tags are not there,
# a shallow clone for instance, because a missing tag is not a failure.
if git show v0.2.3:plugin/commands/imark-notes.md > "$HOME_DIR/old-notes.md" 2>/dev/null; then
  sed -i '' \
    's|"${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs"|"/Applications/Imark.app/Contents/Resources/agent/imark.mjs"|' \
    "$HOME_DIR/old-notes.md"
  export IMARK_TEST_OLD_NOTES="$HOME_DIR/old-notes.md"
else
  echo "note: no v0.2.3 tag here, so the past-release check is skipped"
fi

IMARK_TEST_HOME="$HOME_DIR" \
IMARK_TEST_RESOURCES="$HOME_DIR/Resources" \
  /tmp/imark-setup-test
