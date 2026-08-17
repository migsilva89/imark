<p align="center">
  <img src=".github/assets/app-icon.png" width="128" height="128" alt="Imark app icon">
</p>

<h1 align="center">Imark ®</h1>

<p align="center">
  <strong>Native Markdown reader for macOS.</strong><br><br>
  Double-click a <code>.md</code> file and it opens rendered, reloads itself while you<br>
  edit, and previews in the Finder with the space bar. Comment on a phrase and the<br>
  note goes into the file itself. Nothing leaves the machine.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/network-update%20check%20only-brightgreen?style=flat-square" alt="Network: update check only, can be turned off">
  <img src="https://img.shields.io/badge/size-13%20MB-lightgrey?style=flat-square" alt="13 MB">
  <img src="https://img.shields.io/badge/licence-MIT-blue?style=flat-square" alt="MIT licence">
</p>

<p align="center">
  <img src=".github/assets/comment.gif" width="720" alt="Selecting a block, writing a note in the popover, and the note appearing in the margin">
</p>

<p align="center"><em>Comment on anything. The note goes into the <code>.md</code> file.</em></p>

> [!NOTE]
> Imark reads; it does not edit. Comments are the one thing it writes, and they go into the document itself — see [Comments](#comments). For everything else the *Open in* button hands the file to Cursor, VS Code, Sublime, Zed, or whatever else you have installed.

## What it does

- **Comments in the file** — select, comment, edit or delete, and the note lives in the document as an HTML comment, so it survives being emailed, committed, or opened in anything else. `⌘Z` undoes any of it
- **Quick Look previews** — the space bar in the Finder renders the document, not raw text, using the same engine as the app
- **Live reload** — saving in your editor updates the view in under 300ms, keeping your scroll position, and it survives the delete-and-rename that editors call an atomic save
- **Foldable outline** — headings in the sidebar, with sections you can collapse; past twenty entries it opens folded, so a changelog is one row per version
- **Outline rail** — a tick per heading down the edge of every document, tapering around the pointer, with a card that names the section before you commit to going there
- **Wiki-links** — `[[note]]` resolves against the folder and opens in the same window, with back and forward history
- **The folder and the recents** — every `.md` beside the open document, plus the last five you opened from anywhere else
- **Everything GitHub-flavoured** — tables, task lists, footnotes, front matter as a header card you can put away from the View menu, syntax highlighting, Mermaid diagrams, KaTeX maths
- **Actions on a selection** — comment on it, translate it on device, or search the web for it in your default browser
- **Find with a counter** — `⌘F` highlights every hit and tells you which one you are on
- **Tabs** — several documents in one window, with everything macOS gives a tabbed app: `⌘⇧[` and `⌘⇧]`, drag a tab out, Merge All Windows
- **Offline where it counts** — documents render with every request blocked by a content security policy, KaTeX fonts embedded, remote images refused on purpose

## Screenshots

| Document window | Quick Look preview |
|:---:|:---:|
| ![A document window with the outline sidebar and syntax-highlighted code](.github/assets/imark-window.png) | ![The Finder preview panel, with the outline rail down the left edge](.github/assets/imark-quicklook.png) |

Both are rendering [`testdata/showcase.md`](testdata/showcase.md). For the full
sweep — every construction, every kind of comment, and enough headings that the
outline folds itself — open [`testdata/everything.md`](testdata/everything.md).

<p align="center">
  <img src=".github/assets/quicklook.gif" width="720" alt="Pressing the space bar in Finder and stepping through markdown files in the preview panel">
</p>

<p align="center"><em>Space bar in the Finder. No app to open first.</em></p>

<p align="center">
  <img src=".github/assets/imark-rail.png" width="520" alt="The rail tapering around the pointer, with a card naming the section and quoting its first line">
</p>

<p align="center"><em>The rail: one tick per heading, in the window and in the Finder's preview panel alike. Click to jump, or press and drag to scrub.</em></p>

## Install

```bash
brew install --cask migsilva89/imark/imark
```

Or download the [latest release](../../releases/latest) and drag `Imark.app` into `/Applications`. The disk image is signed and notarised, so it opens without a Gatekeeper warning.

macOS 14 or later. Imark tells you when a newer version exists — once per release, and only if you leave the check on in Settings.

To make it the default for `.md`: launch it with no document open and click **Make Imark the default for .md**, or use the same item in the **Imark** menu. Once it is the default, both quietly disappear.

## Comments

<p align="center">
  <img src=".github/assets/imark-comments.png" width="620" alt="A phrase underlined in the text, a dot in the margin, and a card floating over the right margin with the note">
</p>

Select a phrase, press the speech bubble, write, press `↵`. The quoted words get
underlined, a dot appears in the margin, and clicking either opens the note. Pick
one of five colours while writing it, or change it later. The card carries **Edit**
and **Delete**, and `⌘Z` undoes any of it — writing, editing or deleting.

The note is stored **inside the `.md` file**, as an HTML comment:

```markdown
Rows move in batches of 500, and the deadline is generous but achievable.

<!-- imark quote="generous but achievable" by="john" at="2026-08-02T14:31Z"
Achievable with which team? This needs a number, not an adjective.
-->
```

Which means it travels with the document instead of living in a database only
this app can read:

| Where | What you see |
|---|---|
| **Imark** | the words underlined, a dot in the margin, the note on click |
| **Cursor, VS Code, Vim** | the block above, verbatim, right under the paragraph |
| **GitHub, any renderer** | nothing — HTML comments are invisible |
| **`grep`, `cat`** | the note, with the quote it refers to beside it |

The `quote=` is what makes the note legible in raw text: someone opening the file
in Vim can see what it refers to without counting lines. If the quoted words are
later edited away the note goes **orphan** — still visible, still attached to its
block, marked as having lost its anchor. There is no fuzzy matching, because a
note in the wrong place is worse than a note without an exact one.

Four ways to get at them, because they answer different questions. The count in
the status bar opens **the list** — every note at once, out of the document.
`⌘⇧C` opens them all **in place**, each under its own block. `⌘'` and `⌘⇧'`
**step** through one at a time. And a rail down the left edge marks **where**
they are, so three clustered in one section is visible at a glance.

**File › Export Comments as Text…** writes a copy — not the document — with every
note turned into a blockquote, for the review the other person has to read on
GitHub:

```markdown
Rows move in batches of 500, and the deadline is generous but achievable.

> **john, 2 Aug 2026** on *“generous but achievable”*
>
> Achievable with which team? This needs a number, not an adjective.
```

## Reviewing an agent's work

A plan from a coding agent is markdown. So is a diff, once it is wrapped in a
fenced block. Because comments live in the file, an agent can hand you a
document, you can annotate it in Imark, and the agent can read your notes back
out — with no server, no port and nothing installed on the other side. The file
is the whole bridge.

<p align="center">
  <img src=".github/assets/review.gif" width="720" alt="Pressing Send Back in the toolbar, and the agent picking the notes up in the terminal">
</p>

<p align="center"><em>Send Back, and the agent reads your notes back.</em></p>

A document under review gets two buttons in the toolbar, **Approve** and **Send
Back**, and pressing either one ends the wait on the other side. Closing the
window without pressing one asks first, because something is waiting for an
answer and closing is not an answer.

The buttons appear on a document an agent asked to have reviewed, and nowhere
else: the agent leaves a small file in `~/.imark/pending` naming the document
before opening it, and Imark writes the decision beside that file. Every other
`.md` opens exactly as it always did.

[`plugin/`](plugin/README.md) is a Claude Code plugin that does this:

```
/imark:imark-review PLAN.md       # review a markdown document
/imark:imark-notes PLAN.md        # notes you already left
```

Launched with no document, Imark offers to **set itself up for the coding agents
on your machine** — one skill, written into each one's `skills` folder. The alert
names every file before writing it, and undoing it is deleting those. Claude Code
and Codex read the same `SKILL.md`; only Claude Code also takes the two loose
commands.

Those files are copies, so a new version of Imark brings them forward on its
first launch and says which ones it rewrote. A copy you edited yourself is never
overwritten — Imark only replaces a file that still matches something it shipped,
and tells you the rest were left alone.

## What it touches

| Where | What, and when |
|---|---|
| The `.md` you are reading | only when you comment. Written to a temporary file beside it and moved into place; it refuses to save at all if the document changed on disk since Imark read it |
| `~/.imark/pending` | while an agent is waiting on a review: which document, and what you decided. Deleted when the agent reads it |
| `~/Library/Preferences/pt.miguelsilva.imark.plist` | your settings — theme, text size, width, the update check |
| `~/.claude/skills`, `~/.codex/skills`, … | only if you accept the offer to set up your coding agents, and only the files the alert names. A new version rewrites those same files once, on its first launch, unless you edited them |
| The network | one request a day to `api.github.com` asking whether a newer version exists. A version number travels, nothing of yours does, and Settings turns it off |

> [!IMPORTANT]
> Comments are the only feature that writes to your documents. Imark keeps the
> last ten states of a document, so `⌘Z` puts any of them back. If it ever
> damages a file, [open an issue](../../issues/new?template=bug_report.yml)
> before anything else — that is the one bug worth interrupting whatever else is
> happening.

## Keyboard shortcuts

| | | | |
|---|---|---|---|
| `⌘O` | Open | `⌘F` | Find, prefilled with the selection |
| `⌘W` | Close window | `⌘G` / `⌘⇧G` | Next / previous hit |
| `⌘\` | Toggle sidebar | `←` / `→` | Fold / unfold outline section |
| `⌘[` / `⌘]` | Back / forward | `⌘R` | Reload |
| `⌘+` / `⌘-` / `⌘0` | Text size | `⌘⇧R` | Reveal in Finder |
| `⌘P` | Print or export PDF | `⌘⇧C` | Show all comments |
| `⌘'` / `⌘⇧'` | Next / previous comment | `⌘Z` | Undo the last comment change |
| `⌘/` | This table, in the app | | |

`⌘/` opens the same list inside the app, built by reading the menu bar rather
than from a copy of this table — which is also how it stays right on keyboards
where macOS remaps the keys. On a Portuguese layout, Back and Forward are `⌘Ç`
and `⌘~`, not `⌘[` and `⌘]`.

## Building from source

Requires Xcode 16 or later and Node 20.

```bash
git clone https://github.com/migsilva89/imark.git
cd imark
cd renderer && npm ci && cd ..
./build.sh
```

That builds the JavaScript bundle, compiles the Swift, assembles `Imark.app` and
installs it to `/Applications`. `npm ci` is not optional: the rendered output is
generated, not committed, and `build.sh` refuses to assemble an app with a blank
window.

| | |
|---|---|
| `./build.sh` | build and install |
| `./build.sh --debug` | fast compile, for iterating |
| `./build.sh --no-install` | leave it in `dist/` |
| `IMARK_INSTALL_DIR=~/Applications ./build.sh` | install elsewhere |

Swift 6 with AppKit and no external Swift dependencies, around a WKWebView that
only ever renders; markdown-it, highlight.js, Mermaid and KaTeX are bundled
offline with esbuild. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the layout of the
repository, the test suites and how to run them.

## FAQ

### Why does the Quick Look extension need the network entitlement?

It does not use the network. WebKit refuses to start its WebContent process
inside a sandboxed app extension without `com.apple.security.network.client`,
even when every byte is served from a local scheme. The panel stays blank without
it, with no error and no log entry.

### What does `⌘Z` undo?

The last change to the document — a note written, edited or deleted — up to ten
deep. Each one is a snapshot of the whole file taken before the change. It only
covers changes Imark made; edits from your own editor are your editor's to undo.

### What happens if two people comment on the same words?

The second note gets an `nth="2"` so it anchors to the right occurrence. Notes on
the same paragraph stack down the margin rather than landing on top of each
other.

## Security, contributing, licence

Imark is a personal project, maintained by one person. Issues get answered and
pull requests are welcome —
[`CONTRIBUTING.md`](CONTRIBUTING.md) says what is out of scope before you spend a
weekend on it — but there is no support promise and no release schedule. For
anything that looks like a security problem, [`SECURITY.md`](SECURITY.md) says
where to send it instead of the issue tracker.

Everything Imark bundles is permissive — MIT, ISC, BSD, Unlicense — with no
copyleft anywhere in the tree. Several require their copyright notice to travel
with the binary, so [`THIRD-PARTY.md`](THIRD-PARTY.md) is generated from what
esbuild actually put in the bundle, on every build, and the same list ships
inside the app: **Imark › About Imark** shows it.

Imark itself is [MIT](LICENSE) — use it, change it, redistribute it, just keep
the copyright notice.
