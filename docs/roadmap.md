# What Kylmora does not have yet

A gap list, written 2026-09-15 against the code as of commit `c6faebb`. It was
built two ways: a sweep of every folder under `Sources/Kylmora` to record what
actually exists, and the demand research in `docs/research/browser-features/`
(what people beg Orion, Zen, Arc, Vivaldi, Brave, Firefox and Safari for).
Anything the research listed as MISSING that has since been built is left out.

The browser already has most of what those users ask for: Spaces as separate
identities, sync to six backends, a command palette, tab archiving, split view,
Glance, Little Arc, web apps, mouse and rocker gestures, vim keys, link hints,
Boosts (per-site CSS/JS/dark mode), an element picker, cookie-banner
auto-reject, anti-fingerprinting, Touch ID lock, per-tab resource monitor,
screenshots, reader mode with read-aloud, customisable shortcuts and context
menu, 25 per-site settings, browser import from five browsers and Arc, and
enterprise policies. So the list below is what is genuinely left.

Legend: **fix** = ships today but does not really work · **table stakes** =
every browser has it · **demand** = ranked high in the research · **custom** =
customisation depth · **tiny** = an afternoon each.

---

## 1. Fixed: two features that looked real but were not

Both broke the README's "nothing in the UI is a mock" promise. Fixed on
2026-09-15:

| | Feature | What was wrong | What was done |
|---|---|---|---|
| fix | **Page translation** (⌥⌘T) | `NativeTranslationEngine.translate` checked Apple's `LanguageAvailability`, then unconditionally fell back to a hard-coded phrase dictionary. Pages were not translated. | `TranslationSessionHost` keeps an invisible SwiftUI view in each browser window and drives a real `TranslationSession` through it, batch by batch, applying each batch to the page as it returns. Apple's language-download sheet appears on that window when a pack is missing. The phrase table is gone; on macOS 14 the popover says the feature needs macOS 15 instead of pretending. |
| fix | **DNS over HTTPS** | `NetworkConfigManager.applyDoH` created an `nw_privacy_context` and stored it; it was never attached to anything, so WebKit kept using system DNS. | WebKit resolves names in its own network process, which only a system-wide setting reaches. The pane is now "Encrypted DNS": it writes a `com.apple.dnsSettings.managed` configuration profile for the chosen resolver (`DNSProfile`) and opens it for approval in System Settings, and the note says exactly what that does. The dead code is removed; the enterprise doc tells admins to push the same profile through MDM. |

Also verify and then claim in the README, because the research says switchers
test these on day one:

- **Apple Pay on the web** — WebKit disables it on pages where user scripts are
  injected. Boosts, autofill and site-behaviour scripts inject on every page, so
  Apple Pay may be silently off everywhere. Test on a real checkout.
- **Netflix / Prime / Disney+ (FairPlay DRM)** — test. If WKWebView cannot play
  them, document the limit up front rather than let people find out.
- **Google Meet tab sharing, WebUSB, WebSerial** — WebKit does not support
  them. Document the limits.

## 2. Table stakes still missing

Things a person expects from any browser and will hit within a week.

- ~~**Print** (⌘P)~~ Done 2026-09-15: File ▸ Page Setup…, Print… (⌘P) and
  Export as PDF…, through WebKit's own pagination. Headers and footers are
  still open.
- ~~**PDF viewer.**~~ Done 2026-09-15: PDFKit viewer with thumbnails, search
  and a match count, page number, zoom, rotate, Open in Preview and Save; a
  per-site setting chooses Kylmora's viewer, WebKit's, download, or Preview.
- **New Window** (⌘N). Only Little Arc, floating and web-app windows exist.
  A second full window with the same Spaces is expected, and "Move Tab to New
  Window" with it.
- **Passkeys / WebAuthn / Sign in with Apple.** No `ASAuthorization` code.
  Wire `ASAuthorizationController` for passkey registration and assertion
  from the page's WebAuthn calls; store in iCloud Keychain.
- ~~**Form autofill beyond passwords.**~~ Done 2026-09-15: identities
  (name, email, phone, company, address) in a JSON store and cards with the
  number in the Keychain; a page script classifies fields by autocomplete
  token and by name, fills on focus, never submits, never fills the CVC.
- ~~**A new-tab page.**~~ Done 2026-09-15: a native start page (pinned
  tiles, most visited, recently closed, reading list, the Space's colour),
  now the default for new tabs; the search page and the homepage remain
  choices. Still open: a clock, a blank option.
- **Localisation.** No `.lproj`, no `NSLocalizedString`. Wrap strings now
  while the count is manageable; ship 5 to 10 languages via String Catalogs.
- ~~**Per-tab audio badge**~~ Already there: `TabRowView` has an audio
  button per row; the first inventory missed it.
- ~~**History and password sync.**~~ Done 2026-09-15: the last 2,000
  visits merge across devices without duplicates; passwords travel only in
  a passphrase-encrypted archive and are stripped before CloudKit. The Sync
  pane gained a passphrase field.
- ~~**Toolbar customisation.**~~ Done 2026-09-15 for the bar above the page:
  tick and reorder its buttons in Browsing. Still open: the sidebar header's
  two buttons, drag rather than arrows, and layouts per Space.
- ~~**Horizontal tab bar option.**~~ Done 2026-09-15: a tab strip above the
  page (⌃⌘B), usable with any sidebar mode, so sidebar Hidden plus the strip
  is a conventional browser, with drag to reorder.
- ~~**Bang shortcuts**~~ Done 2026-09-15: `!g cats` and `cats !g` search
  the engine whose keyword is `g`, for built-in and custom engines alike.
- ~~**Tab search**~~ Already there: the tab overview (⇧⌘\) searches every
  tab in every Space live, with thumbnails and keyboard navigation.
- ~~**Screenshot annotation.**~~ Done 2026-09-15: an editor window with
  crop, arrow, box, circle, highlight, pixelating blur, text, undo, copy and
  save (⌃⌥⌘3 / ⌃⌥⌘4).

## 3. Demand list: still missing after the recent work

Ranked by how many trackers asked. Most of the original demand list is built;
these are the survivors.

| # | Feature | Why it matters | Sketch |
|---|---|---|---|
| 1 | **iPhone / iPad app** | The single most repeated "one missing feature" from Safari and Arc users. The companion Shortcut helps, but people want tabs and bookmarks on the phone. | Read-only first: a SwiftUI iOS app that reads the same encrypted sync archive and opens tabs in SFSafariViewController. Full browser later. |
| 2 | **Extension compatibility list** | Orion loses users because broken extensions silently pretend to work. | Auto-generate `docs/extensions.md` from a test matrix of the top 100 Chrome/Firefox extensions: works / partial (APIs missing) / broken. Show the verdict in the install sheet. |
| 3 | **AppleScript + CLI + URL scheme** | Power users automate browsers. | Done 2026-09-15 for the CLI and the scheme: `kylmora open <url> --space Work --background`, `kylmora space`, `kylmora command <palette id>`, `kylmora new-tab`, all as `kylmora://` addresses. Still open: an AppleScript dictionary (`sdef`) that can also read state and run JavaScript. |
| 4 | **Tree-style tabs** | Groups nest; tabs do not. Tree-style users want a tab opened from a tab to sit indented under its parent, collapsible. | Store `parentTabID`; indent in the sidebar; "close subtree". |
| 5 | **Semantic history search** | FTS5 exists; people want "that article about battery on Apple silicon last week". | Local embeddings with `NaturalLanguage` sentence embeddings, stored in SQLite, no network. |
| 6 | **Global media controls** | One place to pause whatever is playing, in any Space. | Extend the now-playing row into a popover listing every playing tab; hook `MPNowPlayingInfoCenter` so the keyboard media keys and Control Center work. |
| 7 | **Full RSS reader** | Live Folders subscribe; there is no reading view. | Unread counts, an article list, and a reader-mode article pane. |
| 8 | **Profiles export as a shareable file** | "Send me your setup." | Export a Space's look, pinned sites, routing rules and Boosts as `.kylmoraspace`; import merges. |
| 9 | **Per-site JS toggle in the address bar** | Exists as a per-site setting; people want the one-click switch. | Add JavaScript and Content Blocking toggles to the shield popover. |
| 10 | **Reader mode for every page, forced per domain** | Exists. Add "auto reader on sites that pass a threshold" and a reader theme editor (sepia, fonts, width, line height). | |

## 4. Customisation depth

The user's goal is "highly customizable". Kylmora has the switches; what it
lacks is the layer that lets people compose them.

**A rules engine ("when X, do Y").** Done 2026-09-15 as the Automations
pane: triggers are page loaded, tab idle, media started and download
finished; actions are move to Space, pin, mute, keep awake, Reader, zoom,
archive, close, message, open address, run Shortcut and run AppleScript,
exportable as JSON. Space routing got its first editor in the same pane.
Still open from the sketch below: time-of-day and Space-switched triggers,
Boost as an action, enterprise delivery.

- Triggers: URL matches, tab opened from app, time of day, Space switched,
  tab idle for N minutes, download finished, page title contains, media
  started.
- Actions: open in Space, pin, mute, reader mode, apply Boost, set zoom,
  block, archive, move to group, run shortcut, run AppleScript, notify.
- Editor in Settings; exportable as JSON; usable from enterprise policies.

**Custom commands.** Done 2026-09-15: a rule whose trigger is "run from
the command palette" appears in the palette under its name and runs its
actions on the current tab (open an address, run a Shortcut, run an
AppleScript, and every tab action). Still open: a keyboard shortcut per
custom command.

**Theme engine for the chrome.** Partly done 2026-09-15: theme files
(`.kylmoratheme`, export and import in the Spaces pane) and sidebar density.
Still open from the list below:

- Sidebar density (compact / regular / roomy), row height, favicon size.
- UI font and size for the chrome.
- Accent colour independent of the Space colour.
- Corner radius, hairlines on/off, vibrancy on/off.
- Custom CSS for the reader, error pages and start page.
- Themes as files (`.kylmoratheme`), a gallery in Settings, share/import.

**Keyboard.** Done 2026-09-15: chords (record a stroke, then a plain key
within a moment), a cheat sheet on ⌘/, and a shortcut per custom command.
Still open: a leader key for vim mode and per-Space shortcut overrides.

**Mouse.** Configurable actions for middle-click, ⌘-click, ⌥-click,
double-click on empty sidebar, scroll on tab list, and the gesture map with
more actions (split, glance, mute, pin, reader).

**Tab appearance.** Done 2026-09-15: colour tags, the unread dot and an
emoji per tab. Still open: a "favicon only" mode, show/hide close buttons,
the URL under the title.

**Per-Space everything.** Done 2026-09-15: search engine, user agent,
default zoom and sleep delay. Still open: a content-blocking profile,
startup page and shortcut overrides per Space.

**Site settings.** Now 29: images, clipboard reading and the referrer were
added 2026-09-15 (PDF Documents earlier the same day). Still open: default
font per site, forced minimum contrast, GIF autoplay, WebGL, sensors, and
"open links from this site in Space X" (Space routing covers the last one
by hand).

**Configurable start-up.** Open the last session / a fixed Space / a
specific set of URLs / blank; ask whether to restore after a crash.

**Import and export for every store.** Bookmarks HTML, Netscape and JSON;
history CSV; passwords CSV (Touch ID gated); shortcuts JSON; Boosts; rules.

## 5. Tiny features, one afternoon each

- ~~Copy URL as Markdown link~~ and ~~"Copy Title and URL"~~ Done
  2026-09-15, in the Edit menu and the palette. Still open: as QR code,
  "Copy Selected Text as Quote".
- Paste and Go / Paste and Search in the omnibox context menu.
- ~~Reload every N seconds on this tab~~ Done 2026-09-15 (Auto Reload in the tab menu, ↻ badge).
- "Open all links in selection" and "Open all in group as split".
- Undo close tab with a toast "Reopen" button.
- ~~Tab notes~~ Done 2026-09-15 (Add Note… in the tab menu, shown in the tooltip).
- Word count / reading time in reader mode and in the status bar.
- Hover status bar showing the link target, with a delay setting.
- Highlight all matches with a count in the Find bar; regex and
  whole-word find; find in the reader view.
- Zoom indicator badge in the address bar with a reset click.
- Recently closed Spaces, not just tabs.
- Tab-close confirmation for tabs with unsaved form data (`beforeunload`)
  and a "close anyway" button that lists them.
- Site-specific favicon override (pick an SF Symbol or emoji).
- Double-click a tab to rename (exists via menu; check the gesture).
- ~~Sort tabs by domain / title / last used.~~ Done 2026-09-15.
- ~~"Close duplicate tabs" and a duplicate-tab indicator.~~ Done 2026-09-15 (⧉ in the row's badge slot).
- Send tab to Space by drag onto the Space switcher (verify it is there).
- Text encoding menu.
- ~~View page source in a tab~~ Done 2026-09-15 (⌥⇧⌘U, line-numbered).
- Save page as Web Archive / complete HTML.
- Bookmark all tabs into a dated folder (exists; add "and close them").
- ~~Quick Look a download from the downloads list (space bar).~~ Done 2026-09-15.
- Clear the download list on quit option.
- Download bandwidth cap and parallel-download limit.
- A "downloads in progress" dock badge and a quit warning.
- Dock badge for unread reading-list count.
- Notifications settings: sound per site, "do not disturb" hours.
- Search the current page from the omnibox with a `/` prefix.
- Bookmarklets (they are user scripts; expose "Add Bookmarklet").
- Open selected text as a URL.
- Shake the mouse to find the cursor in Zen mode (macOS does it; ensure
  Zen mode respects it).
- Confirm-before-quit only when N tabs are open (setting).
- Autocomplete of the whole URL inline in the omnibox with an opt-out.
- Suggest search engine for the current site ("Add Kylmora search for
  github.com?") when the site has an OpenSearch description.
- Menu bar extra / Dock menu with recent tabs and "New tab in Space".
- Handoff to Safari on iPhone via `NSUserActivity` (works today with no
  iOS app, because Safari accepts web activities).
- Continuity: receive tabs from Safari on iPhone through Handoff.
- Share sheet extension target ("Add to Kylmora reading list").
- Services menu items: "Open in Kylmora", "Search with Kylmora".
- Accessibility: reduce motion honoured for sidebar slides; increased
  contrast theme; every control's `accessibilityLabel` audited with the
  Accessibility Inspector.
- Sound effects toggle (tab close, download done) with the system sounds.
- Settings search that also finds per-site settings and shortcuts.
- ~~"What's new" sheet after an update~~ Done 2026-09-15, linking to the release on GitHub.
- A diagnostics export: settings, version, filter-list versions, no
  history, for bug reports.

## 6. Bigger bets, in priority order

1. **iOS app.** The most-wanted thing across every source; nothing else on
   the list moves as many people.
2. **Opt-in local AI**, and nothing else. The research is blunt: users want
   no AI, or AI that is opt-in, local, and invisible when off. The only
   accepted uses are summarise-this-page, group-my-tabs, and semantic
   history search, all via Apple's `FoundationModels` on device. No account,
   no upload, one master switch defaulting to off.
3. **Extension store surface** inside the app: search the Chrome and Firefox
   catalogues from Settings, with the compatibility verdict shown before
   install.
4. **Sync for history and passwords** and a "device list" that shows what is
   syncing, with remote sign-out.
5. **Windows / Linux?** No. The advantage is system WebKit and 1.2 MB. Stay
   on Apple platforms and say so.

## 7. Suggested order for the next few releases

- **Next release:** ~~real translation, DoH honesty, Print~~ (done), PDF
  viewer, passkeys. New Window is deliberately not on the list: "one window"
  is a stated design principle in the README, so that is a product decision
  before it is a feature. Passkeys need the
  `com.apple.developer.web-browser.public-key-credential` entitlement, which
  has to be provisioned for the app ID before any code can be verified.
- **After that:** new-tab page, form autofill, bang search, tree-style
  tabs, rules engine v1 (extend routing), custom commands, theme files.
- **Then:** localisation, screenshot annotation, AppleScript + CLI,
  extension compatibility list, global media controls, RSS reading view.
- **Long-running:** iOS app, opt-in local AI, history and password sync.

Every item above should follow the existing rule: if a control is there, it
does something. Better to ship fewer switches than a switch that fakes it.
