#!/bin/bash
#
# The round trip: the plugin opens a review and waits, the app writes a decision,
# the plugin wakes up and produces what the agent will read.
#
#   Support/test-review.sh
#
# Everything here is the real code on both sides. The decision is written by
# Review.decide — the function the toolbar buttons call — rather than by a
# click, because posting a synthetic click needs accessibility permission that a
# terminal does not have. That one hop, button to selector, is the only part of
# this feature no test covers.

set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
check() {
  if [[ "$2" == *"$3"* ]]; then
    echo "OK   $1"
    pass=$((pass + 1))
  else
    echo "FAIL $1"
    fail=$((fail + 1))
  fi
}
refute() {
  if [[ "$2" == *"$3"* ]]; then
    echo "FAIL $1"
    fail=$((fail + 1))
  else
    echo "OK   $1"
    pass=$((pass + 1))
  fi
}

echo "▸ compiling the decider"
swiftc -parse-as-library \
  Sources/Imark/Review.swift Support/decide.swift \
  -o /tmp/imark-decide 2>/dev/null || {
    echo "FAIL did not compile"; exit 1;
  }

run() {   # run <decision> <notes-in-document>  → prints what the agent reads
  local decision="$1" note="$2"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  {
    echo "# Plan"
    echo
    echo "A paragraph that is going to be reviewed."
    echo
    if [[ -n "$note" ]]; then
      echo '<!-- imark quote="going to be reviewed" by="miguel" at="2026-08-03T15:00Z"'
      echo "$note"
      echo '-->'
    fi
  } > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!

  local review=""
  for _ in $(seq 1 40); do
    review="$(ls .imark/reviews/*.md 2>/dev/null | head -1)"
    [[ -n "$review" ]] && break
    sleep 0.25
  done
  if [[ -z "$review" ]]; then
    kill "$pid" 2>/dev/null
    echo "FAIL the review was never written"
    cd "$OLDPWD"; return 1
  fi

  /tmp/imark-decide "$review" "$decision" 1 > /dev/null
  wait "$pid"
  cat out.txt
  cd "$OLDPWD"
  rm -rf "$dir"
}

echo "▸ request changes"
out="$(run request-changes 'This is ambiguous and needs a number.')"
check "tells the agent it was not approved"    "$out" "THE REVIEWER DID NOT APPROVE THIS"
check "tells it not to rewrite yet"             "$out" "Do not rewrite anything yet"
check "tells it to ask when unsure"    "$out" "Do not guess"
check "carries the note I wrote"               "$out" "This is ambiguous"
check "and the phrase it refers to"         "$out" "going to be reviewed"
refute "does not call it an orphan"                   "$out" "Orphan"

echo "▸ approve"
out="$(run approve 'A note to take into account.')"
check "tells the agent it was approved"        "$out" "APPROVED"
check "and passes the notes anyway"         "$out" "A note to take into account"
refute "without the order to rewrite"            "$out" "DID NOT APPROVE"

echo "▸ the plan-mode hook"

hook() {   # hook <on|off> <decision> → prints the JSON Claude Code reads
  local gate="$1" decision="$2"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  # The shape Claude Code puts on stdin when ExitPlanMode asks for permission.
  node -e 'require("fs").writeFileSync("ev.json", JSON.stringify({
    tool_input: { plan: "# Plan\n\nA step that is going to be reviewed.\n" },
    cwd: process.cwd(),
  }))'

  if [[ "$gate" == off ]]; then
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json
    cd "$OLDPWD"; rm -rf "$dir"; return
  fi

  IMARK_TEST_NO_OPEN=1 IMARK_PLAN_REVIEW=1 \
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json > out.json 2>/dev/null &
  local pid=$!
  local review=""
  for _ in $(seq 1 40); do
    review="$(ls .imark/reviews/*.md 2>/dev/null | head -1)"
    [[ -n "$review" ]] && break
    sleep 0.25
  done
  [[ -n "$review" ]] && /tmp/imark-decide "$review" "$decision" 0 > /dev/null
  wait "$pid"
  cat out.json
  cd "$OLDPWD"; rm -rf "$dir"
}

# A note is a note. The fallback words end a review, and everything else has to
# leave it running — an ordinary English word quoted in a question used to
# approve the document and take the question away with it.
echo "▸ ordinary words do not decide"
ordinary() {   # ordinary <quoted-word> → "still waiting" or what came back
  local word="$1"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  printf '# Plan\n\nWe go through the tables one at a time, and it is ok.\n' > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!

  local review=""
  for _ in $(seq 1 40); do
    review="$(ls .imark/reviews/*.md 2>/dev/null | head -1)"
    [[ -n "$review" ]] && break
    sleep 0.25
  done

  {
    echo
    echo "<!-- imark quote=\"$word\" by=\"reviewer\" at=\"2026-08-04T10:00Z\""
    echo "A question about the word $word, not a decision."
    echo '-->'
  } >> "$review"

  # Twice the poll interval, so a verdict would have been reached by now.
  sleep 1.5
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "still waiting"
  else
    wait "$pid" 2>/dev/null
    cat out.txt
  fi
  cd "$OLDPWD"; rm -rf "$dir"
}

for word in go ok ship no changes rework; do
  check "commenting on \"$word\" leaves the review open" "$(ordinary "$word")" "still waiting"
done
check "and \"approve\" still ends it"  "$(ordinary approve)" "APPROVED"
check "as does \"revise\""             "$(ordinary revise)"  "DID NOT APPROVE"

out="$(hook off approve)"
check "does nothing without IMARK_PLAN_REVIEW"    "$out" "{}"
refute "and decides no permission request"                "$out" "behavior"

out="$(hook on request-changes)"
check "request changes denies the permission"   "$out" '"behavior":"deny"'
check "with the revise order in the reason"        "$out" "DID NOT APPROVE"

out="$(hook on approve)"
check "approve lets the agent carry on"         "$out" '"behavior":"allow"'
refute "without asking again in the terminal"   "$out" "deny"

echo
if [[ $fail -eq 0 ]]; then
  echo "all good ($pass)"
else
  echo "$fail failing of $((pass + fail))"
  exit 1
fi
