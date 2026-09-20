# Closing the gap with Crest: where we are

Written 2026-09-20. `main` is at `054f2c3`; the `declarativeNetRequest` work in
the last section is finished and tested but not yet committed.

The starting point was a read of [Crest](https://crestbrowser.com/) and its
source (MPL-2.0) against `Sources/Kylmora`, to find what a direct competitor
ships that we do not. None of their code was used; only the shape of the
problem. The four items below were taken in order of user-visible value.

---

## Done

### 1. Native messaging — PR #12, `cafc954`

An extension can talk to an app installed on the Mac. This is what makes a
password manager's extension work at all: the vault lives in the app and the
extension is only a front end.

- Reads the host manifests apps already install for Chrome, Chromium, Edge,
  Brave, Vivaldi, Opera, Arc and Firefox as well as Kylmora's own, because
  almost no app ships a Kylmora manifest -- and the app's own manifest still
  decides which extensions may reach it.
- 4-byte length framing, persistent connections, per-host allow lists,
  enterprise policy keys, and a Settings list that says **why** a manifest was
  refused rather than silently ignoring it.
- **Verified** with real `python3` hosts spawned as real processes, not mocks.
- Docs: `docs/native-messaging.md`.

### 2. Extension side panels — PR #13, `0dd7f1f`

Extensions that put their interface beside the page instead of in a popup.
Both spellings: Chrome's `chrome.sidePanel` and Firefox's
`browser.sidebarAction`.

- WebKit's engine has **neither** API. Confirmed empirically inside a real
  background service worker, not assumed. So Kylmora provides the API and the
  panel itself.
- The panel is styled as the page card is -- same radius, gutters, hairline,
  shadow and header height -- after three rounds of correction.
- **Verified** with the shim loaded into a real `JSContext`.
- Docs: `docs/extension-side-panels.md`.

### 3. Web notifications — PR #17, `054f2c3`

A page that calls `Notification`, or a service worker's `showNotification`,
gets a real macOS notification, and **clicking it returns to the tab that sent
it**, switching Space if need be.

The note that started this said we had nothing. That was wrong -- there was a
shim -- but it was a stub: clicks did nothing, `tag` stacked instead of
replacing, `close()` never withdrew, `addEventListener` was an empty function,
permission reset on reload, and **no `UNUserNotificationCenterDelegate` existed
anywhere**, so a notification posted while Kylmora was frontmost was swallowed
entirely. That is the common case, not an edge one.

- **Verified** with seven end-to-end tests in a real `WKWebView` over the real
  message bridge.
- Known limits: no Push, so a site can only notify while one of its pages is
  open; a service worker's own `notificationclick` handler cannot run (the shim
  lives in the page), though the click still focuses the tab; no actions.
- Docs: `docs/web-notifications.md`.

### 4. `chrome.declarativeNetRequest` — finished, **not yet committed**

The widest gap. WebKit's engine does not implement the API, so an MV3 content
blocker -- which is most of them now -- installs cleanly, reports no error,
shows a healthy icon and **blocks nothing**.

Kylmora now reads the rules itself and translates them into a
`WKContentRuleList`, so the matching runs inside WebKit's own matcher.

- Static rulesets, dynamic rules (kept across launches), session rules,
  `updateEnabledRulesets`, and the rest of the namespace.
- `redirect` and `modifyHeaders`, which the content matcher cannot express, are
  applied at navigation time for pages and frames.
- **Verified live, in the running browser.** uBlock Origin Lite 2026.914.1325
  was installed into Kylmora and pointed at a local server offering two files,
  one at a path uBOL's own rules name and one not. Result:
  `ads:BLOCKED app:200`.

| Measured against uBOL | |
| --- | --- |
| Rulesets declared / on by default | 56 / 6 |
| Rules read | 18,509 |
| Rules emitted for WebKit | 120,991 |
| Refused as untranslatable | 203 (1.1%) |
| Redirects handled at navigation time | 862 |
| First compile / second launch | ~38 s / ~4 s |

Docs: `docs/declarative-net-request.md`.

---

## Known to be impossible on this engine

Worth writing down so nobody spends a week rediscovering it. Each was checked
against the real API, not inferred from documentation.

| Wanted | Why it cannot be done |
| --- | --- |
| Redirect or rewrite headers on a **subresource** | WebKit fetches images, scripts and XHR in its own process without asking the app. Only a man-in-the-middle proxy with its own root certificate in the trust store could see them -- which is not a thing to do to a privacy browser's traffic. Crest does emulate these. |
| Change a **response header** | Same reason, and the response has already been fetched. |
| **Alternation in a content rule** (`(a|b)`) | WebKit's matcher refuses it in every shape -- nine were tried against the real compiler. This is why a `requestDomains` list becomes one rule per host, and why 18,509 rules become 120,991. |
| A service worker's **`notificationclick`** | The shim lives in the page; a worker's script cannot be reached from there. |
| **Push API** | Not available to an embedded `WKWebView` at all. |

---

## What is left, in the order worth doing it

### Next

1. **Passkeys / WebAuthn** — increasingly a hard blocker on sign-in pages, and
   the largest remaining *functional* gap. **Establish feasibility first:**
   whether a `WKWebView` can do WebAuthn at all without private API is not yet
   known. This could turn out to be impossible rather than merely undone, and
   that answer is worth a day on its own before any building.
2. **Media Session + system Now Playing** — pages' track metadata and transport
   commands into Control Center and the media keys. Well bounded, demos well,
   and a natural neighbour of the notification work just finished.
3. **Developer toolbar with viewport presets** — responsive preview, capture,
   inspector toggles. Cheap next to the rest and shows well.

### After that

4. **`chrome.debugger`** — a real Chrome DevTools Protocol implementation.
   Large. Crest has 19 files of it. Only worth it if extensions our users
   actually want depend on it.
5. **Per-Space retention** for history, archive and downloads; **Archive
   filterable by reason**; **app icon palette**; **Look-and-Feel presets with
   live preview**. Polish, each small.
6. **Server-trust overrides** and **download risk assessment** — small, and both
   are gaps where we already do most of the work.
7. **Multiple windows onto one workspace**, **tab tear-off**, **blank /
   disposable window**, **Quick Window** — all downstream of a one-window
   design decision. A deliberate architectural choice to revisit, not a feature
   to add.
8. **iOS / iPadOS** — the biggest gap and the biggest project. A separate
   decision, not a feature.

### Where we are ahead, and should stay

Automations, Boosts, the screenshot editor, our own PDF viewer, encrypted-DNS
profiles, proxies, anti-fingerprinting, 29 per-site settings, live folders, the
tab overview with a task manager, enterprise policies and MDM, the `kylmora://`
scheme and CLI, mouse and rocker gestures, vim keys and link hints -- and a
5 MB dependency-free bundle that runs on macOS 14, where Crest requires 26.1.

---

## Housekeeping

- **CI** was split into three parallel jobs behind one required check
  (`c2cabcb`), taking the wall clock from ~11 min to ~7 min. The `Tests` job is
  still ~5 min and is mostly compile; caching `.build` is the next win.
- **Two extensions are installed in the developer's browser from testing:**
  "Side Panel Probe" and uBlock Origin Lite. Remove whenever.
- The `declarativeNetRequest` first compile takes ~38 s. It is cached by a
  fingerprint of its input, so it is paid once -- but it is worth knowing about
  before shipping, and worth revisiting if it bothers anyone.
- Test suite: 1,840 tests in 289 suites.
