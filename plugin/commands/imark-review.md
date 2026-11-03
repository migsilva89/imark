---
description: Open a markdown document in Imark for review and wait for the reviewer's notes
argument-hint: "<file.md> [--no-wait]"
allowed-tools: Bash(command -v imark), Bash(imark review *), Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" review *)
---

Open a document in Imark for the user to review, and wait for their decision.

First see whether `imark` — the command the user has in their own terminal,
so the two of you drive Imark the same way — is on the PATH:

```
command -v imark
```

If that prints a path, run this, passing the arguments through as they came:

```
imark review $ARGUMENTS
```

Whatever it returns is the answer, an error included: do not run the script
below after `imark` has run. Only if `command -v imark` printed nothing, run the
script it wraps instead, with the same arguments, and tell the user once that
**Imark ▸ Install the imark Command…** puts `imark` on their PATH:

```
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" review $ARGUMENTS
```

Markdown only — plans, specs, RFCs, docs. If you are asked to review code, say
that Imark is a markdown reader and that reviewing code is a job for GitHub or
their editor.

The review happens **on the file itself** — no copy is made. The reviewer's
notes are written into the document as `<!-- imark … -->` blocks and stay
there; they travel with the file. Content piped on stdin, or several files at
once, gets a temporary stand-in document instead, cleaned up afterwards.

The command **blocks** until the user presses Approve or Send Back in the
app. That is expected and can take a long time: do not interrupt it, do not put
a timeout on it, and do not ask whether they are done.

When it returns, the output carries the decision and the notes, and on a refusal
it also carries the steps to take. **Follow them in the order they come** — in
particular, reply to the user before rewriting anything, and ask rather than
guess when a note is ambiguous or two of them contradict each other.

Refer to notes by the words they are attached to — *on “X”* — rather than by
number, because that is how the user sees them in the app.

When you act on a note, do not delete it. Mark it done by adding
`resolved="<ISO date>"` to its opening `<!-- imark` line — the note is the
reviewer's record of what was asked, the mark is yours of having done it. The
app shows resolved notes faded, and the next review round will not repeat them
back to you.

If the command says Imark is not installed, tell the user where the document
ended up and carry on without the review.
