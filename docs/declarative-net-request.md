# `chrome.declarativeNetRequest`

An MV3 content blocker ships its filter list as `declarativeNetRequest` rules.
WebKit's extension engine does not implement the API at all, so on a plain
`WKWebExtensionController` such a blocker installs cleanly, reports no error,
shows a healthy toolbar icon -- and blocks nothing.

Kylmora reads the rules itself, translates them into a `WKContentRuleList` and
gives that to the web views of the Spaces where the extension is enabled. The
matching then happens inside WebKit's own matcher, at the same cost as
Kylmora's own filter lists, which is to say a cost you cannot measure.

## What works

- **Static rulesets** from the manifest's `declarative_net_request.rule_resources`,
  honouring each one's `enabled` default. This is how almost every blocker
  ships its list.
- **Rules added at runtime**: `updateDynamicRules` (kept across launches) and
  `updateSessionRules` (not), with `getDynamicRules` / `getSessionRules`.
- **`updateEnabledRulesets` / `getEnabledRulesets`**, remembered per extension.
- `getAvailableStaticRuleCount`, `isRegexSupported`, `getMatchedRules`,
  `setExtensionActionOptions`.
- Actions: `block`, `allow`, `allowAllRequests`, `upgradeScheme` everywhere;
  `redirect` and `modifyHeaders` for pages and frames (see below).
- Conditions: `urlFilter`, `regexFilter`, `isUrlFilterCaseSensitive`,
  `initiatorDomains` / `excludedInitiatorDomains` (and the older `domains` /
  `excludedDomains` spelling), `requestDomains`, `resourceTypes` /
  `excludedResourceTypes`, `domainType`.

## How priority survives the translation

Chrome evaluates every rule and the highest priority wins; at equal priority an
`allow` beats a `block`. WebKit has no priorities at all -- it runs the list in
order and the last `ignore-previous-rules` to match wins.

So the list is emitted **lowest priority first, blocks before allows**, which
makes WebKit's "last one wins" produce Chrome's answer. This is the single
thing most likely to be wrong in a translation like this, so it is the thing
the tests pin hardest.

## Redirects and header rules

WebKit's content matcher can block and it can upgrade a scheme. It cannot send
a request somewhere else and it cannot touch a header. Those two are applied at
navigation time instead, where Kylmora may cancel a load and re-issue it:

- **`redirect` works for a page or a frame**, in all four spellings Chrome
  allows -- `url`, `extensionPath`, `transform` (including `queryTransform`)
  and `regexSubstitution` with capture groups.
- **`modifyHeaders` rewrites request headers** on a page or frame load, for
  requests with no body. Re-issuing a POST would lose the body, so a POST is
  left alone.
- **Neither works for a subresource.** An image, a script or an XHR is fetched
  by WebKit out of process and Kylmora never sees it. Nothing short of running
  a man-in-the-middle proxy with its own root certificate could change that,
  which is not a thing this browser is going to do to your traffic.
- **Response headers cannot be changed at all**, by anything here. A rule that
  only rewrites response headers is refused with that as its reason.

A redirect onto the address it is already at is ignored, and anything just
redirected to is left alone for three seconds, so two rules pointing at each
other settle instead of looping.

## What cannot be translated, and is said out loud

A blocker that half works without telling you is worse than one that says what
this browser could not take. Every rule that does not survive is kept with a
reason against its own rule id.

| Not translated | Why |
| --- | --- |
| `requestMethods` / `excludedRequestMethods` | The matcher cannot match on the method |
| `tabIds` / `excludedTabIds` | It has no notion of a tab |
| `excludedRequestDomains` | It can require a requested host but not exclude one |
| A condition with both `urlFilter` and `requestDomains` | The two cannot be combined without alternation |
| `regexFilter` using lookaround, backreferences or lazy quantifiers | Its regular expressions are a restricted dialect |
| Response-header-only `modifyHeaders` | Nothing can change a response header here |

`getMatchedRules` returns an empty list and `setExtensionActionOptions` does
nothing, for the same reason: the matching happens inside WebKit, which does
not report what it matched. An empty answer is the honest one.

## Some things that are not obvious

- **A rule naming no `resourceTypes` never blocks the top-level document.**
  That is Chrome's behaviour, and a translation that got it wrong would be a
  browser that refuses to load websites.
- **`main_frame` and `sub_frame` are both "document" to WebKit**, told apart by
  load context. A sub-frame rule that took the top frame with it would do the
  same damage.
- **WebKit's matcher has no alternation whatsoever.** Not `(a|b)`, not
  anchored, not inside a group -- every shape was tried against the real
  compiler and every one was refused. So a list of `requestDomains` becomes one
  rule per host, which is why a blocker's 18,000 rules can become six figures
  here, and why the ceiling is counted in emitted rules rather than in rules as
  the extension wrote them.
- **Rules are per Space**, because extensions are: a Space the extension is
  switched off in gets none of its rules.
- Changes take effect on a page's next load, which is how every content rule
  list on this engine works, Safari's included.

## How the API reaches the extension

The same way side panels do. WebKit starts an extension's background worker and
owns its world, so nothing can be added to it afterwards -- the namespace is put
into Kylmora's own copy of the package before the engine loads it, and calls
come back through a reserved name (`com.kylmora.netrequest`) that Kylmora
answers in process. No program is started and nothing is installed on the Mac.

An extension that asks for neither this nor a side panel is left byte for byte
as it arrived.

## Measured against a real blocker

uBlock Origin Lite 2026.914.1325, its own package, unchanged:

| | |
| --- | --- |
| Rulesets declared / on by default | 56 / 6 |
| Rules read | 18,509 |
| Rules emitted for WebKit | 120,991 |
| Refused as untranslatable | 203 (1.1%) |
| Redirects applied at navigation time | 862 |
| Refused response-header rules | 52 |
| First compile / second launch | ~38 s / ~4 s |

The first compile is slow and is paid once: the compiled list is keyed by a
fingerprint of what went into it, so a launch where nothing changed reuses what
WebKit already holds.

It was then checked in the browser rather than only in a test. With uBOL
installed and a local server offering two files -- one at a path uBOL's own
rules name, one not -- the page's two fetches reported `ads:BLOCKED app:200`.
