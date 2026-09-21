# UniReader

A PDF reader for macOS that keeps every note **outside** the PDF file — and lets you
write on the page with a tablet stylus over your local network.

[![Release](https://img.shields.io/github/v/release/Unireader/uni-reader)](https://github.com/Unireader/uni-reader/releases/latest)
![Platform](https://img.shields.io/badge/macOS-26%2B-blue)
[![License](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)

English · [中文](README.zh.md)

---

## What it is

UniReader is built around one rule: **the PDF file is never modified**. Highlights,
text notes, handwriting, bookmarks and images all live in a workspace of your own,
anchored to the document by its content hash (SHA-256) plus page and page coordinates.
Move or rename the file and your notes follow it.

On top of that it adds the two things a reader for studying actually needs: real
handwriting from a tablet stylus, and Markdown notes that sit next to the books
instead of in a separate app.

![UniReader reading a paper, with the agent panel open](docs/images/Agentic%20Noting.png)

*Highlights, note bubbles and handwriting on the page; the agent panel sits in the
inspector on the right.*

## Features

### Reading

- Custom page renderer (not `PDFView`): steady scrolling and zooming, no flicker
  and no jumping when you pinch, resize the window, or open a panel
- Multiple windows and tabs; PDFs and Markdown notes can share one row of tabs,
  and the whole row comes back in order after a restart
- Library sidebar with groups and manual ordering; documents are identified by
  content hash, so the same file in several places is still one document
- Table of contents, text search (⌘F), jump history (⌘[), go to page (⌃G)
- OCR for scanned pages, with repeated watermark blocks filtered out of selection
  and search
- **Scan alignment**: per-page rotation and shift for crooked scans (View › Align
  Scanned Pages) — once it is on, the aligned page *is* the page, including for ink
- Reference window: a second, read-only floating window for another document
- Night rendering for dark-room reading

![A reference window over the reading area](docs/images/Reference%20Window.png)

*A reference window keeps another page in view — here page 6 of the same paper —
while you read and write on the page underneath.*

### Notes that never touch the PDF

| Kind | What it is |
|---|---|
| Text note | A pin anchored to a point or a selection; body is Markdown, shown in a bubble on the page (click / hover / always open) |
| Highlight | Colored marker over selected text |
| Bookmark | Named position in the document |
| Image note | ⌥⇧-drag a region of the page into a note; images are content-addressed and reference-counted |
| Handwriting | Vector ink with pressure, four pen types, layers, lasso selection, eraser, undo and a clipboard |

There is also a **scratch pad** (an infinite whiteboard over the document) and a
**canvas mode** that widens the page margins so there is room to write.

### Markdown notes in the workspace

- Plain Obsidian-flavored Markdown. Three ways in: create a new note, **import** a
  folder (copied into the workspace), or **reference** a folder (edited in place,
  not copied)
- The sidebar shows the real folder hierarchy; notes open in tabs and save
  themselves when you pause typing, when the view goes away, and on quit
- `[[Note name]]` links, `![[image]]` embeds and `$math$` / `$$display math$$`
- **Your files stay the source of truth**: importing, renaming or moving a note
  never rewrites the text inside it

### Writing with a tablet stylus

- The Mac runs a small LAN server. Pair a tablet by scanning a QR code and the
  browser shows the current page image; you write on it with the stylus and the
  ink lands on the Mac live
- Ink is sent in normalized page coordinates over a binary protocol (WebSocket,
  plus UDP for the live stroke), so it stays in place whatever the Mac is zoomed to
- Pen barrel button switches tools; a long press brings up the pen ring
- An **Android client** lives in its own repository —
  [Unireader/uni-reader-android](https://github.com/Unireader/uni-reader-android) —
  with two modes: a standalone reader that works from an offline copy of the
  workspace, and an input-tablet mode paired to the Mac

### Agents and automation

- **Agent panel** in the inspector (ACP — currently [Kimi](https://github.com/MoonshotAI)):
  it can see which document and page you are on, search, add text notes,
  highlights and bookmarks, jump to a page, and read and edit the Markdown note you
  have open. Install and sign in to the agent in Terminal first, then enable it in
  Settings › Agent
- **MCP server** built into the app for outside agents — loopback only by default,
  optionally bound to all interfaces with a password
- `unireader://open?ws=…&doc=…&page=…&note=…` links, so a list written in Obsidian
  or by an agent can take you straight back to a page or a note

### Workspaces

A workspace is a `.unrd` package holding the library database, ink, images and
notes. It can live on an external disk; the **offline mirror** copies the whole
thing to the local disk so you can keep working (including writing ink) while the
disk is away, then merges the changes back three-way when you plug it in again.

## Requirements

macOS 26 (Tahoe) or later. The app is not sandboxed, signed with a Developer ID
and notarized by Apple. Earlier macOS versions are not supported.

## Install

Download the latest `.dmg` or `.zip` from
[Releases](https://github.com/Unireader/uni-reader/releases/latest) and move
`UniReader.app` into your Applications folder. The app updates itself through
Sparkle (UniReader › Check for Updates…, or Settings › General › Updates).

## Build from source

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), plus Node.js for the tablet capture page.

```bash
# 1. Build the tablet capture page (generates Sources/Resources/capture.html)
scripts/build-web.sh

# 2. Generate the Xcode project (UniReader.xcodeproj is generated — do not edit it)
xcodegen generate

# 3. Resolve the Swift packages once (needs network)
xcodebuild -project UniReader.xcodeproj -scheme UniReader \
  -derivedDataPath build/dev -resolvePackageDependencies

# 4. Build
xcodebuild -project UniReader.xcodeproj -scheme UniReader \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath build/dev build CODE_SIGNING_ALLOWED=NO
# → build/dev/Build/Products/Debug/UniReader.app
```

`scripts/package.sh` produces a signed and notarized build, and `scripts/release.sh`
publishes a GitHub release and updates `appcast.xml`; both need a Developer ID and a
notarization profile.

Swift packages used: [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
(Markdown editing and rendering, with LaTeX through SwiftMath),
[Sparkle](https://github.com/sparkle-project/Sparkle) (updates) and
[swift-acp](https://github.com/Unireader/swift-acp) (the agent client).

## Repository layout

| Path | What is in it |
|---|---|
| `Sources/App/` | App-level state: workspaces, sessions, render pipeline, ink logic |
| `Sources/Reader/` | The reading area (AppKit): page layers, zoom, ink, selection, overlays |
| `Sources/Window/` | Window shell, sidebar, inspector, panels and sheets |
| `Sources/Store/` | The workspace SQLite schema and data access |
| `Sources/Server/` | LAN WebSocket server, QR pairing, UDP transport |
| `Sources/MCP/` | The built-in MCP server |
| `Sources/Agent/` | The ACP agent panel |
| `web/` | The tablet capture page (Svelte + Vite, built into a single HTML file) |
| `spike/` | Standalone verification scripts (`swift spike/<name>.swift`) |

Development notes and design documents live at the top level; `AGENTS.md` is the
entry point and carries the map of the rest (`REQUIREMENTS.md`, `PROTOCOL.md`, and
the per-feature plan documents). They are written in Chinese.

## License

[GNU Affero General Public License v3.0](LICENSE).
