# Apple Books for PDFs

**Apple Books, but for PDFs.** A macOS reader that gives PDFs the Books experience — a library of covers, full-screen spreads, highlights and notes — while showing every page exactly as it was laid out, graphics and all.

Native Swift / SwiftUI / PDFKit. No dependencies. Builds with the command-line tools alone.

## Features

**Library**
- Drag PDFs or whole folders in (or ⌘O). The app keeps its own copy of each file.
- Covers rendered from each book's first page, collections, search, sort.
- Progress bars appear only on books you're *actually* reading — it tracks attentive time (reader frontmost, recent input) and sequential page turns, so peeking into a book doesn't mark it as in progress.

**Reader**
- The page owns the whole window. The title bar is a translucent strip that fades out after ~1 s idle and returns on mouse movement.
- Two-page spreads when the window is wide enough, a single page when it's narrow; switches live.
- Edge arrows and a page scrubber appear on hover only.
- Smooth ⌘+ / ⌘− zoom, ⌘0 to fit.
- Highlights in five colors plus underline, with notes; click a highlight to edit or remove it.
- **Margin braces**: hold ⌥ Option and drag beside the text to draw a hand-drawn-style brace spanning those lines. Stored as a highlight of the lines it covers.
- **Margin notes**: hold ⌘ Command and drag to draw a note card anywhere on the page and write in it. The note is linked to the lines beside it (or the nearest line), and shows up with that text in Notes & Highlights.
- Sidebar: page thumbnails, table of contents, bookmarks, notes & highlights, in-book search.
- Remembers your page per book; Go to Page accepts printed page labels (`xii`, `245`).

**Night mode** (dark appearance)
- Paper becomes charcoal and ink becomes light gray, but *pictures stay pictures*: the renderer scans each page's content stream for image placements, classifies each image from its pixels (color or photographic tones → keep as printed; scanned text / raster line charts → transmute like text), and composites the originals back in.
- Vector diagrams and colored headings keep their colors; anti-aliased edges are handled so colored text has no halo.
- Pages are pre-rendered around your position and a dark cover is placed before each turn, so page turns never flash white.
- A gentler **Dim** mode (soft gray paper) is also available. Light appearance offers Paper, Sepia and Soft Gray.

## Keyboard

| Action | Keys |
| --- | --- |
| Turn page | ← → or space / shift-space |
| Zoom in / out / fit | ⌘+ ⌘− ⌘0 |
| Go to page | ⌥⌘G |
| Bookmark | ⌘D |
| Find in book | ⌘F |
| Contents / Notes / Bookmarks | ⇧⌘T / ⇧⌘N / ⇧⌘B |
| Sidebar | ⌃⌘S |
| Margin brace | ⌥ + drag |
| Margin note | ⌘ + drag |

## Build

Requires macOS 14+ and the Xcode command-line tools (`xcode-select --install`).

```bash
./build.sh
```

This compiles the app, generates the icon, signs it ad hoc, and installs it to `~/Applications`. Set `APP_NAME` (or put a name in a local `.appname` file) to choose the name shown in the Dock and Finder; the default is `Books for PDFs`.

## Where your data lives

`~/Library/Application Support/Folio/` (the internal data folder name) — `library.json` (catalog, progress, highlights, braces), `Books/` (your PDF copies), `Covers/` (thumbnails). Delete the folder to start fresh.

## Layout

- `Sources/Models.swift` — library store, books, highlights, persistence
- `Sources/LibraryView.swift` — the home grid and sidebar
- `Sources/ReaderView.swift` — reader window, floating bar, sidebar panels, highlight bubble
- `Sources/PDFKitView.swift` — PDFView wrapper: hover zones, selection, braces, zoom, page-turn cover, auto-hiding bar
- `Sources/NightRendering.swift` — content-stream image finder, picture classifier, Night page renderer
- `Sources/FolioApp.swift` — app entry point, menus, appearance
