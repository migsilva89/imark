# Imark for Claude Code

Review what an agent hands you — a plan, a diff, a document — in
[Imark](../README.md) instead of in the terminal. Comment on the phrases you
disagree with, and the notes come back to the agent.

The file is the bridge. No server, no port, no browser, and nothing leaves the
machine.

## Install

```bash
/plugin marketplace add migsilva89/imark
/plugin install imark@imark
```

Needs Imark in `/Applications` and Node 20.

## Use

```
/imark:imark-review              # as alterações por commitar
/imark:imark-review --staged     # só o que está em staging
/imark:imark-review docs/PLAN.md # ficheiros
/imark:imark-notes ficheiro.md   # lê notas que já lá estão
```

`imark-review` writes a document to `.imark/reviews/`, opens it in Imark, and
**blocks**. You read it, comment where you want to, and finish with the two
buttons at the top of the window:

| | |
|---|---|
| **Approve** | the agent carries on, with any notes you left |
| **Request Changes** | the agent gets every note and revises instead |

They appear only on a review — a document carrying `imark: review` in its front
matter. Every other markdown file opens exactly as it always did.

Pressing one writes a `.decision.json` beside the document, never into it: the
document is yours and carries your notes, and the machinery keeps its own
bookkeeping somewhere you can delete without losing anything.

On a build of Imark without those buttons, commenting on the words **seguir** or
**rever** does the same thing. A review only one version of one app can finish
would not be much of a bridge.

`.imark/` writes its own one-line `.gitignore`, so your project's does not have
to change.

## Reviewing the plan automatically

The `ExitPlanMode` hook is off by default. `ExitPlanMode` is crowded territory —
[Plannotator](https://plannotator.ai) hooks the same event, and two blocking
hooks on one event is a hung session. Turn it on deliberately:

```bash
export IMARK_PLAN_REVIEW=1
```

With it set, leaving plan mode opens the plan in Imark and waits. Commenting on
**rever** denies the permission request and hands the agent every note you
wrote, so it revises instead of building.

## What it does not do

- **No drawing.** Text on a phrase, which is what Imark does.
- **No side-by-side diff.** A diff here is a fenced block with `+` and `-` —
  syntax-highlighted, commentable line by line, but not a diff view.
- **No idea when you closed the window.** Open a review and go to lunch and the
  agent waits. That is the price of there being no channel back.

## Where the code is

The plugin is one file — [`scripts/imark.mjs`](scripts/imark.mjs), the parser,
the review documents and the hook, with no dependencies. Its escaping is the
mirror image of `Sources/Imark/Comments.swift`; if one side grows a rule, the
other has to grow it too.

The app's side is `Sources/Imark/Review.swift` and `ReviewButton.swift`. That is
the only part of Imark that knows another tool exists, and it is meant to stay
that way.

```bash
node scripts/imark.mjs notes ../testdata/comments.md
```

Why it is built this way, and what it deliberately leaves out, is in
[`docs/PLAN-AGENT.md`](../docs/PLAN-AGENT.md).
