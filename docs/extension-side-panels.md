# Extension side panels

A growing number of extensions put their real interface in a panel beside the
page rather than in a popup that vanishes when you click away: a translator, a
notebook, a reading assistant, a chat. Chrome calls it `chrome.sidePanel`,
Firefox calls it `browser.sidebarAction`, and WebKit's extension engine — the
one Kylmora runs extensions on — has neither. An extension that wants a panel
gets an API that is not there, and in the worst case its background worker
throws on its first line and nothing about the extension works at all.

Kylmora provides the panel and the API.

## What an extension gets

| It calls | What happens |
| --- | --- |
| `chrome.sidePanel.setOptions({ path, enabled, tabId })` | Sets the page the panel shows, for every tab or for one. |
| `chrome.sidePanel.getOptions({ tabId })` | Answers with the page and whether it is switched on. |
| `chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick })` | Makes the extension's toolbar item open the panel instead of a popup. |
| `chrome.sidePanel.open({ tabId })` | Opens it. |
| `browser.sidebarAction.setPanel / getPanel` | The same thing in Firefox's spelling, where `null` means "no panel here". |
| `browser.sidebarAction.setTitle / getTitle` | The name on the panel's header. |
| `browser.sidebarAction.open / close / toggle / isOpen` | Opens, closes, flips, and reports. |
| `browser.sidebarAction.setIcon` | Accepted. The panel wears the extension's own icon, which is the one the rest of the browser shows for it. |

Both spellings are defined whichever one the manifest was written in, because
an extension ported from one browser to the other often calls whichever it
finds.

`side_panel.default_path` and `sidebar_action.default_panel` are both read from
the manifest, along with Firefox's `default_title` and `default_icon`.

## Where the panel appears

Docked beside the page, on the same side as Web Panels and sharing that strip:
opening one puts the other away, because they are the same piece of screen. The
header carries the extension's icon and name, a reload, and a close.

Clicking the extension's toolbar item opens the panel when the extension asked
for that with `setPanelBehavior`, or when it has a panel and no popup.

The panel follows the tab: an extension can set a different page per tab, and
changing tabs changes the page, or closes the panel if the extension has
switched it off for the tab you moved to.

## How it works, and the one invasive part

The panel itself is an ordinary extension page — the same
`chrome-extension://` origin as the popup and the options page — hosted in a
web view built from the configuration the engine hands out for that extension.
`chrome.storage`, `chrome.runtime` and the rest work in it as they do anywhere
else. Kylmora adds the side panel API to it with an injected script and answers
its calls through a message handler.

A background worker cannot be reached that way. WebKit starts it, WebKit owns
its world, and nothing the app does afterwards can add an API to it. So for an
extension that declares a side panel — and only for such an extension —
Kylmora writes one file into **its own copy** of the package and points the
manifest's background entry at it:

```js
importScripts('kylmora-sidepanel.js');   // the API this engine does not have
importScripts('worker.js');              // the extension's own code, unchanged
```

The extension's own files are not edited. The manifest gains the new entry
point, the `nativeMessaging` permission, and a `kylmora_side_panel` key
recording what was done, so a second pass does not wrap the wrapper. Nothing is
written for an extension that has no panel; its package is left byte for byte
as it arrived.

`nativeMessaging` is how the shim talks back: it opens a port to
`com.kylmora.sidepanel`, a name Kylmora reserves and answers inside the app. No
program is started, nothing reaches the disk or the network, and a manifest on
disk claiming that name is ignored. See
[native-messaging.md](native-messaging.md) for the channel itself.

## What is not there

- **A panel for an extension whose background code is an HTML page** rather
  than a worker or scripts gets the API in its panel but not in that page.
  Settings says so.
- **Panel icons** from `sidebar_action.default_icon` are read but the header
  shows the extension's own icon.
- **Per-tab panels need the `tabs` permission.** Kylmora cannot see the numbers
  WebKit gives tabs, so the extension reports which tab is in front; without
  that permission a panel is the same on every tab.
- **One panel at a time.** Chrome shows one, and so does this.
