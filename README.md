<p align="center">
  <img src=".github/assets/app-icon.png" width="128" height="128" alt="Imark app icon">
</p>

<h1 align="center">Imark ®</h1>

<p align="center">
  <strong>Native Markdown reader for macOS.</strong><br><br>
  Double-click a <code>.md</code> file and it opens rendered, reloads itself while you<br>
  edit, and previews in the Finder with the space bar. Nothing leaves the machine.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/network-none-brightgreen?style=flat-square" alt="No network access">
  <img src="https://img.shields.io/badge/size-13%20MB-lightgrey?style=flat-square" alt="13 MB">
</p>

> [!NOTE]
> Imark is a reader, not an editor. There is no text field and nothing to save — the *Open in* button hands the file to Cursor, VS Code, Sublime, Zed, or whatever else you have installed.

## Screenshots

| Document window | Quick Look preview |
|:---:|:---:|
| ![Document window with a folded outline](.github/assets/imark-window.png) | ![Quick Look preview with the outline rail](.github/assets/imark-quicklook.png) |

## Features

- **Quick Look previews** — the space bar in the Finder renders the document, not raw text, using the same engine as the app
- **Live reload** — saving in your editor updates the view in under 300ms, keeping your scroll position, and it survives the delete-and-rename that editors call an atomic save
- **Foldable outline** — headings in the sidebar, with sections you can collapse; past twenty entries it opens folded, so a changelog is one row per version
- **Wiki-links** — `[[note]]` resolves against the folder and opens in the same window, with back and forward history
- **Everything GitHub-flavoured** — tables, task lists, footnotes, front matter as a header card, syntax highlighting, Mermaid diagrams, KaTeX maths
- **Find with a counter** — `⌘F` highlights every hit and tells you which one you are on
- **Truly offline** — a content security policy blocks every request, and the KaTeX fonts are embedded in the bundle. Remote images do not load, on purpose
- **Native throughout** — real AppKit windows, menus, appearance switching and printing, around a WebView that only ever renders

## Tech Stack

- Swift 6 with AppKit, no external Swift dependencies
- WKWebView over a private `imark://` scheme, so images beside a document load without opening `file://` to the page
- markdown-it, highlight.js, Mermaid and KaTeX, bundled offline with esbuild
- Swift Package Manager plus a shell script that assembles the `.app` — no `.xcodeproj` to keep in sync

## Building from Source

Requires Xcode 16 or later and Node 20.

```bash
git clone https://github.com/migsilva89/imark.git
cd imark
cd renderer && npm install && cd ..
./build.sh
```

That builds the JavaScript bundle, compiles the Swift, assembles `Imark.app`, signs it ad-hoc and installs it to `/Applications`.

| | |
|---|---|
| `./build.sh` | build and install |
| `./build.sh --debug` | fast compile, for iterating |
| `./build.sh --no-install` | leave it in `dist/` |
| `IMARK_INSTALL_DIR=~/Applications ./build.sh` | install elsewhere |

## Keyboard Shortcuts

| | | | |
|---|---|---|---|
| `⌘O` | Open | `⌘F` | Find |
| `⌘W` | Close window | `⌘G` / `⌘⇧G` | Next / previous hit |
| `⌘\` | Toggle sidebar | `←` / `→` | Fold / unfold outline section |
| `⌘[` / `⌘]` | Back / forward | `⌘R` | Reload |
| `⌘+` / `⌘-` / `⌘0` | Text size | `⌘⇧R` | Reveal in Finder |
| `⌘P` | Print or export PDF | | |

## FAQ

### How do I make Imark the default for `.md`?

Launch it with no document open and click **Make Imark the default for .md**, or use the same item in the **Imark** menu. Once it is the default, both quietly disappear.

### Why does the Quick Look extension need the network entitlement?

It does not use the network. WebKit refuses to start its WebContent process inside a sandboxed app extension without `com.apple.security.network.client`, even when every byte is served from a local scheme. The panel stays blank without it, with no error and no log entry. See `docs/PLAN.md` for the rest of that afternoon.

### Can I sign it with my own Developer ID?

```bash
IMARK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build.sh
```

With an identity it signs with `--options=runtime` and a timestamp, which is what notarisation expects. Without one it stays ad-hoc, which is enough for the machine that built it.

## Repository

```
Sources/Imark/           the app
Sources/ImarkQuickLook/  the Quick Look extension
Sources/ImarkRender/     the renderer both of them share
renderer/                JavaScript source
Resources/               build output — not edited by hand
Support/                 Info.plist, entitlements, and the icon generator
docs/                    design, flows and acceptance criteria
```

The renderer is the only part that knows how to turn Markdown into anything. The Swift side handles windows, files and navigation, and talks to it in messages.

Design and acceptance criteria live in [docs/DESIGN.md](docs/DESIGN.md); the build order and what each milestone had to satisfy is in [docs/PLAN.md](docs/PLAN.md).

## Tools

The icon is drawn in code from the rules in the design document:

```bash
swift Support/make-icon.swift
```

Two helpers exist for looking at the UI without photographing the whole desktop — `Support/shoot.swift` renders a page in an off-screen web view, and `Support/window-id.swift` resolves a window id so a screenshot can be taken of one window:

```bash
screencapture -x -o -l"$(swift Support/window-id.swift Imark)" shot.png
```
