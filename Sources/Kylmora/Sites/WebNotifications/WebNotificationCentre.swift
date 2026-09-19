import AppKit
import UserNotifications

/// The system half of web notifications, behind a seam.
///
/// `UNUserNotificationCenter.current()` traps outright in a process that is not
/// a bundled application, which a test binary is not -- so the one place that
/// touches it is here, and everything worth testing sits on the other side of
/// this protocol.
@MainActor
protocol WebNotificationBackend: AnyObject {
    func authorise() async -> Bool
    func deliver(_ request: UNNotificationRequest) async -> Bool
    func withdraw(_ identifiers: [String])
}

/// The real centre.
@MainActor
final class SystemNotificationBackend: NSObject, WebNotificationBackend {
    /// A bundled application with an identifier is the only shape of process
    /// the notification centre will speak to; anything else crashes on the
    /// first call rather than returning an error.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func authorise() async -> Bool {
        guard Self.isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }


    func deliver(_ request: UNNotificationRequest) async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    func withdraw(_ identifiers: [String]) {
        guard Self.isAvailable, !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Web notifications: what the page asked for, what the system shows, and what
/// happens when the person clicks one.
///
/// The part worth saying out loud is the click. A notification the person
/// cannot click back to its page is a dead end, and a browser that posts dead
/// ends is worse than one that posts nothing -- so every notification carries
/// its identifier in `userInfo`, and a click looks that identifier up, brings
/// the owning tab to the front and lets the page's own handler run.
@MainActor
final class WebNotificationCentre: NSObject {
    static let shared = WebNotificationCentre()

    /// Kylmora's own notifications must not be mistaken for a website's, so a
    /// web one is marked and carries the identifier the store knows it by.
    nonisolated static let identifierKey = "kylmoraWebNotification"
    nonisolated static let originKey = "kylmoraWebNotificationOrigin"

    private var store = WebNotificationStore()
    private let backend: WebNotificationBackend

    /// Bring a tab to the front, Space and all. Set by the app delegate; a nil
    /// resolver simply means a click cannot navigate, not that it crashes.
    var focusTab: ((UUID) -> Void)?
    /// Run the page's own `click` or `close` handler for a notification.
    var dispatchEvent: ((WebNotificationRecord, String) -> Void)?

    init(backend: WebNotificationBackend? = nil) {
        self.backend = backend ?? SystemNotificationBackend()
        super.init()
    }

    /// Takes over the system delegate. Without this a notification posted while
    /// Kylmora is the frontmost application is never shown at all -- macOS
    /// suppresses banners for the active app unless the delegate asks for them
    /// -- and a click on one that did appear goes nowhere. A browser is
    /// frontmost most of the time it is posting notifications, so this is not
    /// an edge case; it is the common one.
    func start() {
        guard SystemNotificationBackend.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - What the page asks for

    func requestAuthorisation() async -> Bool {
        await backend.authorise()
    }


    /// Shows one, and answers with the identifier the page should keep. Nil
    /// means it was not shown, and the page's `error` handler should run.
    func show(payload: [String: Any], origin: String, tabID: UUID?) async -> String? {
        let id = UUID().uuidString
        guard let record = WebNotificationRecord(payload: payload, id: id, origin: origin, tabID: tabID) else {
            return nil
        }
        // Replaced and evicted ones leave the screen before the new one lands,
        // so a tagged stream never flickers two of itself into the centre.
        let outcome = store.show(record)
        backend.withdraw(outcome.displaced)
        let content = await content(for: record)
        let request = UNNotificationRequest(identifier: record.id, content: content, trigger: nil)
        guard await backend.deliver(request) else {
            store.remove(id: record.id)
            return nil
        }
        return record.id
    }

    /// The page closing one of its own.
    func close(id: String, origin: String) {
        guard store.close(id: id, origin: origin) else { return }
        backend.withdraw([id])
    }

    /// `getNotifications`: what this origin still has on screen.
    func notifications(origin: String, tag: String) -> [[String: Any]] {
        store.records(origin: origin, tag: tag).map { record in
            var value: [String: Any] = [
                "id": record.id,
                "title": record.title,
                "body": record.body,
                "tag": record.tag,
                "lang": record.language,
                "dir": record.direction,
                "silent": record.isSilent,
                "requireInteraction": record.requiresInteraction,
                "timestamp": record.timestamp.timeIntervalSince1970 * 1000
            ]
            if let icon = record.icon { value["icon"] = icon.absoluteString }
            if let data = record.data { value["data"] = data }
            return value
        }
    }

    /// A tab has gone. Its page cannot answer a click any more, so its
    /// notifications go with it -- except a service worker's, which are meant
    /// to outlive the page that registered them.
    func forget(tabID: UUID) {
        let gone = store.removeAll(tabID: tabID)
        backend.withdraw(gone)
    }

    /// A JavaScript string literal for a value that came back from the system
    /// centre. The identifiers are Kylmora's own UUIDs, but building script
    /// text by concatenation is the kind of shortcut that stays wrong once the
    /// values stop being ours.
    static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Turning a record into something the system will show

    /// Built here rather than inline so a test can read every field of it
    /// without a notification centre to post it to.
    func content(for record: WebNotificationRecord) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = record.title
        // The site, always. A notification that does not say who sent it is one
        // the person cannot judge, and a browser posts on behalf of strangers.
        content.subtitle = record.displayOrigin
        content.body = record.body
        content.sound = record.isSilent ? nil : .default
        // One thread per site, so the centre groups a site's notifications the
        // way it groups a messaging app's.
        content.threadIdentifier = record.origin
        content.userInfo = [
            Self.identifierKey: record.id,
            Self.originKey: record.origin
        ]
        if record.requiresInteraction {
            // Honoured only where the entitlement allows; harmless elsewhere.
            content.interruptionLevel = .timeSensitive
        }
        if let icon = record.icon, let attachment = await Self.attachment(for: icon, id: record.id) {
            content.attachments = [attachment]
        }
        return content
    }

    /// Downloads the page's icon and hands it to the centre as an attachment.
    /// Best-effort throughout: a notification with no picture is fine, a
    /// notification that never appears because an icon 404'd is not.
    private static func attachment(for url: URL, id: String) async -> UNNotificationAttachment? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              // An icon is a small image. Anything larger is not one, and the
              // page does not get to make Kylmora download it.
              data.count <= 2 * 1024 * 1024,
              let type = response.mimeType, type.hasPrefix("image/") else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KylmoraWebNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id).appendingPathExtension(Self.extension(for: type))
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: id, url: file)
    }

    private static func `extension`(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        default: return "jpg"
        }
    }
}

extension WebNotificationCentre: UNUserNotificationCenterDelegate {
    /// Show it even though Kylmora is frontmost. Without this the banner is
    /// swallowed and the page's notification simply never happened.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isWeb = notification.request.content.userInfo[Self.identifierKey] != nil
        let wantsSound = notification.request.content.sound != nil
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if wantsSound { options.insert(.sound) }
        completionHandler(isWeb ? options : [.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = info[Self.identifierKey] as? String
        let action = response.actionIdentifier
        // The system's completion handler is not `Sendable`, and the work it
        // reports on has to happen on the main actor. Carried rather than
        // called early, so "handled" means handled.
        let finish = UncheckedBox(completionHandler)
        Task { @MainActor in
            if let id { self.handle(action: action, id: id) }
            finish.value()
        }
    }

    /// A click brings the page back and lets it run its handler; a dismissal
    /// only tells the page it is gone.
    func handle(action: String, id: String) {
        guard let record = store.record(id: id) else { return }
        switch action {
        case UNNotificationDismissActionIdentifier:
            store.remove(id: id)
            dispatchEvent?(record, "close")
        default:
            store.remove(id: id)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let tabID = record.tabID { focusTab?(tabID) }
            dispatchEvent?(record, "click")
        }
    }
}


/// A value the compiler cannot prove is safe to move between actors, carried
/// anyway because it is used exactly once and on one actor: the system's own
/// completion handlers, which predate `Sendable`.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
