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

## What this is not

- **Not an editor.** Imark reads. Comments are the one thing it writes, and that
  is deliberate — your editor is better at editing than this will ever be.
- **Not cross-platform.** It is AppKit and a WebView, and the Quick Look
  extension only exists on macOS.
- **Not a vault.** No database, no index, no folder structure it insists on.

Changes that pull in any of those three directions are not going to be merged,
however well they are written.
