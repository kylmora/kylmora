# Tools: the design

A native workbench inside Kylmora for the small jobs people currently do by
uploading a private file to an ad-covered website and hitting a paywall on the
third one. Merge a PDF, turn a HEIC into a JPG, pull the text out of a
screenshot, cut the background off a photo.

Written 2026-09-16 against the code at `d44bc34`.

The whole proposition is one sentence, and it is the line that goes on the
page: **every tool here runs on your Mac, and no file ever leaves it.** That
is not marketing. Everything below is built on frameworks that ship with
macOS — PDFKit, ImageIO, Vision, Core Image — so there is no server to send a
file to even if we wanted one, and no third-party code, which keeps the
promise the About pane already makes.

---

## 1. Where it lives

**A tab, at `kylmora://tools`.** Not a settings pane, not a separate window,
not a web page.

The mechanism already exists and is already proven twice. `StartPage` is a
native `NSView` drawn over a blank web view, addressed as `kylmora://start`,
carried through the session file, and never fetched (`Tab.contentOverlay`,
`Tab.showsStartPage`). `PDFDocumentView` is the same pattern for a document.
Tools is the third instance of a pattern the browser already runs on, so it
costs one URL host, one `showsTools` flag and one branch in `contentOverlay`.

Why a tab beats the alternatives:

| | Why not |
|---|---|
| Settings pane | Settings is where you configure the browser. Tools is where you do a job — drag a file in, act, get a file out. Different room, and Settings has no place to put a file. |
| Separate window | A second app bolted to the side, with its own lifecycle, its own menu handling, and no relationship to Spaces. |
| A web page we host | Would break the one promise that makes the feature worth having. |

Because it is a tab it gets, for free: session restore, ⌘W, back/forward,
archiving, renaming, a colour tag, and **split view** — so Merge PDF can sit
beside the PDF you are reading. None of that has to be written.

### The four doors

One room, four ways in. The hub is for discovery; everything after the first
time should be contextual.

1. **Start page.** A "Tools" strip of tiles under the pinned sites. The start
   page already has a tile row and a model to feed it.
2. **Command palette (⌘K).** Each tool is its own `CommandCandidate`, so
   typing `heic`, `merge`, `ocr` or `background` lands on *that tool* with its
   bench already open — not on the hub. This is the fastest door and the one
   power users will actually use.
3. **Toolbar button.** One new entry in `ToolbarLayout.catalog` — `Tools`,
   `wrench.and.screwdriver` — opening a small grid popover. It joins the
   existing catalog, so it can be reordered or hidden with the drag list in
   Settings ▸ Browsing like every other button. No new settings surface.
4. **Context, which is where it wins.**
   - Right-click an image on a page → *Convert…*, *Remove Background…*,
     *Text from Image*.
   - A PDF open in the viewer → *PDF Tools* in the top bar, with the open
     document already staged.
   - A download finishes → the toast offers the tool that fits the file type.

Plus the one that matters most: **drop a file anywhere on the window** and
Tools opens with it staged and the likely tool already chosen. A dropped
`.heic` opens Convert. Two dropped PDFs open Merge.

---

## 2. The UI

Kylmora's own vocabulary, not a stock Apple inspector. Every measurement below
is an existing `Style` token or a new one in the same family, so the page reads
as part of the browser rather than as a utility someone stapled on.

The page is built from three shapes the chrome already uses: **the plate** (a
container, radius 12, `folderPlateFill`), **the pill** (a row, radius 8,
`rowSelectedFill` + hairline + soft shadow), and **the tile** (radius 10). A
tool card is a tile grown up. Nothing new is invented.

### 2.1 The hub

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   Tools                                                      │  title, 22 semibold
│   Everything here runs on your Mac. No file leaves it.       │  note, secondary
│                                                              │
│   ╭────────────────────────────────────────────────────────╮ │
│   │  PDF                                                   │ │  plate, radius 12
│   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │ │  folderPlateFill
│   │  │ ⧉        │ │ ⑂        │ │ ⤓        │ │ ⊕        │   │ │
│   │  │ Merge    │ │ Split    │ │ To Images│ │ From     │   │ │  tool cards
│   │  │ two into │ │ one into │ │ page by  │ │ Images   │   │ │  168 x 112
│   │  │ one      │ │ many     │ │ page     │ │          │   │ │
│   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │ │
│   ╰────────────────────────────────────────────────────────╯ │
│                                                              │
│   ╭────────────────────────────────────────────────────────╮ │
│   │  Images                                                │ │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────┐                │ │
│   │  │ Convert  │ │ Resize   │ │ Remove   │                │ │
│   │  │ HEIC to  │ │ to a     │ │ Background│               │ │
│   │  │ anything │ │ size     │ │          │                │ │
│   │  └──────────┘ └──────────┘ └──────────┘                │ │
│   ╰────────────────────────────────────────────────────────╯ │
│                                                              │
│   Or drop a file anywhere on this window.                    │  note, tertiary
└──────────────────────────────────────────────────────────────┘
```

Centred column like the start page, `lessThanOrEqualToConstant: 880` (wider
than the start page's 760 — a card grid needs four across before it wraps),
32pt side gutters, 56pt top and bottom.

**The tool card** — a tile grown to hold two lines:

- 168 × 112, corner radius 12 (`folderPlateCornerRadius`: a card is a
  container, and rhymes with the plate it sits on rather than with the pills).
- A 22pt SF Symbol top-left, tinted with the Space's colour. The Space tint is
  already everywhere else in the chrome; this is what stops the page looking
  like a generic grid of grey boxes.
- Name in `Fonts.emphasis` (13 semibold), then one line in `Fonts.note` (11,
  secondary) saying what it does in plain words.
- Rest `tileFill` (veil 0.42 / 0.07) + `Colors.hairline`.
- Hover `tileHoverFill` (veil 0.68 / 0.13), and it **lifts**: `rowSelectedShadow`
  at `cardShadowRadius`, over `Motion.hover` (0.09s) on `Motion.curve`.

That lift is `RowHighlight` with `Depth.raised`, which already exists, is
already tested, and already honours Reduce Motion by using a zero duration
rather than skipping the change. The card is a new frame around a component
the sidebar is already built on.

### 2.2 The bench

Choosing a tool slides the hub out and the bench in over `Motion.selection`
(0.16s). Same curve as a sidebar selection moving, because it is the same kind
of event: something the user just committed to, which can afford to be seen
travelling.

```
┌──────────────────────────────────────────────────────────────┐
│  ‹ Tools / Merge PDF                                         │  breadcrumb
│                                                              │
│  ╭─────────────────────────────╮  ╭───────────────────────╮  │
│  │  ⠿  Invoice-March.pdf   4p ×│  │  Options              │  │
│  │  ⠿  Invoice-April.pdf   2p ×│  │                       │  │
│  │  ⠿  Receipts.pdf       11p ×│  │  Keep bookmarks   [ ●]│  │  SettingsToggle
│  │                             │  │  Page numbers     [● ]│  │
│  │  ＋ Add files…              │  │                       │  │
│  ╰─────────────────────────────╯  │  Save to              │  │
│                                    │  Beside the original ▾│  │
│   17 pages · about 2.4 MB          │                       │  │
│                                    │  ╭─────────────────╮  │  │
│                                    │  │   Merge PDFs    │  │  │  primary
│                                    │  ╰─────────────────╯  │  │
│                                    ╰───────────────────────╯  │
└──────────────────────────────────────────────────────────────┘
```

**The file list is the sidebar's row pill, reused exactly**: radius 8,
`rowHoverFill` on hover, `rowSelectedFill` + hairline + shadow when selected,
`rowHeight` from the sidebar density setting. A file row looks like a tab row
because in this browser a row of things looks like that.

And it is a **`ReorderableStackView`** — the drag-to-reorder control already
built and tested for the toolbar list, including the `mouseDownCanMoveWindow`
fix that stops a drag carrying the window with it. For Merge PDF the order of
that list *is* the merge order, so the most important control in the tool is
one already-finished component, with no new interaction to learn.

**The options panel** is a plate carrying `SettingsToggle` and the settings
controls — the app's own switches, not AppKit checkboxes. It matches Settings
without being Settings.

**The primary button** is full-width at the foot of the options panel, with
the live summary ("17 pages · about 2.4 MB") on the left under the file list,
so the thing you are about to make is described before you make it.

### 2.3 Finishing

Default output is **beside the original**, named `Invoice-March-merged.pdf`,
with the existing toast reporting it and offering *Show in Finder*. The
alternative in the Save-to menu is the Downloads folder, which routes through
`DownloadManager` so the result appears in the downloads popover like anything
else the browser produced. The entitlements file is empty — the app is not
sandboxed — so writing beside the original works without a save panel.

Nothing is ever written over the input. A tool that can destroy the file you
fed it is a tool people stop trusting.

---

## 3. What ships first

Nine tools, chosen because each is a paywall somewhere else and each is a
handful of calls into a framework that is already on the machine.

| Tool | Built on | Paid elsewhere as |
|---|---|---|
| Merge PDF | PDFKit | Smallpdf, iLovePDF |
| Split PDF | PDFKit | same |
| PDF → Images | PDFKit + ImageIO | same |
| Images → PDF | PDFKit | same |
| Compress PDF | PDFKit + Core Image | same |
| Convert image (HEIC/PNG/JPG/WebP) | ImageIO | a hundred converter sites |
| Resize image | Core Image | same |
| Remove background | Vision | remove.bg, ~$9/mo |
| Text from image (OCR) | Vision | Prizmo, OCR sites |

`PDFKit`, `ImageIO`, `UniformTypeIdentifiers` and `CoreGraphics` are already
imported somewhere in the source. **`Vision` is the one new system framework**
— free, on-device, no network, no entitlement.

Held back deliberately for later: media trimming and conversion (AVFoundation
covers fewer formats than people expect, and ffmpeg would break the
no-third-party-code promise — so it ships when it can be honest about the
limit), and anything that downloads media from a page, which is the highest-
demand item in this category and the fastest route to legal trouble.

---

## 4. Rules

- **If a control is there, it does something.** The README's promise applies
  hardest here, because a broken tool is worse than an absent one: someone
  came to Kylmora specifically to avoid the site that wasted their time.
- **No progress theatre.** These operations are fast. A merge that takes 200ms
  gets a result, not a fake progress bar.
- **Every tool states its limit.** Compress PDF says how much it actually
  saved. OCR names the languages it recognised. A tool that quietly does less
  than the site it replaced is how the promise gets broken.
- **Nothing new in the sidebar.** Tools is a tab. It does not get its own
  permanent chrome, its own icon in the footer, or its own settings pane.

---

## 5. Order of work

1. `kylmora://tools` routing — the host, the `showsTools` flag, the
   `contentOverlay` branch, session restore. Nothing visible yet.
2. `ToolsHubView` — plates, tool cards, hover lift. The hub with tools that
   are not built yet simply lists fewer of them.
3. `ToolsBenchView` — breadcrumb, reorderable file list, options plate,
   primary action. One tool end to end: **Merge PDF**.
4. The rest of the PDF tools against that bench.
5. The image tools, then Vision for background removal and OCR.
6. The four doors: start-page strip, command palette entries, toolbar button,
   context menus, window-wide drop.

Step 3 is the one that proves the design. Everything after it is filling in a
shape that already works.
