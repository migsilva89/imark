---
description: Open a markdown document in Imark for review and wait for the reviewer's notes
argument-hint: "<file.md> [--no-wait]"
allowed-tools: Bash(node:*)
---

Open a document in Imark for the user to review, and wait for their decision.

Run this, passing the arguments through as they came:

```
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" review $ARGUMENTS
```

Markdown only — plans, specs, RFCs, docs. If you are asked to review code, say
that Imark is a markdown reader and that reviewing code is a job for GitHub or
their editor.

The command **blocks** until the user presses Approve or Request Changes in the
app. That is expected and can take a long time: do not interrupt it, do not put
a timeout on it, and do not ask whether they are done.

When it returns, the output carries the decision and the notes, and on a refusal
it also carries the steps to take. **Follow them in the order they come** — in
particular, reply to the user before rewriting anything, and ask rather than
guess when a note is ambiguous or two of them contradict each other.

Refer to notes by the words they are attached to — *on “X”* — rather than by
number, because that is how the user sees them in the app.

If the command says Imark is not installed, tell the user where the document
ended up and carry on without the review.
