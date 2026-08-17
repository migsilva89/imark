---
title: Everything at once
subtitle: The document that exercises the lot
owner: John Doe
status: living fixture
version: 0.1.0
tags: [markdown, macos, fixture, comments]
updated: 2026-08-02
---

# Everything at once

This file exists to be opened, not to be read. It carries every construction the
renderer knows, every kind of comment, and enough headings that the outline
folds itself and both rails have something to say. If something breaks, it
breaks here first.

<!-- imark quote="opened, not to be read" by="John Doe" at="2026-08-02T09:00:00Z"
The whole point of a fixture: it is a place for things to go wrong on purpose,
before they go wrong on somebody's actual document.
-->

## Text

Prose is set in a column capped at 72 characters, because a line you have to
track back across is a line you read twice. **Bold** and *italic* and
***both at once***, `inline code`, ~~struck through~~, and ==marked== text all
sit on the same baseline without pushing the line apart.

<!-- imark quote="Bold and italic" by="jane" at="2026-08-01T12:00:00Z" color="blue"
A quote that runs straight across markup — bold, then plain text, then italic.
It has to be found and underlined in three pieces. Searching node by node found
none of these and orphaned them without a word.
-->

A second paragraph, so there is something for a comment to be anchored to that
is not the first thing on the page. The word *anchor* appears here, and the word
anchor appears again in this same sentence — which is what `nth=` is for.

<!-- imark quote="anchor" by="jane" at="2026-08-01T11:20:00Z" nth="2" color="green"
This one is deliberately on the second "anchor", not the first. If it moves to
the first one, the occurrence counting has broken.
-->

<!-- imark quote="not the first thing on the page" by="John Doe" at="2026-08-02T09:05:00Z" color="amber"
Two notes on one paragraph, to check they stack in the margin instead of landing
on top of each other.
-->

### Links

An [external link](https://example.com) opens in your browser. A
[local one](./showcase.md) opens in the same window, with back and forward
history. A wiki-link to [[comments]] resolves against this folder; a wiki-link
to [[a note that is not here]] is marked as dead rather than silently doing
nothing.

<!-- imark quote="a line you have to track back across" by="John Doe" at="2026-08-02T09:02:00Z"
A note deliberately written far from its paragraph, to prove the rule: the quote
is looked for in the block immediately above the note, not across the document.
This one is on the wrong block on purpose and should be an orphan.
-->

### Quotes

> A blockquote is a top-level block, so it can carry a note of its own.
>
> > And it can contain another one, which should indent without the border
> > doubling up into a smear.

<!-- imark quote="top-level block" by="john" at="2026-07-30T18:20:00Z" color="blue"
Anchoring inside a blockquote is the case that proves the rule is about blocks
and not about paragraphs.
-->

## Code

Syntax colours come from the same palette as the rest of the app, rather than an
imported highlight.js theme that would glow in a page it knows nothing about.

```swift
/// The one thing in Imark that writes to your files, so it goes through a
/// temporary file and a rename rather than writing over the original.
private static func write(_ text: String, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).imark-\(UUID().uuidString)")
    try text.write(to: temporary, atomically: false, encoding: .utf8)
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}
```

```javascript
// A licence file is somebody else's markdown and may contain fences of its own.
const fenced = (text) => {
  const longest = Math.max(2, ...[...text.matchAll(/`+/g)].map((m) => m[0].length))
  const fence = '`'.repeat(longest + 1)
  return `${fence}\n${text}\n${fence}`
}
```

```bash
IMARK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" IMARK_NOTARY_PROFILE=imark ./release.sh
```

```
A fence with no language at all. It should still get the frame, the copy button
and the monospaced face, just no colours.
```

<!-- imark quote="no language at all" by="sam" at="2026-08-02T10:00:00Z" color="red"
A note on a code block. The quote has to be found inside the highlighted markup
without disturbing any of the spans highlight.js put there.
-->

## Diagrams

Mermaid renders locally and takes its colours from the same variables as
everything else, so diagrams do not glow white in the middle of a dark page.

```mermaid
flowchart LR
    A[Select a phrase] --> B{Popover}
    B -->|Comment| C[Composer]
    B -->|Translate| D[On device]
    B -->|Search| E[Your browser]
    C --> F[Atomic write]
    F --> G[(The .md file)]
```

```mermaid
sequenceDiagram
    participant U as You
    participant A as Imark
    participant D as Disk
    U->>A: Select, comment, press return
    A->>D: Write to a temporary file
    A->>D: Rename over the original
    D-->>A: Watcher fires
    A->>A: Ignore it, we caused it
    A-->>U: The note appears
```

## Tables

| Piece | Where it lives | Notes |
|---|---|---|
| Line map | `renderer/src/main.js` | `data-line` on every block |
| Anchoring | `renderer/src/comments.js` | Quote inside the block above |
| Writing | `Sources/Imark/Comments.swift` | Atomic, with a conflict check |
| Colour | `Sources/Imark/NoteColour.swift` | Five names, closed set |
| Undo | `DocumentWindowController` | Snapshots, ten deep |

<!-- imark quote="Atomic, with a conflict check" by="jane" at="2026-08-01T09:00:00Z"
A note anchored inside a table cell, which is the case that made the wrapper
necessary — a table will not take a stray child of its own.
-->

A wider one, to check that it scrolls inside its own box rather than pushing the
whole page sideways:

| Command | Shortcut | What it does | When it is greyed out | Since |
|---|---|---|---|---|
| Show All Comments | `⌘⇧C` | Opens every note under its block | No notes in the document | 0.1 |
| Next Comment | `⌘'` | Steps forward, wrapping at the end | No notes in the document | 0.1 |
| Previous Comment | `⌘⇧'` | Steps backward | No notes in the document | 0.1 |
| Export Comments | — | Writes a copy with visible blockquotes | No notes in the document | 0.1 |
| Undo | `⌘Z` | Puts back the last change to a note | Nothing to undo | 0.1 |

## Lists

Unordered, with a nested level:

- The first item
- The second, which is longer so it wraps and you can see how the hanging indent
  behaves when a line runs past the end
  - A nested item
  - Another one
    - And a third level, because someone always does
- The last

Ordered:

1. Ask the certificate holder
2. Make the repository public
3. Cut a release with the `.dmg` attached
4. Record the fifteen seconds that are the whole post
5. Publish in three places on the same day

Tasks, which are clickable:

- [x] Line map with `data-line`
- [x] Selection popover
- [x] Read comments written by hand
- [x] Write, edit and delete them
- [x] Colour
- [ ] A Developer ID certificate
- [ ] Somebody else's Mac

## Mathematics

Inline maths like $e^{i\pi} + 1 = 0$ sits in the line without disturbing it.

Display maths gets its own block:

$$
\text{falloff}(d) = \exp\left(-\frac{d^2}{2\sigma^2}\right)
$$

That one is real: it is the curve the outline rail uses to taper around wherever
you are pointing, with $\sigma = 1.15$.

An equation may also be broken over as many lines as it takes to stay readable,
and the subscripts in it are subscripts rather than italics:

$$ \mathbf{K}_e^L = \mathbf{K}_m^L
+ \mathbf{K}_b^L $$

And a dollar sign on its own is money: the licence costs $0 and always will.

## Definition lists

Orphan
: A note whose quoted words are no longer in the document. Still visible, still
  attached to its block, marked as having lost its anchor.

Occurrence
: Which copy of a repeated phrase a note is about, written as `nth=`.

Atomic save
: Write to a temporary file in the same directory, then rename it over the
  original. Never write over the original in place.

## Footnotes

Comments are stored in HTML comments[^why], which every markdown renderer hides
and every text editor shows.

[^why]: A sidecar file would not travel with the document, and a syntax of our
own would dirty files that other tools read.

## Images

Images beside the document load through a private URL scheme, so a page never
gets handed `file://` access to your disk:

<p align="center">
  <img src="../.github/assets/app-icon.png" width="96" alt="The Imark icon">
</p>

Remote images deliberately do not load.

## A comment that lost its anchor

This paragraph no longer contains what the note below was written about.

<!-- imark quote="a sentence that was edited away" by="john" at="2026-07-28T11:05:00Z"
Orphaned on purpose. It should still be readable and still be attached here, with
a hollow mark instead of a filled one, and no underline anywhere.
-->

## A colour that does not exist

A file can carry anything at all in `color=`. Anything unrecognised has to come
back as the default rather than reach the stylesheet.

<!-- imark quote="anything at all" by="sam" at="2026-08-02T16:00:00Z" color="chartreuse; } body { display: none"
This note tries to close the attribute and inject CSS. It should be the ordinary
violet, and the page should look exactly as it did.
-->

## Horizontal rules

---

Three dashes make a rule, and it should be a hairline rather than a bar.

## Long enough to scroll

### One

Enough sections follow that the outline in the sidebar opens folded, the heading
rail has more ticks than it can show at full pitch and starts sampling, and the
notes rail has somewhere to place its marks proportionally.

### Two

Each of these is deliberately short. What matters is how many there are.

### Three

The rail samples evenly rather than truncating, or dragging along it would lie
about where you are in the document.

### Four

Past twenty entries the sidebar opens folded, so a changelog reads as one row
per version instead of four hundred rows of prose.

### Five

### Six

### Seven

### Eight

### Nine

### Ten

## The end

If everything above rendered, the renderer is fine.

<!-- imark quote="the renderer is fine" by="John Doe" at="2026-08-02T18:00:00Z" color="green"
And if it is not, this is the file to open first.
-->
