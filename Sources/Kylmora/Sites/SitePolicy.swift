import AppKit
import CoreLocation
import UserNotifications
import WebKit

/// The per-site choices that can only be honoured from inside the page.
///
/// WebKit has no public switch for a page's use of autoplay, notifications,
/// geolocation, screen capture or picture in picture, and no reader. So each
/// of those is a script Kylmora puts in the page: the behaviour scripts are
/// added once per controller, and a one-line policy script carrying the
/// resolved settings for the page's site is replaced on every main-frame
/// navigation. The behaviour scripts read the policy when they are used,
/// not when they load, so the order the two arrive in does not matter.
///
/// Notifications and geolocation are provided, not just gated: the page's
/// calls come to Kylmora over a message handler, and Kylmora answers them with the
/// system's notification centre and Core Location.
@MainActor
final class SitePolicy: NSObject {
    static let shared = SitePolicy()

    static let messageName = "kylmoraSite"
    private static let policyPrefix = "window.__kylmoraSite = "

    private let settings: SiteSettings
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let location = LocationProvider()
    /// The tab behind a web view, for reports that belong to a tab.
    var tabResolver: ((WKWebView) -> Tab?)?

    init(settings: SiteSettings = .shared) {
        self.settings = settings
    }

    /// Adds the behaviour scripts and the message handler once.
    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        for script in SiteBehaviourScripts.all {
            controller.addUserScript(script)
        }
    }

    /// A page is about to load on `url`: give its scripts the site's values.
    func apply(for url: URL?, to controller: WKUserContentController) {
        let policy = settings.policy(for: url)
        guard let data = try? JSONSerialization.data(withJSONObject: policy) else { return }
        let source = Self.policyPrefix + String(decoding: data, as: UTF8.self) + ";"
        let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.policyPrefix) }
        guard others.count != controller.userScripts.count || !controller.userScripts.contains(where: { $0.source == source }) else {
            return
        }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    // MARK: - Notifications

    /// Whether this process can talk to the notification centre at all: a
    /// test binary cannot, and asking crashes rather than failing.
    private static var hasNotificationCentre: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationAuthorisation() async -> Bool {
        guard Self.hasNotificationCentre else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func deliverNotification(title: String, body: String, site: String) async {
        guard Self.hasNotificationCentre else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = site
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension SitePolicy: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            return (nil, "Unrecognised message.")
        }
        let pageURL = message.frameInfo.request.url ?? message.webView?.url
        let site = pageURL?.host() ?? "a website"
        switch kind {
        case "askNotification":
            if settings.permission(.notifications, for: pageURL) == .deny { return ("denied", nil) }
            return (await requestNotificationAuthorisation() ? "granted" : "denied", nil)
        case "notification":
            guard settings.permission(.notifications, for: pageURL) != .deny else { return (nil, "Denied.") }
            let title = body["title"] as? String ?? site
            let text = body["body"] as? String ?? ""
            await deliverNotification(title: title, body: text, site: site)
            return (true, nil)
        case "pictureInPicture":
            if let webView = message.webView, let tab = tabResolver?(webView) {
                tab.setPictureInPicture(body["active"] as? Bool ?? false)
            }
            return (true, nil)
        case "geolocation":
            guard settings.permission(.location, for: pageURL) != .deny else { return (["error": "denied"], nil) }
            do {
                let fix = try await location.currentLocation()
                return ([
                    "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
                    "accuracy": fix.horizontalAccuracy, "timestamp": fix.timestamp.timeIntervalSince1970 * 1000
                ], nil)
            } catch {
                return (["error": "unavailable", "message": error.localizedDescription], nil)
            }
        default:
            return (nil, "Unrecognised message.")
        }
    }
}

/// One location fix at a time from Core Location, with the system's own
/// permission prompt on first use.
@MainActor
private final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The manager is read back through `self` on the main actor rather
        // than carried into the task: it is not `Sendable`, and it is ours.
        Task { @MainActor in
            switch self.manager.authorizationStatus {
            case .authorized, .authorizedAlways:
                if !waiting.isEmpty { self.manager.requestLocation() }
            case .denied, .restricted:
                fail(CLError(.denied))
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in
            let continuations = waiting
            waiting.removeAll()
            for continuation in continuations { continuation.resume(returning: fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in fail(error) }
    }

    private func fail(_ error: Error) {
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}
