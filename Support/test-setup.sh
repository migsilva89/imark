#!/bin/bash
#
# Installs the Claude Code files and removes them again, in a throwaway home.
#
#   Support/test-setup.sh
#
# Never in the real one: this writes into ~/.claude, and a test that touched
# somebody's actual configuration to prove it works would be the bug.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${IMARK_APP:-/Applications/Imark.app}"
if [ ! -d "$APP/Contents/Resources/agent" ]; then
  echo "FALHA $APP não tem os ficheiros do agente — corre ./build.sh primeiro"
  exit 1
fi

swiftc -parse-as-library Sources/Imark/AgentSetup.swift Support/test-setup.swift \
  -o /tmp/imark-setup-test 2>/dev/null || { echo "FALHA não compilou"; exit 1; }

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
IMARK_TEST_HOME="$HOME_DIR" \
IMARK_TEST_RESOURCES="$APP/Contents/Resources" \
  /tmp/imark-setup-test
