---
name: imark-comments
description: Read and write the `<!-- imark … -->` comment blocks that Imark stores inside markdown files. Use when a markdown file contains blocks starting with `<!-- imark`, when the user mentions Imark notes or comments, asks you to read their annotations on a document, or asks for feedback they left in a file to be acted on.
---

# Imark comments

Imark is a macOS markdown reader that stores a reader's comments **inside the
document**, as HTML comments. Every renderer ignores them, `grep` finds them,
and they travel with the file. If you are looking at a markdown file with blocks
like this, that is what they are:

```markdown
As linhas movem-se em lotes de 500, e o prazo é generoso mas exequível.

<!-- imark quote="generoso mas exequível" by="miguel" at="2026-08-02T14:31Z"
Exequível com que equipa? Isto precisa de um número, não de um adjectivo.
-->
```

## Reading them

Do not hand-roll a parser:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/imark.mjs" notes <file.md>
```

Add `--json` for structured output. Each note comes back with what it says, the
quote it is attached to, who wrote it and when, the heading it falls under, and
the block above it.

## The format

| Attribute | Meaning |
|---|---|
| `quote=` | the exact words the note is attached to. Required |
| `by=` | who wrote it. Omitted when there is no name |
| `at=` | ISO 8601 timestamp |
| `nth=` | which occurrence of the quote, when the same words appear twice. Only written when it is above 1 |
| `color=` | one of five names. Omitted for the default |

The body is every line between the opening line and a line containing only
`-->`. Inside it, `&amp;` is a literal `&` and `--&gt;` is a literal `-->` —
escaped so the note cannot close its own comment early. In attributes, `&quot;`
is a quote character.

## Acting on them

A note is a request, not a remark. Answer every one, say what you changed for
each, and refer to them by their quote — *“on ‘generoso mas exequível’”* — which
is how the user sees them in the app.

A note reported as **orphan** has lost its anchor: the quoted words were edited
away. It still counts, but the paragraph above it is no longer reliably what it
is about — say so instead of guessing.

## Writing them

Prefer not to. The comments are the user's side of the conversation, and Imark
owns the file surgery — atomic writes, a staleness check, ten levels of undo.
Writing a block by hand from an agent gets none of that. Put your own answers in
your reply, or in a separate document.

If a note must be written into a file anyway, match `format()` in
`Sources/Imark/Comments.swift` exactly: attributes in the order `quote`, `by`,
`at`, `nth`, `color`, a blank line between the note and the block above it, and
the body escaped as described.
