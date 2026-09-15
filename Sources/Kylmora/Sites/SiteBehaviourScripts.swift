import WebKit

/// The scripts behind the per-site settings WebKit cannot switch itself.
///
/// Each reads `window.__kylmoraSite` at the moment it matters and does nothing
/// when the value is the permissive default, so a page on a site with every
/// setting at its default sees no difference from these being here.
enum SiteBehaviourScripts {
    /// The scripts that run at document start in every frame, as one
    /// script: each is a self-contained function, and WebKit evaluates one
    /// user script far more cheaply than eleven. A page with many iframes
    /// used to pay for all eleven in each of them.
    ///
    /// Each part keeps the isolation it had as a script of its own: an
    /// exception in one must not stop the ones after it, so every part runs
    /// inside its own try.
    static let documentStart: String = [
        autoplay, notifications, geolocation, screenSharing, pictureInPicture, pictureInPictureWatcher,
        mediaWatcher, nativeVideoPlayer, antiFingerprinting, hostileBehaviourBlocker, clipboardRead
    ].map { "try {\n\($0)\n} catch (e) {}" }.joined(separator: "\n")

    static var all: [WKUserScript] {
        [
            WKUserScript(source: documentStart, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: referrer, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: autoplaySweep, injectionTime: .atDocumentEnd, forMainFrameOnly: false),
            WKUserScript(source: reader, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ]
    }

    private static let policy = "((window.__kylmoraSite || {})"

    /// Reading the clipboard refused where the site says so: the async
    /// clipboard API rejects, and the paste event carries no data.
    static let clipboardRead = """
    (function () {
      var setting = \(policy).clipboardRead || "allow");
      if (setting !== "deny" || !navigator.clipboard) { return; }
      var refused = function () { return Promise.reject(new DOMException("Reading the clipboard is blocked by a website setting.", "NotAllowedError")); };
      try {
        Object.defineProperty(navigator.clipboard, "readText", { value: refused, configurable: true });
        Object.defineProperty(navigator.clipboard, "read", { value: refused, configurable: true });
      } catch (e) {}
      document.addEventListener("paste", function (event) {
        if (event.target && (event.target.isContentEditable || /^(input|textarea)$/i.test(event.target.tagName))) { return; }
        event.stopImmediatePropagation();
      }, true);
    })();
    """

    /// No referrer leaves the page where the site says so: a meta referrer
    /// policy is set before anything the page loads can carry one.
    static let referrer = """
    (function () {
      var setting = \(policy).referrer || "default");
      if (setting !== "none") { return; }
      var meta = document.createElement("meta");
      meta.name = "referrer";
      meta.content = "no-referrer";
      var head = document.head || document.documentElement;
      if (head) { head.insertBefore(meta, head.firstChild); }
    })();
    """

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

    /// Monitors HTML audio/video playback and MediaSession metadata, and provides
    /// controls for muting, play/pause and requesting Picture-in-Picture.
    static let mediaWatcher = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraSite;
      if (!bridge) { return; }

      var isMuted = false;
      var activeMedia = new Set();

      function getTitle() {
        try {
          if (navigator.mediaSession && navigator.mediaSession.metadata && navigator.mediaSession.metadata.title) {
            return navigator.mediaSession.metadata.title;
          }
        } catch (e) {}
        return document.title || "";
      }

      function getArtist() {
        try {
          if (navigator.mediaSession && navigator.mediaSession.metadata && navigator.mediaSession.metadata.artist) {
            return navigator.mediaSession.metadata.artist;
          }
        } catch (e) {}
        return "";
      }

      function report() {
        var isPlaying = false;
        var hasAudio = false;
        var hasVideo = false;

        activeMedia.forEach(function (el) {
          if (!el.paused && !el.ended) {
            isPlaying = true;
            if (el.tagName === "VIDEO") {
              hasVideo = true;
            }
            if (!el.muted && el.volume > 0) {
              hasAudio = true;
            }
          }
        });

        bridge.postMessage({
          kind: "mediaPlayback",
          isPlaying: isPlaying,
          hasAudio: hasAudio,
          hasVideo: hasVideo,
          isMuted: isMuted,
          title: getTitle(),
          artist: getArtist()
        });
      }

      function attach(el) {
        if (!el || el.__kylmoraTracked) { return; }
        el.__kylmoraTracked = true;
        if (isMuted) { el.muted = true; }

        var events = ["play", "playing", "pause", "ended", "emptied", "volumechange", "ratechange"];
        for (var i = 0; i < events.length; i++) {
          el.addEventListener(events[i], function () {
            if (!el.paused && !el.ended) {
              activeMedia.add(el);
            } else {
              activeMedia.delete(el);
            }
            report();
          }, true);
        }
      }

      function scan() {
        var elements = document.querySelectorAll("audio, video");
        for (var i = 0; i < elements.length; i++) {
          attach(elements[i]);
        }
      }

      scan();
      document.addEventListener("DOMContentLoaded", scan);
      if (document.documentElement) {
        var observer = new MutationObserver(function () { scan(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      }

      window.__kylmoraMedia = {
        setMuted: function (muted) {
          isMuted = !!muted;
          var elements = document.querySelectorAll("audio, video");
          for (var i = 0; i < elements.length; i++) {
            elements[i].muted = isMuted;
          }
          report();
        },
        togglePlayPause: function () {
          var anyPlaying = false;
          var elements = document.querySelectorAll("audio, video");
          for (var i = 0; i < elements.length; i++) {
            if (!elements[i].paused && !elements[i].ended) {
              anyPlaying = true;
              elements[i].pause();
            }
          }
          if (!anyPlaying && elements.length > 0) {
            elements[0].play().catch(function () {});
          }
          report();
        },
        requestPiP: function () {
          var video = document.querySelector("video");
          if (!video) { return false; }
          if (video.requestPictureInPicture) {
            video.requestPictureInPicture().catch(function () {});
            return true;
          } else if (video.webkitSetPresentationMode) {
            var next = video.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture";
            video.webkitSetPresentationMode(next);
            return true;
          }
          return false;
        }
      };
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

    /// Native HTML5 video player option (Vinegar-like: PiP, background playback, no tracking).
    ///
    /// Replaces custom video player UI (such as YouTube's custom DOM player)
    /// with clean native HTML5 controls, enables Picture-in-Picture directly,
    /// allows seamless background audio/video playback without being paused
    /// by the Page Visibility API, and skips/bypasses ads and tracking.
    static let nativeVideoPlayer = """
    (function () {
      var setting = \(policy).nativeVideoPlayer || "on");
      if (setting === "off") { return; }

      // 1. Background Playback & Visibility API Spoofing
      // YouTube and other video sites listen to visibilitychange and document.hidden
      // to forcefully pause playback when switching tabs. We preserve background playback.
      try {
        Object.defineProperty(document, "hidden", { get: function () { return false; }, configurable: true });
        Object.defineProperty(document, "visibilityState", { get: function () { return "visible"; }, configurable: true });
        Object.defineProperty(document, "webkitVisibilityState", { get: function () { return "visible"; }, configurable: true });
      } catch (e) {}

      window.addEventListener("visibilitychange", function (e) {
        if (\(policy).nativeVideoPlayer || "on") !== "off") {
          e.stopImmediatePropagation();
        }
      }, true);

      document.addEventListener("visibilitychange", function (e) {
        if (\(policy).nativeVideoPlayer || "on") !== "off") {
          e.stopImmediatePropagation();
        }
      }, true);

      // Protect against blur-induced pauses on window
      window.addEventListener("blur", function (e) {
        if (\(policy).nativeVideoPlayer || "on") !== "off") {
          e.stopImmediatePropagation();
        }
      }, true);

      // 2. Native Controls Enforcement & Ad-Bypass for YouTube & HTML5 video
      function enhanceVideoElement(video) {
        if (!video || video.__kylmoraNativeVideo) { return; }
        video.__kylmoraNativeVideo = true;

        // Force native controls & PiP
        video.controls = true;
        video.disablePictureInPicture = false;
        if (typeof video.webkitAllowsInlineMediaPlayback !== "undefined") {
          video.webkitAllowsInlineMediaPlayback = true;
        }

        // Prevent page scripts from removing controls attribute
        var origSetAttribute = video.setAttribute;
        video.setAttribute = function (name, val) {
          if (name === "controls" && \(policy).nativeVideoPlayer || "on") !== "off") {
            return;
          }
          return origSetAttribute.apply(this, arguments);
        };

        var origRemoveAttribute = video.removeAttribute;
        video.removeAttribute = function (name) {
          if (name === "controls" && \(policy).nativeVideoPlayer || "on") !== "off") {
            return;
          }
          return origRemoveAttribute.apply(this, arguments);
        };
      }

      function cleanYouTubeOverlays() {
        if (!location.hostname.includes("youtube.com") && !location.hostname.includes("youtu.be")) {
          return;
        }

        // Auto-skip video ads immediately
        var skipBtn = document.querySelector(".ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-overlay-close-button");
        if (skipBtn) {
          try { skipBtn.click(); } catch (e) {}
        }

        // Skip unskippable or ad video segment to the end
        var adShowing = document.querySelector(".ad-showing video, .ad-interrupting video");
        if (adShowing && !isNaN(adShowing.duration) && isFinite(adShowing.duration) && adShowing.currentTime < adShowing.duration) {
          try { adShowing.currentTime = adShowing.duration; } catch (e) {}
        }

        // Apply style to hide YouTube player overlay and expose native controls
        if (!document.getElementById("kylmora-native-video-style")) {
          var style = document.createElement("style");
          style.id = "kylmora-native-video-style";
          style.textContent = `
            .ytp-chrome-bottom, .ytp-gradient-bottom, .ytp-chrome-top, .ytp-gradient-top,
            .ytp-pause-overlay, .ytp-ad-module, .ytp-ad-player-overlay, .video-ads,
            .ytp-ce-element, .annotation, .ytp-share-panel, .ytp-contextmenu {
              display: none !important;
              pointer-events: none !important;
            }
            .html5-video-player video {
              pointer-events: auto !important;
              z-index: 20 !important;
            }
            .html5-video-player {
              background: #000 !important;
            }
          `;
          (document.head || document.documentElement).appendChild(style);
        }
      }

      function sweepVideos() {
        var videos = document.querySelectorAll("video");
        for (var i = 0; i < videos.length; i++) {
          enhanceVideoElement(videos[i]);
        }
        cleanYouTubeOverlays();
      }

      sweepVideos();
      document.addEventListener("DOMContentLoaded", sweepVideos);
      if (document.documentElement) {
        var observer = new MutationObserver(function () { sweepVideos(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      }
      setInterval(cleanYouTubeOverlays, 600);
    })();
    """

    /// Randomizes Canvas / WebGL read-backs with per-space seed, masks AudioContext signatures,
    /// and standardizes hardware parameters to defeat browser fingerprinting.
    static let antiFingerprinting = """
    (function () {
      var site = window.__kylmoraSite || {};
      if (site.antiFingerprinting === "off") { return; }

      var seed = typeof site.spaceSeed === 'number' ? site.spaceSeed : 42069;
      var allowCanvasNoise = site.canvasNoise !== false;
      var allowAudioNoise = site.audioNoise !== false;
      var allowHardwareMasking = site.hardwareMasking !== false;

      // Deterministic PRNG per Space
      function makeRNG(s) {
        return function () {
          var t = s += 0x6D2B79F5;
          t = Math.imul(t ^ (t >>> 15), t | 1);
          t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
          return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
      }
      var rng = makeRNG(seed);

      // 1. Canvas 2D Read-back Noise Farbling
      if (allowCanvasNoise && window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype.getImageData) {
        var origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
        CanvasRenderingContext2D.prototype.getImageData = function () {
          var imageData = origGetImageData.apply(this, arguments);
          var data = imageData.data;
          var len = data.length;
          if (len > 0) {
            var step = Math.max(16, (len / 120) | 0);
            for (var i = 0; i < len; i += step) {
              if (data[i + 3] > 10) {
                var delta = (rng() > 0.5 ? 1 : -1);
                var ch = i % 3;
                data[i + ch] = Math.min(255, Math.max(0, data[i + ch] + delta));
              }
            }
          }
          return imageData;
        };
      }

      // Canvas toDataURL Noise Farbling
      if (allowCanvasNoise && window.HTMLCanvasElement && HTMLCanvasElement.prototype.toDataURL) {
        var origToDataURL = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function () {
          try {
            var ctx = this.getContext && this.getContext('2d');
            if (ctx && this.width > 0 && this.height > 0) {
              var img = ctx.getImageData(0, 0, Math.min(this.width, 8), Math.min(this.height, 8));
              if (img.data.length > 0) {
                img.data[0] = img.data[0] ^ (seed & 1);
                ctx.putImageData(img, 0, 0);
              }
            }
          } catch (e) {}
          return origToDataURL.apply(this, arguments);
        };
      }

      // 2. AudioContext & Web Audio Acoustic Jitter
      if (allowAudioNoise && window.AudioBuffer && AudioBuffer.prototype.getChannelData) {
        var origGetChannelData = AudioBuffer.prototype.getChannelData;
        AudioBuffer.prototype.getChannelData = function () {
          var channel = origGetChannelData.apply(this, arguments);
          if (channel && channel.length > 0) {
            var aRng = makeRNG(seed + channel.length);
            var step = Math.max(16, (channel.length / 60) | 0);
            for (var i = 0; i < channel.length; i += step) {
              channel[i] += (aRng() - 0.5) * 1e-7;
            }
          }
          return channel;
        };
      }

      if (allowAudioNoise && window.AnalyserNode && AnalyserNode.prototype.getFloatFrequencyData) {
        var origGetFloat = AnalyserNode.prototype.getFloatFrequencyData;
        AnalyserNode.prototype.getFloatFrequencyData = function (array) {
          origGetFloat.apply(this, arguments);
          if (array && array.length > 0) {
            for (var i = 0; i < array.length; i += 4) {
              array[i] += (rng() - 0.5) * 0.01;
            }
          }
        };
      }

      // 3. WebGL Unmasked Renderer & Vendor Masking
      function maskGL(proto) {
        if (!proto || !proto.getParameter) return;
        var origGetParam = proto.getParameter;
        proto.getParameter = function (param) {
          if (param === 0x9245) return "Apple Inc.";
          if (param === 0x9246) return "Apple GPU";
          return origGetParam.apply(this, arguments);
        };
      }
      if (window.WebGLRenderingContext) maskGL(WebGLRenderingContext.prototype);
      if (window.WebGL2RenderingContext) maskGL(WebGL2RenderingContext.prototype);

      // 4. Hardware Concurrency & Memory Standardization
      if (allowHardwareMasking) {
        try {
          Object.defineProperty(navigator, 'hardwareConcurrency', { get: function () { return 8; }, configurable: true });
          Object.defineProperty(navigator, 'deviceMemory', { get: function () { return 8; }, configurable: true });
        } catch (e) {}
      }

      // 5. Battery API Neutralization
      if (navigator.getBattery) {
        navigator.getBattery = function () {
          return Promise.resolve({
            charging: true,
            chargingTime: 0,
            dischargingTime: Infinity,
            level: 1.0,
            addEventListener: function () {},
            removeEventListener: function () {},
            dispatchEvent: function () { return false; }
          });
        };
      }

      // 6. Screen dimension normalization
      try {
        if (window.screen) {
          Object.defineProperty(screen, 'availWidth', { get: function () { return screen.width; }, configurable: true });
          Object.defineProperty(screen, 'availHeight', { get: function () { return screen.height; }, configurable: true });
        }
      } catch (e) {}
    })();
    """

    /// Blocks hostile page behaviour: forces text to remain selectable, prevents
    /// right-click and context menu hijacking, and shields against unsolicited clipboard snooping.
    static let hostileBehaviourBlocker = """
    (function () {
      var setting = \(policy).blockHostileBehaviour || "on");
      if (setting === "off") return;

      // 1. Force Selectable Text & Re-enable Copying
      function injectStyles() {
        try {
          if (document.getElementById('kylmora-anti-hostile-style')) return;
          var style = document.createElement('style');
          style.id = 'kylmora-anti-hostile-style';
          style.textContent = 'html, body, p, span, div, h1, h2, h3, h4, h5, h6, li, td, th, pre, code, blockquote, article, section, main, em, strong, b, i, a { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }';
          (document.head || document.documentElement).appendChild(style);
        } catch (e) {}
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', injectStyles);
      } else {
        injectStyles();
      }

      // 2. Prevent right-click trapping and preventDefault on contextmenu, selectstart, dragstart
      var origPreventDefault = Event.prototype.preventDefault;
      Event.prototype.preventDefault = function () {
        if (this.type === 'contextmenu' || this.type === 'selectstart' || this.type === 'dragstart') {
          var currentSetting = \(policy).blockHostileBehaviour || "on");
          if (currentSetting !== "off") {
            return;
          }
        }
        return origPreventDefault.apply(this, arguments);
      };

      // 3. Clear hostile event listeners and property traps in capture phase
      ['contextmenu', 'selectstart', 'dragstart', 'copy', 'cut'].forEach(function (evtName) {
        window.addEventListener(evtName, function (e) {
          var currentSetting = \(policy).blockHostileBehaviour || "on");
          if (currentSetting === "off") return;

          if (document['on' + evtName]) document['on' + evtName] = null;
          if (document.body && document.body['on' + evtName]) document.body['on' + evtName] = null;
          if (window['on' + evtName]) window['on' + evtName] = null;
        }, { capture: true, passive: true });
      });

      // 4. Protect clipboard access (no clipboard reading or writing without user gesture)
      if (navigator.clipboard) {
        if (navigator.clipboard.readText) {
          var origReadText = navigator.clipboard.readText;
          navigator.clipboard.readText = function () {
            var currentSetting = \(policy).blockHostileBehaviour || "on");
            if (currentSetting !== "off") {
              var hasUserActivation = !!(navigator.userActivation && navigator.userActivation.isActive);
              if (!hasUserActivation) {
                return Promise.reject(new DOMException("Clipboard access blocked by Kylmora hostile behaviour protection.", "NotAllowedError"));
              }
            }
            return origReadText.apply(this, arguments);
          };
        }

        if (navigator.clipboard.read) {
          var origRead = navigator.clipboard.read;
          navigator.clipboard.read = function () {
            var currentSetting = \(policy).blockHostileBehaviour || "on");
            if (currentSetting !== "off") {
              var hasUserActivation = !!(navigator.userActivation && navigator.userActivation.isActive);
              if (!hasUserActivation) {
                return Promise.reject(new DOMException("Clipboard access blocked by Kylmora hostile behaviour protection.", "NotAllowedError"));
              }
            }
            return origRead.apply(this, arguments);
          };
        }

        if (navigator.clipboard.writeText) {
          var origWriteText = navigator.clipboard.writeText;
          navigator.clipboard.writeText = function (data) {
            var currentSetting = \(policy).blockHostileBehaviour || "on");
            if (currentSetting !== "off") {
              var hasUserActivation = !!(navigator.userActivation && (navigator.userActivation.isActive || navigator.userActivation.hasBeenActive));
              if (!hasUserActivation) {
                return Promise.reject(new DOMException("Unsolicited clipboard write blocked by Kylmora hostile behaviour protection.", "NotAllowedError"));
              }
            }
            return origWriteText.apply(this, arguments);
          };
        }
      }

      // 5. Clean inline attributes on elements as they appear
      function scrubNode(node) {
        if (!node || node.nodeType !== 1) return;
        try {
          if (node.hasAttribute('oncontextmenu')) node.removeAttribute('oncontextmenu');
          if (node.hasAttribute('onselectstart')) node.removeAttribute('onselectstart');
          if (node.hasAttribute('oncopy')) node.removeAttribute('oncopy');
          if (node.hasAttribute('unselectable')) node.removeAttribute('unselectable');
          if (node.style && node.style.userSelect === 'none') node.style.userSelect = 'auto';
          if (node.style && node.style.webkitUserSelect === 'none') node.style.webkitUserSelect = 'auto';
        } catch (e) {}
      }

      var observer = new MutationObserver(function (mutations) {
        var currentSetting = \(policy).blockHostileBehaviour || "on");
        if (currentSetting === "off") return;
        for (var i = 0; i < mutations.length; i++) {
          var added = mutations[i].addedNodes;
          for (var j = 0; j < added.length; j++) {
            scrubNode(added[j]);
            if (added[j].querySelectorAll) {
              var subs = added[j].querySelectorAll('[oncontextmenu], [onselectstart], [oncopy], [unselectable]');
              for (var k = 0; k < subs.length; k++) scrubNode(subs[k]);
            }
          }
        }
      });

      if (document.documentElement) {
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } else {
        document.addEventListener('DOMContentLoaded', function () {
          if (document.documentElement) {
            observer.observe(document.documentElement, { childList: true, subtree: true });
          }
        });
      }
    })();
    """
}
