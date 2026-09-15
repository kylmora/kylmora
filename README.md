# Kylmora

![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/swift-6-orange.svg)
[![CI](https://github.com/kylmora/kylmora/actions/workflows/ci.yml/badge.svg)](https://github.com/kylmora/kylmora/actions/workflows/ci.yml)

**A lightweight, native macOS browser.** An AppKit shell over the system WebKit,
one window with Spaces inside it, and no bundled engine or third-party
dependencies — the release build is around 1.2 MB.

<p align="center">
  <img src="assets/screenshot.png" alt="Kylmora's vertical sidebar with Spaces, pinned sites and tab groups" width="440">
</p>

[kylmora.com](https://kylmora.com)

> **Status:** feature-complete for everyday browsing, and sandboxed. Downloads,
> find-in-page, favicons, content blocking, extensions and per-space identities
> all work. Nothing in the UI is a mock — if a control is there, it does
> something. An AI-automation layer is planned; nothing built so far depends on it.

**Contributions are welcome** — see [Contributing](#contributing).

## Contents

- [Install](#install)
- [Features](#features)
- [Requirements](#requirements)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Contributing](#contributing)
- [Performance](#performance)
- [Where data lives](#where-data-lives)
- [Updates](#updates)
- [Name and icon](#name-and-icon)
- [License](#license)

## Install

Download the latest build from the releases page:
**https://github.com/kylmora/kylmora/releases/latest** — open the `.dmg` and drag
Kylmora to Applications. Builds are signed with a Developer ID and notarized by
Apple, so they open without a security warning.

Prefer to build it yourself? See [Building from source](#building-from-source) —
you'll need macOS 14+ and a Swift 6 toolchain (no Xcode required).

Rolling it out to a fleet? [docs/enterprise-policies.md](docs/enterprise-policies.md)
covers deploying the `.dmg` through an MDM and locking settings with a
configuration profile or a `policies.json`; a sample profile is in
`Resources/Enterprise/`.

## Features

- One window. Spaces and tabs switch inside it, never by opening another window
- Vertical sidebar: omnibox, navigation, the active space's tabs, space switcher
- Tabs: open, close, reorder by dragging, close button on hover, loading spinner
- Spaces: create, rename, close, switch. Each keeps its own tabs and selection
- Tabs are lazy. A tab that has not been shown has no web view and no WebKit
  process behind it; closing one releases its process immediately
- `window.open` and `target="_blank"` open a real tab next to their opener
- Sessions restore on launch, including each tab's scroll position, form contents
  and back-forward history, without reloading it from the network
- History, with omnibox completion ranked by how often and how recently you
  visited a site
- Bookmarks, in the menu bar, with Cmd-D to add or remove the current page
- Background tabs are suspended after an idle period and under system memory
  pressure. A suspended tab is dimmed in the sidebar and reopens where it was
- Links from other apps, and `open -a Kylmora <url>`, land in a tab in the current
  space rather than a new window
- Failed loads show a native error page naming the host, with Try Again where
  retrying could actually help. Certificate failures deliberately do not offer it
- VoiceOver reads a tab's state, including suspended and failed, not just its title
- Downloads, into `~/Downloads`, with a list showing live progress, Stop, Resume,
  Show in Finder and Open. Filenames supplied by a page are treated as untrusted
- Find in page on WebKit's own API
- Favicons in the sidebar, fetched anonymously outside every space so the
  request carries no cookies and no identity
- The address bar shows the page you are actually looking at. It does not follow
  a navigation that has started but not committed
- Spaces are identities: each has its own cookies and logins, so the same site
  can be signed into as a different account in each one. A private space writes
  nothing to disk and comes back empty on relaunch
- Window borders, per space: a solid, glass or gradient rim around the window in
  the space's own colours, so any corner of the screen says which identity is in front
- A look per space: light or dark, a custom colour, a page's own theme colour on
  the chrome if the space allows it, a bookmarks bar, default fonts, and
  full-screen behaviour
- Content blocking through WebKit's own content rule lists, fed by EasyList,
  EasyPrivacy, the cookie-banner lists and uBlock Origin's filters, fetched
  anonymously and on by default
- Extensions on WebKit's own extension engine, which reads the manifest format
  Chrome and Firefox extensions use: paste a Chrome Web Store or addons.mozilla.org
  link in Settings, or install a `.zip`, `.crx`, `.xpi` or an unpacked folder
  (needs macOS 15.4)
- Search engines with keywords, custom engines from any site's search box, and a
  separate engine for private spaces
- Privacy controls: tracking parameters stripped from links, scheduled history and
  cookie removal, a website-data manager, a reset, local crash reports you decide
  about, and a custom user agent
- Per-website settings — twenty of them — each with a default and per-site
  exceptions: reader mode, auto-play, zoom, pop-ups, notifications, camera,
  microphone, location, JavaScript, cookies, and more
- System WebKit, no bundled engine

## Requirements

- macOS 14 (Sonoma) or later — for per-space `WKWebsiteDataStore`. Extensions
  need macOS 15.4.
- A Swift 6 toolchain. **Xcode is not required** — the Command Line Tools are
  enough (`xcode-select --install`).

## Building from source

Everything goes through the `Makefile`:

```sh
make run      # build, bundle and launch build/Kylmora.app
make bundle   # build the app bundle without launching
make test     # run the unit test suite
make size     # report the release bundle size
make measure  # launch and report launch time, memory and bundle size
```

There are no dependencies to fetch first — the project links only Apple system
frameworks.

## Project layout

```
Sources/Kylmora/
├── Application/      App delegate, menus, launch, update check
├── Window/           The single main window and its chrome
├── Sidebar/          The vertical sidebar (tabs, spaces, actions)
├── UI/               Reusable chrome views (command bar, rows, buttons, styling)
├── Tabs/             Tab model, lazy web views, suspension
├── Spaces/           Spaces (per-identity workspaces), themes, borders
├── Session/          The in-memory browser model and change notifications
├── Storage/          Session JSON, SQLite history/bookmarks, app paths
├── Web/              WebKit environment, navigation, error pages
├── Downloads/        Download manager, list window, destinations
├── Folders/          Tab groups and live folders
├── ContentBlocking/  Filter lists compiled to WebKit content rules
├── Extensions/       WebKit extension engine integration
├── Settings/         The Settings window and its panes
└── ...
Tests/KylmoraTests/   The swift-testing suite
Tools/                make-icon.py, measure.sh
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Cmd-L | Open the command bar |
| Cmd-T | New tab |
| Cmd-W | Close tab |
| Cmd-R | Reload |
| Cmd-. | Stop loading |
| Cmd-F | Find in page |
| Cmd-G / Cmd-Shift-G | Find next / previous |
| Cmd-Opt-L | Downloads |
| Cmd-[ / Cmd-] | Back / forward |
| Cmd-Opt-Right / Left | Next / previous tab |
| Cmd-Opt-Down / Up | Next / previous space |
| Cmd-1 … Cmd-9 | Select tab by position, 9 being the last |
| Cmd-D | Add or remove a bookmark |
| Cmd-, | Settings |
| Ctrl-Cmd-S | Toggle the sidebar |
| Ctrl-Cmd-F | Full screen |

## Contributing

Contributions of every kind are welcome — bug reports, feature ideas,
documentation, tests and code. The short version:

1. Read the [Contributing guide](CONTRIBUTING.md) and the
   [Code of Conduct](CODE_OF_CONDUCT.md).
2. For anything non-trivial, open an issue first to agree on the approach.
3. Fork, branch off `main`, make your change, and keep `make test` green.
4. Open a pull request describing what you changed and why.

New here? Issues labelled **`good first issue`** are a friendly starting point.
The full guide covers setup, the project's code-style principles (Swift 6 strict
concurrency, system frameworks only, no "fake" UI), and the review process.

## Performance

Figures from `make measure` on macOS 26.6, Apple silicon. Memory is physical
footprint — the number Activity Monitor shows.

| Metric | Value |
|---|---|
| Release bundle | 1.2 MB |
| Bundled frameworks | 0 |
| Package dependencies | 0 |
| Launch to window on screen | 0.51 s |
| Footprint at that moment | 24 MB |
| Browser process, 25 restored tabs, one shown | 30 MB |
| WebKit content process, one page | 52 MB |

Twenty-five restored tabs cost a single content process, because a tab that has
not been shown has no web view.

## Where data lives

Everything is keyed by the bundle identifier, `com.kylmora.Kylmora`, under
`~/Library/Application Support/com.kylmora.Kylmora/`:

- `session.json` — spaces, tabs, and each tab's saved interaction state
- `browser.sqlite` — history and bookmarks
- `downloads.json` — the downloads list, capped at 100 rows

Every space after the first keeps its website data in
`~/Library/WebKit/com.kylmora.Kylmora/WebsiteData/<uuid>/`, managed by WebKit;
the first space uses WebKit's default store. Downloaded files go to `~/Downloads`.
Preferences live in `UserDefaults` under `com.kylmora.Kylmora`.

## Updates

Settings has an About pane with the version and a "Check for Updates…" button
that fetches `https://kylmora.com/releases/latest.json` — a document of the form
`{"version": "0.2.0", "url": "https://kylmora.com/download", "notes": "…"}` — and
says whether this build is the newest. It runs only when clicked and sends nothing
about you or your Mac.

## Name and icon

The app icon is built from the blue K mark at `Resources/Icon/kylmora-mark.png`
by `Tools/make-icon.py`, which places it on a white rounded square on Apple's icon
grid and writes `Resources/Kylmora.icns`. `make bundle` regenerates the icon when
the mark or the script changes.

## License

Licensed under the [Apache License 2.0](LICENSE). By contributing, you agree that
your contributions will be licensed under it as well.
