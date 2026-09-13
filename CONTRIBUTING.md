# Contributing to Kylmora

Thanks for your interest in Kylmora! It's a native macOS browser built on
AppKit and the system WebKit, with **zero third-party dependencies**.
Contributions of every kind are welcome — bug reports, feature ideas,
documentation, tests, and code.

This document explains how to get set up and how changes make their way in.
Please also read our [Code of Conduct](CODE_OF_CONDUCT.md); by participating you
agree to uphold it.

## Ways to contribute

- **Report a bug** — open an issue with steps to reproduce. (Use the bug template.)
- **Suggest a feature** — open an issue describing the problem it solves.
- **Improve the docs** — fixes to the README or this guide are very welcome.
- **Write code** — fix a bug or build a feature. For anything non-trivial,
  please open an issue first so we can agree on the approach before you spend time on it.
- **Test it** — try it on different macOS versions and hardware and report what you find.

Browse the [open issues](../../issues) to find something to work on; issues
labelled `good first issue` are a gentle place to start.

## Prerequisites

- **macOS 14 (Sonoma) or later.** macOS 15.4+ is needed for the extensions feature.
- **A Swift 6 toolchain.** Xcode is **not** required — the Command Line Tools are
  enough: `xcode-select --install`.
- **Nothing else to install.** The project has no package manager and no
  dependencies; it links only Apple system frameworks.

## Getting the code

```sh
# Fork the repo on GitHub, then:
git clone https://github.com/<your-username>/kylmora.git
cd kylmora
make run        # builds, bundles and launches the app
```

## Building and running

Everything goes through the `Makefile`:

```sh
make run        # build, bundle and launch build/Kylmora.app
make bundle     # build the app bundle without launching
make test       # run the unit test suite — must stay green
make size       # report the release bundle size
make measure    # launch and report launch time, memory and bundle size
```

## Project layout

```
Sources/Kylmora/
├── Application/      App delegate, menus, launch, update check
├── Window/           The single main window and its chrome
├── Sidebar/          The vertical sidebar (tabs, spaces, actions)
├── UI/               Reusable chrome views (command bar, rows, buttons, styling)
├── Tabs/             Tab model, lazy web views, suspension
├── Spaces/           Spaces (per-identity workspaces), themes, borders
├── Session/          The in-memory browser model and its change notifications
├── Storage/          Session JSON, SQLite history/bookmarks, app paths
├── Web/              WebKit environment, navigation, error pages
├── Navigation/       URL resolving, search engines, address formatting
├── Downloads/        Download manager, list window, destinations
├── Find/             Find in page
├── Favicons/         Anonymous favicon fetching and caching
├── Folders/          Tab groups and live folders (RSS/GitHub)
├── Glance/           Peek-at-a-link overlay
├── Split/            Split view
├── Compact/          Compact (auto-hiding) sidebar mode
├── ContentBlocking/  Filter lists compiled to WebKit content rules
├── Extensions/       WebKit extension engine integration
├── Bookmarks/        Import from other browsers
├── Passwords/        Keychain-backed logins and autofill
├── Sites/            Per-website settings and behaviour scripts
├── Settings/         The Settings window and its panes
└── ...
Tests/KylmoraTests/   The swift-testing suite
Tools/                make-icon.py, measure.sh
Resources/            Info.plist, entitlements, app icon
```

## Development workflow

1. Create a branch off `main`: `git checkout -b fix-the-thing`.
2. Make your change.
3. Run `make test` — **the full suite must pass.** Add tests for new behaviour or bug fixes.
4. Keep the diff focused; one logical change per pull request.
5. Commit, push to your fork, and open a pull request.

## Code style and principles

Match the style of the code around you. A few principles the project holds to:

- **Swift 6 strict concurrency.** Most UI types are `@MainActor`.
- **System frameworks only.** No third-party packages. If you believe a
  dependency is genuinely needed, open an issue to discuss it before adding one —
  the bar is high, and the answer is usually a small amount of first-party code.
- **No fake UI.** Every control must do something real. Don't add a button,
  menu item, or switch that looks functional but isn't wired up.
- **Comments explain *why*, not *what*.** The reasoning behind a non-obvious
  decision is worth writing down; a paraphrase of the code is not.
- **Prefer the platform.** Reach for the AppKit/WebKit API before reinventing it.

## Tests

Tests use **swift-testing** (not XCTest) and run with `make test`. Please add
tests for new behaviour and for any bug you fix, and make sure the whole suite is
green before opening a pull request.

## Commit messages

- A short, imperative summary line (e.g. "Fix sidebar drag on narrow windows").
- A body explaining *why* when the change isn't obvious.
- Reference issues where relevant, e.g. `Fixes #123`.

## Pull requests

- Keep each PR to a single focused change.
- Describe what the change does and why; link the issue it addresses.
- Make sure `make test` passes. Continuous integration runs it on every pull request.
- A maintainer will review it; please be responsive to feedback.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE), the same license that covers the project.
