#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASK="$TMP/imark.rb"

cp Support/testdata/imark-cask.rb "$CASK"
node Support/update-cask.mjs "$CASK" 0.5.0 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FIRST="$(shasum -a 256 "$CASK" | cut -d' ' -f1)"
node Support/update-cask.mjs "$CASK" 0.5.0 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

[ "$FIRST" = "$(shasum -a 256 "$CASK" | cut -d' ' -f1)" ]
grep -q '^  version "0.5.0"$' "$CASK"
grep -q '^  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"$' "$CASK"
[ "$(grep -c '^  auto_updates true$' "$CASK")" -eq 1 ]
[ "$(grep -c '^  binary "#{appdir}/Imark.app/Contents/Resources/imark"$' "$CASK")" -eq 1 ]

echo "tap update ok"
