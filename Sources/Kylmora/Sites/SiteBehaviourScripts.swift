import WebKit

/// The scripts behind the per-site settings WebKit cannot switch itself.
///
/// Each reads `window.__kylmoraSite` at the moment it matters and does nothing
/// when the value is the permissive default, so a page on a site with every
/// setting at its default sees no difference from these being here.
enum SiteBehaviourScripts {
    static var all: [WKUserScript] {
        [
            WKUserScript(source: autoplay, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: notifications, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: geolocation, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: screenSharing, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: pictureInPicture, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: pictureInPictureWatcher, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: autoplaySweep, injectionTime: .atDocumentEnd, forMainFrameOnly: false),
            WKUserScript(source: reader, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ]
    }

    private static let policy = "((window.__kylmoraSite || {})"

    /// `play()` without a user gesture is refused according to the setting.
    static let autoplay = """
    (function () {
      var original = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        var setting = \(policy).autoPlay || "allow");
        var active = !!(navigator.userActivation && navigator.userActivation.hasBeenActive);
        if (!active && setting !== "allow") {
          if (setting === "never" || (!this.muted && this.volume > 0)) {
            return Promise.reject(new DOMException("Auto-play is blocked by a website setting.", "NotAllowedError"));
          }
        }
        return original.apply(this, arguments);
      };
    })();
    """

    /// Media the page marks `autoplay` never goes through `play()`, so it is
    /// paused as it appears.
    static let autoplaySweep = """
    (function () {
      function sweep(root) {
        var setting = \(policy).autoPlay || "allow");
        if (setting === "allow") { return; }
        if (navigator.userActivation && navigator.userActivation.hasBeenActive) { return; }
        var media = root.querySelectorAll ? root.querySelectorAll("video[autoplay],audio[autoplay]") : [];
        media.forEach(function (m) {
          if (setting === "never" || (!m.muted && m.volume > 0)) { m.autoplay = false; m.pause(); }
        });
      }
      sweep(document);
      new MutationObserver(function (records) {
        records.forEach(function (r) { r.addedNodes.forEach(function (n) { if (n.nodeType === 1) { sweep(n); } }); });
      }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    /// The Notification API, answered by Kylmora and the system's centre.
    static let notifications = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraSite;
      if (!bridge) { return; }
      var state = "default";
      function KylmoraNotification(title, options) {
        options = options || {};
        this.title = title; this.body = options.body || ""; this.tag = options.tag || ""; this.data = options.data;
        this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
        var self = this;
        if (KylmoraNotification.permission !== "granted") {
          setTimeout(function () { if (self.onerror) { self.onerror(new Event("error")); } }, 0);
          return;
        }
        bridge.postMessage({ kind: "notification", title: String(title), body: String(this.body) }).then(function () {
          if (self.onshow) { self.onshow(new Event("show")); }
        }, function () { if (self.onerror) { self.onerror(new Event("error")); } });
      }
      KylmoraNotification.prototype.close = function () { if (this.onclose) { this.onclose(new Event("close")); } };
      KylmoraNotification.prototype.addEventListener = function () {};
      KylmoraNotification.prototype.removeEventListener = function () {};
      KylmoraNotification.requestPermission = function (callback) {
        var setting = \(policy).notifications || "ask");
        var result = setting === "deny" ? Promise.resolve("denied") : bridge.postMessage({ kind: "askNotification" });
        return result.then(function (answer) {
          state = answer === "granted" ? "granted" : "denied";
          if (callback) { callback(state); }
          return state;
        });
      };
      Object.defineProperty(KylmoraNotification, "permission", {
        get: function () {
          var setting = \(policy).notifications || "ask");
          if (setting === "deny") { return "denied"; }
          if (setting === "allow") { return "granted"; }
          return state;
        }
      });
      KylmoraNotification.maxActions = 0;
      window.Notification = KylmoraNotification;
    })();
    """

    /// The Geolocation API, answered by Core Location through Kylmora.
    static let geolocation = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraSite;
      if (!bridge || !navigator.geolocation) { return; }
      var nextWatch = 1;
      function denied() { return { code: 1, message: "Location access is blocked by a website setting.", PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }; }
      function unavailable(message) { return { code: 2, message: message || "Location is unavailable.", PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }; }
      function fetch(success, error) {
        var setting = \(policy).location || "ask");
        if (setting === "deny") { if (error) { setTimeout(function () { error(denied()); }, 0); } return; }
        bridge.postMessage({ kind: "geolocation" }).then(function (reply) {
          if (!reply || reply.error) {
            if (error) { error(reply && reply.error === "denied" ? denied() : unavailable(reply && reply.message)); }
            return;
          }
          success({
            coords: { latitude: reply.latitude, longitude: reply.longitude, accuracy: reply.accuracy,
                      altitude: null, altitudeAccuracy: null, heading: null, speed: null },
            timestamp: reply.timestamp
          });
        }, function (e) { if (error) { error(unavailable(String(e))); } });
      }
      navigator.geolocation.getCurrentPosition = function (success, error) { fetch(success, error); };
      navigator.geolocation.watchPosition = function (success, error) { fetch(success, error); return nextWatch++; };
      navigator.geolocation.clearWatch = function () {};
    })();
    """

    /// Screen capture refused where the site says so. WebKit itself asks
    /// nothing for it in an embedded web view, so deny is the one setting
    /// that changes anything.
    static let screenSharing = """
    (function () {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) { return; }
      var original = navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getDisplayMedia = function () {
        if (\(policy).screenSharing || "ask") === "deny") {
          return Promise.reject(new DOMException("Screen sharing is blocked by a website setting.", "NotAllowedError"));
        }
        return original.apply(this, arguments);
      };
    })();
    """

    static let pictureInPicture = """
    (function () {
      function denied() { return \(policy).pictureInPicture || "allow") === "deny"; }
      if (HTMLVideoElement.prototype.requestPictureInPicture) {
        var original = HTMLVideoElement.prototype.requestPictureInPicture;
        HTMLVideoElement.prototype.requestPictureInPicture = function () {
          if (denied()) { return Promise.reject(new DOMException("Picture in picture is blocked by a website setting.", "NotAllowedError")); }
          return original.apply(this, arguments);
        };
      }
      if (HTMLVideoElement.prototype.webkitSetPresentationMode) {
        var setMode = HTMLVideoElement.prototype.webkitSetPresentationMode;
        HTMLVideoElement.prototype.webkitSetPresentationMode = function (mode) {
          if (denied() && mode === "picture-in-picture") { return; }
          return setMode.apply(this, arguments);
        };
      }
      var descriptor = Object.getOwnPropertyDescriptor(Document.prototype, "pictureInPictureEnabled");
      if (descriptor && descriptor.get) {
        Object.defineProperty(Document.prototype, "pictureInPictureEnabled", {
          get: function () { return denied() ? false : descriptor.get.call(this); }
        });
      }
    })();
    """

    /// Tells Kylmora when a video enters or leaves picture in picture, so
    /// closing its tab can be confirmed.
    static let pictureInPictureWatcher = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraSite;
      if (!bridge) { return; }
      document.addEventListener("webkitpresentationmodechanged", function (event) {
        var target = event.target;
        if (!target || typeof target.webkitPresentationMode === "undefined") { return; }
        bridge.postMessage({ kind: "pictureInPicture", active: target.webkitPresentationMode === "picture-in-picture" });
      }, true);
    })();
    """

    /// Reader mode: the article, on its own.
    ///
    /// The article is the element holding the most paragraph text, found by
    /// scoring every element by the text in its own paragraphs and walking up
    /// while the parent still holds most of the page's paragraph text. A page
    /// with too little paragraph text is not an article and is left alone.
    static let reader = """
    (function () {
      if (\(policy).readerMode || "off") !== "on") { return; }
      if (document.querySelector(".kylmora-reader")) { return; }
      var paragraphs = Array.prototype.slice.call(document.querySelectorAll("p"));
      var textOf = function (el) { return (el.innerText || el.textContent || "").trim(); };
      var scores = new Map();
      var total = 0;
      paragraphs.forEach(function (p) {
        var length = textOf(p).length;
        if (length < 40) { return; }
        total += length;
        var parent = p.parentElement;
        if (parent) { scores.set(parent, (scores.get(parent) || 0) + length); }
      });
      if (total < 800) { return; }
      var best = null, bestScore = 0;
      scores.forEach(function (score, el) { if (score > bestScore) { best = el; bestScore = score; } });
      if (!best) { return; }
      var container = best;
      while (container.parentElement && container.parentElement !== document.body) {
        var parent = container.parentElement;
        var parentText = 0;
        paragraphs.forEach(function (p) { if (parent.contains(p)) { parentText += textOf(p).length; } });
        if (parentText < total * 0.6) { break; }
        container = parent;
      }
      var clone = container.cloneNode(true);
      clone.querySelectorAll("script,style,nav,aside,footer,header,iframe,form,button,input,select,textarea,noscript,svg,[role=navigation],[role=banner],[role=complementary],[aria-hidden=true]").forEach(function (n) { n.remove(); });
      clone.querySelectorAll("*").forEach(function (n) {
        Array.prototype.slice.call(n.attributes).forEach(function (a) {
          if (!/^(href|src|alt|title|colspan|rowspan)$/i.test(a.name)) { n.removeAttribute(a.name); }
        });
      });
      var heading = document.querySelector("h1");
      var title = (heading && textOf(heading)) || document.title || "";
      var esc = function (s) { return s.replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); };
      var byline = document.querySelector("[rel=author],.byline,.author,[itemprop=author]");
      document.documentElement.innerHTML =
        '<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="color-scheme" content="light dark"><title>' + esc(title) + "</title><style>" +
        "body{margin:0;background:#fbf8f2;color:#1f1f1f;font:19px/1.65 -apple-system,Georgia,serif}" +
        ".kylmora-reader{max-width:680px;margin:0 auto;padding:56px 24px 96px}" +
        "h1{font-size:34px;line-height:1.2;margin:0 0 12px}.kylmora-byline{color:#6b6b6b;font-size:15px;margin-bottom:32px}" +
        "img,video{max-width:100%;height:auto}pre{white-space:pre-wrap;font-size:15px}a{color:#0b63c4}" +
        "@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#e8e8e8}a{color:#7fb3ff}.kylmora-byline{color:#a0a0a5}}" +
        '</style></head><body><article class="kylmora-reader"><h1>' + esc(title) + "</h1>" +
        (byline ? '<div class="kylmora-byline">' + esc(textOf(byline)) + "</div>" : "") +
        clone.innerHTML + "</article></body>";
    })();
    """
}
