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
/imark:imark-review PLAN.md       # review a markdown document
/imark:imark-notes PLAN.md        # the notes still waiting on something
```

`imark-notes` hands over the open notes only. One you have already dealt with is
marked `resolved=` and stays in the document as the record of what was asked, but
it is history rather than work — the header says how many were held back, and
`--all` produces them.

Markdown only — plans, specs, RFCs, docs. Imark is a markdown reader, and
reviewing code is a real job this is not the tool for; that is what GitHub or
your editor is for.

`imark-review` opens **the file itself** in Imark and **blocks**. You read it,
comment where you want to, and finish with the two buttons at the top of the
window:

| | |
|---|---|
| **Approve** | the agent carries on, with any notes you left |
| **Send Back** | the agent gets every note and revises instead |

Your notes are written into the document, exactly as if you had commented on it
outside a review — they stay there, and they travel with the file. When the
agent acts on one it marks it `resolved=` rather than deleting it, and the app
shows it faded: the record of what was asked, kept where it was asked.

The buttons appear because the agent announced the review first — a small
request file under `~/.imark/pending/`, answered by the decision and deleted
the moment it is read. Nothing else opens with buttons, and no copy of your
document is made anywhere. Only content with no file of its own — a plan piped
from planning mode, several files at once — opens as a temporary stand-in,
cleaned up afterwards.

On a build of Imark without those buttons, commenting on the word **approve**
or the word **revise** does the same thing. A review only one version of one
app can finish would not be much of a bridge.

## Reviewing the plan automatically

The `ExitPlanMode` hook is off by default. `ExitPlanMode` is crowded territory —
other review tools hook the same event, and two blocking hooks on one event is a
hung session. Turn it on deliberately:

```bash
export IMARK_PLAN_REVIEW=1
```

With it set, leaving plan mode opens the plan in Imark and waits. Commenting on
**rever** denies the permission request and hands the agent every note you
wrote, so it revises instead of building.

## What it does not do

- **No drawing.** Text on a phrase, which is what Imark does.
- **No code review.** Markdown documents only. A ```diff block *inside* a plan
  renders properly — agents write those all the time — but there is no command
  that turns a repository's changes into a review.
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

Its escaping is the mirror image of `Sources/Imark/Comments.swift`; if one side
grows a rule, the other has to grow it too.
