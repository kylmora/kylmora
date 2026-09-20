import Foundation

/// The `chrome.declarativeNetRequest` an extension's own code sees.
///
/// WebKit's engine defines no such namespace, so an extension that adds rules
/// at runtime throws on its first line. The shim puts the namespace back and
/// sends each call to Kylmora, which is where the rules are actually
/// translated and compiled.
///
/// The way back is `sendNativeMessage` to a reserved name. It reaches Kylmora
/// itself, in process: no program is started and nothing is installed on the
/// Mac for it.
enum DeclarativeNetRequestShim {
    static let brokerHostName = "com.kylmora.netrequest"
    static let workerFileName = "kylmora-netrequest.js"

    static let worker = """
    (function () {
      var runtime = (typeof chrome !== "undefined" && chrome.runtime) ? chrome.runtime : null;
      if (!runtime || typeof runtime.sendNativeMessage !== "function") { return; }
      // If this engine ever grows a real implementation, it wins.
      if (typeof chrome.declarativeNetRequest !== "undefined"
          && typeof chrome.declarativeNetRequest.updateDynamicRules === "function") { return; }

      var HOST = "\(brokerHostName)";

      function call(method, args) {
        return new Promise(function (resolve, reject) {
          try {
            runtime.sendNativeMessage(HOST, { method: method, args: args || {} }, function (reply) {
              var failure = runtime.lastError;
              if (failure) { reject(new Error(failure.message || "declarativeNetRequest is unavailable.")); return; }
              if (!reply) { reject(new Error("declarativeNetRequest gave no answer.")); return; }
              if (reply.error) { reject(new Error(reply.error)); return; }
              resolve(reply.value);
            });
          } catch (error) { reject(error); }
        });
      }

      // Every method takes an optional trailing callback, the Chrome way, and
      // returns a promise when there is none, the Firefox and MV3 way.
      function method(name) {
        return function () {
          var args = Array.prototype.slice.call(arguments);
          var callback = (typeof args[args.length - 1] === "function") ? args.pop() : null;
          var running = call(name, args[0] || {});
          if (!callback) { return running; }
          running.then(function (value) {
            callback(value);
          }, function (error) {
            runtime.lastError = { message: String(error && error.message ? error.message : error) };
            try { callback(undefined); } finally { delete runtime.lastError; }
          });
          return undefined;
        };
      }

      var api = {
        updateDynamicRules: method("updateDynamicRules"),
        getDynamicRules: method("getDynamicRules"),
        updateSessionRules: method("updateSessionRules"),
        getSessionRules: method("getSessionRules"),
        updateEnabledRulesets: method("updateEnabledRulesets"),
        getEnabledRulesets: method("getEnabledRulesets"),
        getAvailableStaticRuleCount: method("getAvailableStaticRuleCount"),
        isRegexSupported: method("isRegexSupported"),
        getMatchedRules: method("getMatchedRules"),
        setExtensionActionOptions: method("setExtensionActionOptions"),
        DYNAMIC_RULESET_ID: "_dynamic",
        SESSION_RULESET_ID: "_session",
        MAX_NUMBER_OF_STATIC_RULESETS: 100,
        MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
        MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
        GETMATCHEDRULES_QUOTA_INTERVAL: 10,
        MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20
      };

      chrome.declarativeNetRequest = api;
      if (typeof browser !== "undefined" && browser) { browser.declarativeNetRequest = api; }
    })();
    """
}
