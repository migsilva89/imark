# Contributing

Imark is one person's app. Issues get answered; pull requests are welcome but
please open an issue first, so nobody spends a weekend on something I was never
going to merge.

## Bugs

Anything that damages a document comes first. Everything else, use the [bug
report form](https://github.com/migsilva89/imark/issues/new?template=bug_report.yml)
— the version and the macOS version save a round trip.

## Before a pull request

Run the suites. `./release.sh` refuses to build if any of them fail, so a change
that breaks one cannot ship anyway.

```bash
Support/test-review.sh
node Support/test-notes.mjs
node Support/test-export.mjs
swift Support/test-plus.swift
```

The renderer lives in `renderer/` and is bundled with esbuild; `plugin/` is the
single source for the agent files, copied into the app at build time. Editing
the copy inside `Imark.app` changes nothing in the repo.

## The review handshake: test the second round

Everything about a review passes through `~/.imark/pending`, and that directory
is the only state in Imark that outlives the thing that made it. A review that
is never answered — the session closed, the process killed — leaves its request
there, and 0.2.2 shipped an app that answered the leftover instead of the
review the reviewer was looking at. The agent waited four hours for a decision
that had already been made. Every suite passed: all of them reviewed a clean
document once.

So a change to `Review.swift` or to the handshake in `plugin/scripts/imark.mjs`
is not tested until it is tested **twice over the same document, with a
leftover in the directory**. Three cases in `Support/test-review.sh` hold that
line — the abandoned round, the interrupted one, the sweep — and a fourth
belongs there before the next one gets fixed.

The one step no suite reaches is the press itself: a synthetic click needs
accessibility permission a terminal does not have. Approve, Send Back, and
closing the window without deciding have to be tried by hand, in a build, on a
real review, before a release goes out.

## What this is not

- **Not an editor.** Imark reads. Comments are the one thing it writes, and that
  is deliberate — your editor is better at editing than this will ever be.
- **Not cross-platform.** It is AppKit and a WebView, and the Quick Look
  extension only exists on macOS.
- **Not a vault.** No database, no index, no folder structure it insists on.

Changes that pull in any of those three directions are not going to be merged,
however well they are written.
