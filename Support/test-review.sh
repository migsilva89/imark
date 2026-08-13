#!/bin/bash
#
# The round trip: the plugin announces a review and waits, the app writes a
# decision, the plugin wakes up and produces what the agent will read.
#
#   Support/test-review.sh
#
# Everything here is the real code on both sides. The decision is written by
# Review.decide — the function the toolbar buttons call — rather than by a
# click, because posting a synthetic click needs accessibility permission that a
# terminal does not have. That one hop, button to selector, is the only part of
# this feature no test covers.
#
# Every case gets its own IMARK_PENDING_DIR, so the suite cannot touch a real
# review that happens to be open, and two cases cannot touch each other.

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

wait_for() {   # wait_for <glob> → first match, or empty after 10s
  local found=""
  for _ in $(seq 1 40); do
    found="$(ls $1 2>/dev/null | head -1)"
    [[ -n "$found" ]] && break
    sleep 0.25
  done
  echo "$found"
}

run() {   # run <decision> <notes-in-document> [extra-note-block] → what the agent reads
  local decision="$1" note="$2" extra="${3:-}"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
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
    if [[ -n "$extra" ]]; then
      echo "$extra"
    fi
  } > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!

  local request; request="$(wait_for "$IMARK_PENDING_DIR/*.json")"
  if [[ -z "$request" ]]; then
    kill "$pid" 2>/dev/null
    echo "FAIL the request was never announced"
    unset IMARK_PENDING_DIR; cd "$OLDPWD"; return 1
  fi

  # The decision lands on the document itself — there is no copy any more.
  /tmp/imark-decide "$(pwd)/SPEC.md" "$decision" 1 > /dev/null
  wait "$pid"
  cat out.txt

  # Side checks, folded into the output so `check` can see them.
  [[ -d .imark ]] && echo "LEFTOVER: a .imark directory in the project"
  local pending_left
  pending_left="$(ls "$IMARK_PENDING_DIR" 2>/dev/null)"
  [[ -n "$pending_left" ]] && echo "LEFTOVER: pending files: $pending_left"
  grep -q "imark quote=" SPEC.md && echo "NOTES-STILL-IN-DOCUMENT"

  unset IMARK_PENDING_DIR
  cd "$OLDPWD"
  rm -rf "$dir"
}

echo "▸ request changes"
out="$(run request-changes 'This is ambiguous and needs a number.')"
check "tells the agent it was not approved"    "$out" "THE REVIEWER DID NOT APPROVE THIS"
check "tells it not to rewrite yet"             "$out" "Do not rewrite anything yet"
check "tells it to ask when unsure"    "$out" "Do not guess"
check "tells it to mark notes resolved, not delete them" "$out" 'resolved="<date>"'
check "carries the note I wrote"               "$out" "This is ambiguous"
check "and the phrase it refers to"         "$out" "going to be reviewed"
refute "does not call it an orphan"                   "$out" "Orphan"
check "the notes stay in the reviewed file"    "$out" "NOTES-STILL-IN-DOCUMENT"
refute "no copy is archived in the project"    "$out" "LEFTOVER: a .imark directory"
refute "and the handshake is cleaned up"       "$out" "LEFTOVER: pending"

echo "▸ approve"
out="$(run approve 'A note to take into account.')"
check "tells the agent it was approved"        "$out" "APPROVED"
check "and passes the notes anyway"         "$out" "A note to take into account"
check "pointing at the document itself"     "$out" "notes are in the document itself"
refute "without the order to rewrite"            "$out" "DID NOT APPROVE"

echo "▸ a resolved note is a record, not feedback"
resolved_block='<!-- imark quote="A paragraph" by="miguel" at="2026-08-01T09:00Z" resolved="2026-08-02T09:00Z"
Already dealt with last round.
-->'
out="$(run request-changes 'The one still open.' "$resolved_block")"
check "the open note comes back"               "$out" "The one still open"
refute "the resolved one does not"             "$out" "Already dealt with last round"

echo "▸ a dead review's decision cannot end a fresh one"
ghost() {
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
  mkdir -p "$IMARK_PENDING_DIR"
  printf '# Plan\n\nA paragraph that is going to be reviewed.\n' > SPEC.md

  # The leftovers of a review that crashed after being approved: same file,
  # already answered. The old timestamp-named archive made exactly this pair
  # reachable from a new review, which returned an approval nobody gave.
  cat > "$IMARK_PENDING_DIR/deadbeef0000.json" <<EOF
{ "file": "$(pwd)/SPEC.md", "at": "2026-08-06T00:00:00Z" }
EOF
  cat > "$IMARK_PENDING_DIR/deadbeef0000.decision.json" <<EOF
{ "decision": "approve", "notes": 0, "at": "2026-08-06T00:00:01Z" }
EOF

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!
  sleep 1.5
  if kill -0 "$pid" 2>/dev/null; then
    echo "still waiting"
    # And the buttons still decide it: the app must route around the corpse.
    /tmp/imark-decide "$(pwd)/SPEC.md" request-changes 0 > /dev/null
    wait "$pid"
    cat out.txt
  else
    wait "$pid" 2>/dev/null
    cat out.txt
  fi
  unset IMARK_PENDING_DIR
  cd "$OLDPWD"; rm -rf "$dir"
}
out="$(ghost)"
check "the fresh review keeps waiting"         "$out" "still waiting"
check "and the real decision still lands"      "$out" "DID NOT APPROVE"
refute "the ghost approval never surfaces"     "$out" "APPROVED — the reviewer accepted this"

# Shipped in 0.2.2 and found by pressing the button: a round nobody finished
# leaves an unanswered request behind, and the app answered whichever sorted
# first. The reviewer pressed Send Back, the corpse got the answer, and the
# agent actually waiting was never told anything.
echo "▸ an abandoned round cannot swallow the answer"
abandoned() {
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
  mkdir -p "$IMARK_PENDING_DIR"
  printf '# Plan\n\nA paragraph that is going to be reviewed.\n' > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!
  local request; request="$(wait_for "$IMARK_PENDING_DIR/*.json")"
  if [[ -z "$request" ]]; then
    kill "$pid" 2>/dev/null; echo "the request was never announced"
    unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"; return
  fi

  # The corpse of an earlier round, dropped in after the live one is already
  # waiting — a script that was killed outright, so it never withdrew and the
  # live review never saw it to clear it. Older stamp, and a name that sorts
  # before anything the script rolls: the version that took whichever came
  # first alphabetically handed this one the answer.
  cat > "$IMARK_PENDING_DIR/0000deadbeef.json" <<EOF
{ "file": "$(pwd)/SPEC.md", "at": "2026-08-13T21:31:17.392Z", "by": "Claude Code" }
EOF

  {
    echo
    echo '<!-- imark quote="going to be reviewed" by="miguel" at="2026-08-13T21:38Z"'
    echo 'This needs a number.'
    echo '-->'
  } >> SPEC.md
  /tmp/imark-decide "$(pwd)/SPEC.md" request-changes 1 > /dev/null

  # Four polls: if it were going to wake up it would have by now.
  for _ in $(seq 1 8); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "STILL-WAITING: the answer went somewhere else"
  else
    wait "$pid" 2>/dev/null; cat out.txt
  fi
  unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"
}
out="$(abandoned)"
refute "the live review is not left hanging"    "$out" "STILL-WAITING"
check "it gets the decision"                    "$out" "DID NOT APPROVE"
check "with the note that was written"          "$out" "This needs a number"

# The other half of the same bug: the round that leaves the corpse behind.
echo "▸ an interrupted review takes its request with it"
interrupted() {
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
  printf '# Plan\n\nA paragraph that is going to be reviewed.\n' > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!
  local request; request="$(wait_for "$IMARK_PENDING_DIR/*.json")"
  # Closing the session, or Ctrl-C in the terminal.
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 0.25
  local left; left="$(ls "$IMARK_PENDING_DIR" 2>/dev/null)"
  [[ -n "$left" ]] && echo "LEFTOVER: $left"
  unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"
}
refute "nothing is left for the app to answer"  "$(interrupted)" "LEFTOVER"

# And the belt to that pair of braces: whatever a killed round did leave, the
# next review of the same document takes down before it opens the window.
echo "▸ a new round clears the last one's leftovers"
sweeps() {
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
  mkdir -p "$IMARK_PENDING_DIR"
  printf '# Plan\n\nA paragraph that is going to be reviewed.\n' > SPEC.md
  cat > "$IMARK_PENDING_DIR/0000deadbeef.json" <<EOF
{ "file": "$(pwd)/SPEC.md", "at": "2026-08-13T21:31:17.392Z", "by": "Claude Code" }
EOF
  # A request for somebody else's document, which is none of our business.
  cat > "$IMARK_PENDING_DIR/0000cafe0000.json" <<EOF
{ "file": "$(pwd)/OTHER.md", "at": "2026-08-13T21:31:17.392Z", "by": "Claude Code" }
EOF

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!
  sleep 1
  ls "$IMARK_PENDING_DIR" | sed 's/^/PENDING: /'
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"
}
out="$(sweeps)"
refute "the corpse for this document is gone"   "$out" "PENDING: 0000deadbeef.json"
check "another document's review is untouched"  "$out" "PENDING: 0000cafe0000.json"

echo "▸ the plan-mode hook"

hook() {   # hook <on|off> <decision> → prints the JSON Claude Code reads
  local gate="$1" decision="$2"
  local dir; dir="$(mktemp -d)"
  cd "$dir"
  export IMARK_PENDING_DIR="$dir/pending"
  # The shape Claude Code puts on stdin when ExitPlanMode asks for permission.
  node -e 'require("fs").writeFileSync("ev.json", JSON.stringify({
    tool_input: { plan: "# Plan\n\nA step that is going to be reviewed.\n" },
    cwd: process.cwd(),
  }))'

  if [[ "$gate" == off ]]; then
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json
    unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"; return
  fi

  IMARK_TEST_NO_OPEN=1 IMARK_PLAN_REVIEW=1 \
    node "$OLDPWD/plugin/scripts/imark.mjs" plan-hook < ev.json > out.json 2>/dev/null &
  local pid=$!
  # A plan has no file of its own, so this one review still opens a stand-in.
  local review; review="$(wait_for "$IMARK_PENDING_DIR/*.md")"
  [[ -n "$review" ]] && /tmp/imark-decide "$review" "$decision" 0 > /dev/null
  wait "$pid"
  cat out.json
  unset IMARK_PENDING_DIR
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
  export IMARK_PENDING_DIR="$dir/pending"
  printf '# Plan\n\nWe go through the tables one at a time, and it is ok.\n' > SPEC.md

  IMARK_TEST_NO_OPEN=1 node "$OLDPWD/plugin/scripts/imark.mjs" review SPEC.md > out.txt 2>&1 &
  local pid=$!

  local request; request="$(wait_for "$IMARK_PENDING_DIR/*.json")"
  if [[ -z "$request" ]]; then
    kill "$pid" 2>/dev/null
    echo "the request was never announced"
    unset IMARK_PENDING_DIR; cd "$OLDPWD"; rm -rf "$dir"; return
  fi

  # The reviewer's note goes into the document itself now.
  {
    echo
    echo "<!-- imark quote=\"$word\" by=\"reviewer\" at=\"2026-08-04T10:00Z\""
    echo "A question about the word $word, not a decision."
    echo '-->'
  } >> SPEC.md

  # Twice the poll interval, so a verdict would have been reached by now.
  sleep 1.5
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "still waiting"
  else
    wait "$pid" 2>/dev/null
    cat out.txt
  fi
  unset IMARK_PENDING_DIR
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
