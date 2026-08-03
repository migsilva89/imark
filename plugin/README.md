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
**blocks**. You read it, comment where you want to, and end the wait by
commenting on one of two words the document tells you about:

> Comenta em **seguir** para aprovar, ou em **rever** para devolver as notas ao
> agente.

Everything else you comment on along the way is feedback and decides nothing —
annotate the whole document and choose at the end.

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

## The one file

Everything is [`scripts/imark.mjs`](scripts/imark.mjs) — the parser, the review
documents and the hook. It has no dependencies, and its escaping is the mirror
image of `Sources/Imark/Comments.swift`. If one side grows a rule, the other
has to grow it too.

```bash
node scripts/imark.mjs notes ../testdata/comments.md
```

Why it is built this way, and what it deliberately leaves out, is in
[`docs/PLAN-AGENT.md`](../docs/PLAN-AGENT.md).
