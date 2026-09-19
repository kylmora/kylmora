import Foundation

/// One notification a page asked for, in the form Kylmora keeps it.
///
/// The page's own object lives in JavaScript; this is the half Kylmora has to
/// remember, because the system notification centre hands back nothing but an
/// identifier when the person clicks. Everything needed to find the way home --
/// which tab asked, which origin it belonged to, what the page called it -- is
/// here, keyed by that identifier.
struct WebNotificationRecord: Identifiable, Equatable, Sendable {
    let id: String
    /// The scheme-and-host the page was on. Notifications are grouped by it in
    /// the centre, and a site may only close its own.
    let origin: String
    /// The page's `tag`. A second notification with the same non-empty tag from
    /// the same origin replaces the first rather than stacking on it.
    let tag: String
    let title: String
    let body: String
    let icon: URL?
    let language: String
    let direction: String
    let isSilent: Bool
    let requiresInteraction: Bool
    let renotifies: Bool
    /// The page's `data`, carried as JSON text so it can cross actors and come
    /// back to the page unchanged when the notification is clicked.
    let data: String?
    let timestamp: Date
    /// The tab that asked. Nil once that tab has gone, which is why a click has
    /// to cope with never finding one.
    let tabID: UUID?
    /// Whether it came through a service worker registration rather than the
    /// `Notification` constructor. Only the bookkeeping differs; a page-created
    /// one is closed when its tab goes, a worker's is not.
    let isFromServiceWorker: Bool

    /// Reads the payload the shim posts. Anything missing takes its default
    /// from the spec rather than failing: a page that passes only a title is
    /// perfectly ordinary, and a page that passes rubbish should get a plain
    /// notification rather than silence.
    init?(payload: [String: Any], id: String, origin: String, tabID: UUID?, now: Date = Date()) {
        guard let title = payload["title"] as? String else { return nil }
        self.id = id
        self.origin = origin
        self.title = title
        self.tag = (payload["tag"] as? String) ?? ""
        self.body = (payload["body"] as? String) ?? ""
        self.icon = Self.iconURL(payload["icon"] as? String, origin: origin)
        self.language = (payload["lang"] as? String) ?? ""
        self.direction = (payload["dir"] as? String) ?? "auto"
        self.isSilent = (payload["silent"] as? Bool) ?? false
        self.requiresInteraction = (payload["requireInteraction"] as? Bool) ?? false
        self.renotifies = (payload["renotify"] as? Bool) ?? false
        self.data = payload["data"] as? String
        if let stamp = payload["timestamp"] as? Double, stamp > 0 {
            self.timestamp = Date(timeIntervalSince1970: stamp / 1000)
        } else {
            self.timestamp = now
        }
        self.tabID = tabID
        self.isFromServiceWorker = (payload["fromServiceWorker"] as? Bool) ?? false
    }

    /// Only an image the system can actually fetch and show. A `blob:` or a
    /// `data:` URL cannot be turned into an attachment without writing it out
    /// first, and a page-relative path has already been resolved by the shim;
    /// anything else is dropped and the notification goes without a picture.
    private static func iconURL(_ text: String?, origin: String) -> URL? {
        guard let text, !text.isEmpty, let url = URL(string: text) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// What the centre shows as the source. A notification has to say where it
    /// came from or it is indistinguishable from one Kylmora itself sent.
    var displayOrigin: String {
        guard let host = URL(string: origin)?.host() else { return origin }
        return host
    }
}

/// Which notifications are on screen, and the rules about replacing them.
///
/// Deliberately free of WebKit and of the system centre, because every rule
/// worth getting wrong lives here: that a tag replaces rather than stacks, that
/// one origin cannot close another's, and that a page in a loop cannot fill the
/// notification centre.
struct WebNotificationStore {
    /// How many a single origin may have on screen at once. A page that posts
    /// in a loop is not a rare accident, and the person's notification centre
    /// is not the place to discover it. The oldest goes to make room.
    static let limitPerOrigin = 24

    private(set) var records: [WebNotificationRecord] = []

    init() {}

    /// The result of showing one: the identifiers the centre should withdraw,
    /// because they were replaced by tag or evicted to stay under the cap.
    struct Outcome: Equatable {
        var displaced: [String] = []
    }

    @discardableResult
    mutating func show(_ record: WebNotificationRecord) -> Outcome {
        var outcome = Outcome()
        // A tag is the page saying "this supersedes the last one". An empty tag
        // is not a tag: several untagged notifications stack, as they should.
        if !record.tag.isEmpty {
            let replaced = records.filter { $0.origin == record.origin && $0.tag == record.tag }
            outcome.displaced.append(contentsOf: replaced.map(\.id))
            records.removeAll { $0.origin == record.origin && $0.tag == record.tag }
        }
        records.append(record)
        // Evict oldest-first, and only this origin's: a noisy site must not
        // push a quiet one's notifications off the screen.
        var mine = records.filter { $0.origin == record.origin }
        while mine.count > Self.limitPerOrigin {
            let oldest = mine.removeFirst()
            outcome.displaced.append(oldest.id)
            records.removeAll { $0.id == oldest.id }
        }
        return outcome
    }

    func record(id: String) -> WebNotificationRecord? {
        records.first { $0.id == id }
    }

    /// The notifications a page may see: its own origin's, newest last, and
    /// filtered by tag when it asked for one. This is `getNotifications`.
    func records(origin: String, tag: String = "") -> [WebNotificationRecord] {
        records.filter { $0.origin == origin && (tag.isEmpty || $0.tag == tag) }
    }

    /// Closing is origin-checked rather than trusting the identifier, so a page
    /// that guesses or is handed another site's identifier still closes nothing.
    @discardableResult
    mutating func close(id: String, origin: String) -> Bool {
        guard let found = records.first(where: { $0.id == id }), found.origin == origin else { return false }
        records.removeAll { $0.id == id }
        return true
    }

    @discardableResult
    mutating func remove(id: String) -> WebNotificationRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }

    /// A tab going takes its page's notifications with it: the page that could
    /// have answered a click no longer exists. A service worker's outlive the
    /// tab, which is the whole point of them.
    @discardableResult
    mutating func removeAll(tabID: UUID) -> [String] {
        let gone = records.filter { $0.tabID == tabID && !$0.isFromServiceWorker }
        records.removeAll { $0.tabID == tabID && !$0.isFromServiceWorker }
        return gone.map(\.id)
    }

    @discardableResult
    mutating func removeAll(origin: String) -> [String] {
        let gone = records.filter { $0.origin == origin }
        records.removeAll { $0.origin == origin }
        return gone.map(\.id)
    }
}
