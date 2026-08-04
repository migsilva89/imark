---
description: Read the Imark comments out of a markdown file
argument-hint: "<file.md>"
allowed-tools: Bash(node:*)
---

Read the notes the user left inside a markdown file with Imark.

```
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" notes $ARGUMENTS
```

This waits for nothing and opens nothing — it is for when the user has already
commented and says "read my comments".

Each note carries the words it is attached to, the section it fell under, and
the block above it. That is usually enough to know what it is about without
opening the file; open it anyway if a note needs the text around it.

A note marked **orphan** has lost its anchor: the quoted text is no longer in
the document. It still counts as a comment, but do not assume the line above it
is what it refers to.

Treat every note as a request, answer all of them, and refer to each by the
words it is attached to — *on “X”* — which is how the user sees them in the app.
