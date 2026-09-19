import Foundation

/// The JavaScript that makes `chrome.sidePanel` and `browser.sidebarAction`
/// exist.
///
/// WebKit's engine does not implement either, and an extension whose worker
/// calls `chrome.sidePanel.setPanelBehavior(...)` at the top of its first file
/// does not half-work without them -- it throws, the worker dies, and nothing
/// the extension does works at all. So the API is provided here, in the
/// extension's own contexts, and every call is carried to `SidebarBroker`,
/// which is the one place that decides what a call means.
///
/// Two ways in, because a background worker and a panel page have different
/// doors to the app:
///
/// - a worker has `runtime.connectNative`, which Kylmora answers itself
///   without starting any program, and
/// - a page Kylmora hosts has a script message handler, which replies
///   directly.
///
/// The half that talks to the app is the only difference between them.
enum ExtensionSidebarShim {
    /// The name Kylmora answers to on the native messaging channel. Reserved:
    /// a manifest on disk claiming this name is ignored.
    static let brokerHostName = "com.kylmora.sidepanel"
    /// The script message handler a hosted extension page posts to.
    static let messageHandlerName = "kylmoraSidebar"
    /// The file the shim is written to inside an extension's folder.
    static let workerFileName = "kylmora-sidepanel.js"
    /// The file that becomes the extension's service worker, importing the
    /// shim and then the extension's own.
    static let workerEntryFileName = "kylmora-sidepanel-worker.js"

    /// The shim for a background worker or script.
    static var worker: String {
        body(channel: """
            let port = null;
            let sequence = 0;
            const waiting = new Map();

            function connect() {
              if (port) return port;
              port = api.runtime.connectNative(HOST);
              port.onMessage.addListener(function (message) {
                const pending = waiting.get(message && message.id);
                if (!pending) return;
                waiting.delete(message.id);
                if (message.ok) pending.resolve(message.value);
                else pending.reject(new Error(message.error || 'The side panel call failed.'));
              });
              port.onDisconnect.addListener(function () {
                port = null;
                for (const pending of waiting.values()) {
                  pending.reject(new Error('Kylmora closed the side panel connection.'));
                }
                waiting.clear();
              });
              return port;
            }

            function send(method, args) {
              return new Promise(function (resolve, reject) {
                const id = ++sequence;
                waiting.set(id, { resolve: resolve, reject: reject });
                try {
                  connect().postMessage({ id: id, method: method, args: args });
                } catch (error) {
                  waiting.delete(id);
                  reject(error);
                }
              });
            }
            """, reportsTabs: true)
    }

    /// The shim for a page Kylmora hosts itself.
    static var page: String {
        body(channel: """
            function send(method, args) {
              const handler = window.webkit
                && window.webkit.messageHandlers
                && window.webkit.messageHandlers[HANDLER];
              if (!handler) return Promise.reject(new Error('This page is not hosted by Kylmora.'));
              return handler.postMessage({ method: method, args: args });
            }
            """, reportsTabs: false)
    }

    /// The shared half: the API surface itself.
    ///
    /// Both spellings are defined whichever the manifest asked for, because
    /// an extension ported between the two browsers often calls whichever it
    /// finds, and a `browser.sidebarAction` that exists on Chrome's side costs
    /// nothing.
    private static func body(channel: String, reportsTabs: Bool) -> String {
        """
        (function () {
          'use strict';
          const api = typeof browser !== 'undefined' ? browser
            : (typeof chrome !== 'undefined' ? chrome : undefined);
          if (!api) return;
          // If this engine ever grows the real thing, it wins.
          if (api.sidePanel && api.sidebarAction) return;
          const HOST = '\(brokerHostName)';
          const HANDLER = '\(messageHandlerName)';

        \(channel.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

          // Chrome's APIs take a callback and return a promise; Firefox's
          // return a promise. Supporting both is what lets one shim serve an
          // extension written for either.
          function method(name) {
            return function () {
              const args = Array.prototype.slice.call(arguments);
              let callback;
              if (typeof args[args.length - 1] === 'function') callback = args.pop();
              const options = (args[0] && typeof args[0] === 'object') ? args[0] : {};
              const promise = send(name, options);
              if (!callback) return promise;
              promise.then(function (value) { callback(value); }, function (error) {
                try { api.runtime.lastError = { message: String(error && error.message || error) }; } catch (ignored) {}
                callback(undefined);
              });
              return undefined;
            };
          }

          // A plain value in, a plain value out: `setTitle('x')` and
          // `setPanel(null)` are both legal in Firefox.
          function valueMethod(name, key) {
            return function (value, callback) {
              const options = (value && typeof value === 'object') ? value : {};
              if (!(value && typeof value === 'object')) options[key] = value === undefined ? null : value;
              return method(name)(options, callback);
            };
          }

          const sidePanel = {
            setOptions: method('sidePanel.setOptions'),
            getOptions: method('sidePanel.getOptions'),
            setPanelBehavior: method('sidePanel.setPanelBehavior'),
            getPanelBehavior: method('sidePanel.getPanelBehavior'),
            open: method('sidePanel.open'),
          };

          const sidebarAction = {
            setPanel: valueMethod('sidebarAction.setPanel', 'panel'),
            getPanel: method('sidebarAction.getPanel'),
            setTitle: valueMethod('sidebarAction.setTitle', 'title'),
            getTitle: method('sidebarAction.getTitle'),
            setIcon: method('sidebarAction.setIcon'),
            open: method('sidebarAction.open'),
            close: method('sidebarAction.close'),
            toggle: method('sidebarAction.toggle'),
            isOpen: method('sidebarAction.isOpen'),
          };

          function define(target, name, value) {
            if (!target || target[name]) return;
            try {
              Object.defineProperty(target, name, { value: value, enumerable: true, configurable: true, writable: true });
            } catch (error) {
              try { target[name] = value; } catch (ignored) {}
            }
          }

          for (const target of [typeof chrome !== 'undefined' ? chrome : undefined,
                                typeof browser !== 'undefined' ? browser : undefined]) {
            define(target, 'sidePanel', sidePanel);
            define(target, 'sidebarAction', sidebarAction);
          }
        \(reportsTabs ? tabReporting : "")
        }());
        """
    }

    /// Kylmora cannot see the numbers WebKit gives tabs, and per-tab panels
    /// are addressed by them. The extension can see them, so the worker says
    /// which tab is in front whenever that changes; without the `tabs`
    /// permission this does nothing and panels are simply not per-tab.
    private static let tabReporting = """

          try {
            if (api.tabs && api.tabs.onActivated) {
              api.tabs.onActivated.addListener(function (info) {
                send('kylmora.tabChanged', { tabId: info && info.tabId });
              });
            }
            if (api.tabs && api.tabs.onRemoved) {
              api.tabs.onRemoved.addListener(function (tabId) {
                send('kylmora.tabRemoved', { tabId: tabId });
              });
            }
            if (api.tabs && api.tabs.query) {
              const query = api.tabs.query({ active: true, currentWindow: true });
              if (query && query.then) {
                query.then(function (tabs) {
                  if (tabs && tabs[0]) send('kylmora.tabChanged', { tabId: tabs[0].id });
                }, function () {});
              }
            }
          } catch (ignored) {}
        """
}
