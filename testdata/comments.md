---
title: Comments — test file
status: fixture
---

# Comments

This file exists to verify C3: reading comments written by hand, with the app
having written none of them. Six should anchor and one should be an orphan.

The deadline is tight but achievable if we start in September.

<!-- imark quote="dline is" by="John Doe" at="2026-08-02T11:02:33Z"
A quote landing in the middle of two words, on purpose.
-->

<!-- imark quote="achievable" by="john" at="2026-08-02T14:31Z"
Achievable with which team? This needs a number, not an adjective.
-->

## A table

| Piece | State |
|---|---|
| Line map | done |
| Popover | done |

<!-- imark quote="Line map" by="jane" at="2026-08-01T09:00Z" color="green"
A note inside a table, to prove the anchor does not need a paragraph.
-->

> A blockquote is a top-level block too.

<!-- imark quote="blockquote" by="john" at="2026-07-30T18:20Z" color="amber"
And it takes a note like any other.
-->

## The same word twice

The word appears here, and it appears again on the same line.

<!-- imark quote="appears" by="john" at="2026-08-02T15:00Z" nth="2" color="red"
This one has to land on the second occurrence, not the first.
-->

## A colour that does not exist

A file can carry anything in `color=`, and whatever is not recognised has to
fall back to normal instead of reaching the stylesheet.

<!-- imark quote="anything" by="sam" at="2026-08-02T16:00Z" color="chartreuse; }"
This colour is invented — the note has to end up in the default one.
-->

## The orphan

This paragraph no longer contains what the note referred to.

<!-- imark quote="a sentence that was deleted" by="john" at="2026-07-28T11:05Z" color="blue"
The quote disappeared in an edit. The note is still legible and still attached
to its block, but without the underline and marked as an orphan.
-->
