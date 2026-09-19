# Web notifications

A page that calls `new Notification(...)` -- or, far more often now,
`registration.showNotification(...)` -- gets a real notification in macOS
Notification Centre, and clicking it comes back to the tab that sent it.

WebKit defines both APIs in a `WKWebView` and attaches neither to anything:
there is no notification provider behind them, so the built-in versions refuse.
Kylmora replaces them the same way it replaces the other per-site APIs WebKit
cannot switch, through a script in the page and a message handler in the app.

## What a page gets

| | |
| --- | --- |
| `new Notification(title, options)` | Shown by the system, with the site's host as the subtitle |
| `Notification.permission` | `granted` / `denied` / `default`, from the site's own setting |
| `Notification.requestPermission()` | Promise and callback forms; the answer is remembered |
| `notification.close()` | Takes it off the screen, not only fires the event |
| `click`, `close`, `show`, `error` | Real events, on a real `EventTarget`: `addEventListener` and the `on*` properties both work |
| `tag` | A second notification with the same tag replaces the first rather than stacking |
| `body`, `icon`, `lang`, `dir`, `silent`, `requireInteraction`, `renotify`, `timestamp`, `data` | Carried through |
| `registration.showNotification(...)` | The service worker spelling, down the same path |
| `registration.getNotifications({tag})` | What this origin still has on screen |

## The click

This is the part that makes the feature worth having. A notification the person
cannot click back to its page is a dead end, so every one Kylmora posts carries
its identifier in `userInfo`. A click looks that identifier up, brings Kylmora
to the front, switches to the Space the tab is in, selects the tab, and runs the
page's own `click` handler. A dismissal fires `close` and does not drag the tab
forward -- dismissing is not a request to go there.

## Permission

The Websites pane's **Notifications** setting is the authority.

- **Deny** -- `Notification.permission` is `denied`, `requestPermission()`
  answers `denied` without a system prompt, and nothing reaches the system.
- **Allow** -- `permission` is `granted` and no prompt is raised again.
- **Ask** -- the first `requestPermission()` raises the macOS prompt for
  Kylmora, and the answer is written back to the site's setting. Without
  writing it back a granted site would find `permission` at `default` on its
  next load and ask again on every visit.

macOS's own permission for Kylmora sits above all of this: if notifications are
off for the app in System Settings, nothing is shown whatever a site is set to.

## Limits worth knowing

- **Notifications appear while Kylmora is frontmost.** macOS suppresses banners
  for the active application unless the app asks for them; Kylmora asks. This is
  not a detail -- a browser is frontmost most of the time it is notifying.
- **A service worker's own `notificationclick` handler does not run.** The shim
  lives in the page, and a worker's script is out of reach from there. The click
  still brings the tab to the front, which is what almost every such handler
  does, but a handler that routes to a specific URL will not.
- **Push is not implemented**, so a site can only notify while one of its pages
  is open. Nothing arrives when the tab is closed.
- **No actions.** `maxActions` is 0 and `options.actions` is ignored.
- **Icons** are fetched over http(s) only, capped at 2 MB, and dropped if they
  fail; `data:` and `blob:` icons are not attached.
- **A site is capped at 24 on screen at once**, oldest evicted first, and only
  its own: a page in a loop must not fill the notification centre or push a
  quieter site's notifications off it.
- **Closing a tab withdraws its notifications**, because the page that would
  have answered a click has gone. A service worker's are left alone.
- A site can only close its own: `close()` is checked against the origin rather
  than trusting the identifier.
