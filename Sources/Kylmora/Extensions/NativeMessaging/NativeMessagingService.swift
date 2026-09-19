import Foundation

/// Native messaging: the part of the extension platform that lets an
/// extension talk to a program installed on the Mac.
///
/// An extension cannot start a process, so the browser does it on the
/// extension's behalf. That is the whole feature, and it is what makes
/// 1Password, Bitwarden, iCloud Passwords and their kind work: the extension
/// in the page is a thin front end, and the vault lives in an app that only
/// the browser can reach for it.
///
/// It is also the most dangerous thing an extension platform does, so every
/// launch has to pass, in order: the feature is on, the organisation allows
/// it, the extension asked for the `nativeMessaging` permission, the host's
/// own manifest names that extension, and the program named is one that is
/// there and that only its owner can change. Miss any of them and nothing
/// starts.
/// The extension's end of a persistent connection.
///
/// WebKit's own port type exists only on macOS 15.4 and later, and an
/// availability-gated type cannot be reached from everywhere this service is.
/// The protocol keeps the service free of that constraint; the adapter that
/// implements it over `WKWebExtension.MessagePort` lives beside the extension
/// engine, which is the only place that knows about WebKit at all.
@MainActor
protocol NativeMessagingPort: AnyObject {
    /// The host the extension asked for.
    var hostName: String? { get }
    var isClosed: Bool { get }
    /// Called with each message the host sends.
    var receive: ((Any) -> Void)? { get set }
    /// Called when the extension hangs up.
    var closed: (() -> Void)? { get set }
    func deliver(_ message: Any)
    func close(with error: Error?)
}

@MainActor
final class NativeMessagingService {
    static let shared = NativeMessagingService()

    /// What happened, for Settings and for the log. Enough to answer "why did
    /// my password manager not open?" without a debugger.
    struct Event: Identifiable, Sendable {
        enum Outcome: Sendable, Equatable {
            case connected
            case replied
            case closed
            case refused(String)
            case failed(String)
        }
        let id = UUID()
        let at: Date
        let hostName: String
        let extensionName: String
        let outcome: Outcome
        var isPersistent: Bool = false
    }

    enum Denial: Error, Equatable {
        case turnedOff
        case blockedByPolicy
        case hostBlocked(String)
        case noSuchHost(String)
        case notAllowedByHost(String)
        case permissionMissing
        case noHostNamed
    }

    /// `KYLMORA_EXTENSION_LOG=1` prints every launch, refusal and failure.
    static let isLogging = ProcessInfo.processInfo.environment["KYLMORA_EXTENSION_LOG"] == "1"

    /// How long `sendNativeMessage` waits for the single reply it is owed.
    /// Chrome waits forever; a browser that waits forever leaks a process per
    /// silent host, and no real host is slow by minutes.
    var replyTimeout: Duration = .seconds(30)

    private let registry: NativeMessagingHostRegistry
    private let settings: Settings
    private let policies: EnterprisePolicyManager
    /// Live persistent connections, keyed so nothing is collected while the
    /// extension still has a port open on it.
    private var connections: [UUID: NativeMessagingConnection] = [:]
    private var ports: [UUID: any NativeMessagingPort] = [:]
    private(set) var events: [Event] = []
    /// Settings redraws on this.
    var onChange: (() -> Void)?

    init(registry: NativeMessagingHostRegistry = NativeMessagingHostRegistry(),
         settings: Settings = .shared,
         policies: EnterprisePolicyManager = .shared) {
        self.registry = registry
        self.settings = settings
        self.policies = policies
    }

    // MARK: - What the user and the organisation allow

    var isEnabled: Bool {
        settings.nativeMessagingEnabled && !policies.isNativeMessagingDisabled
    }

    var usesOtherBrowsersHosts: Bool {
        settings.nativeMessagingUsesOtherBrowsers
    }

    /// The hosts Kylmora can see, with the manifests it refused and why.
    func scan(refreshing: Bool = false) async -> NativeMessagingHostRegistry.Scan {
        await registry.scan(includingOtherBrowsers: usesOtherBrowsersHosts, refreshing: refreshing)
    }

    func isBlocked(_ hostName: String) -> Bool {
        settings.nativeMessagingBlockedHosts.contains(hostName.lowercased())
    }

    func setBlocked(_ blocked: Bool, hostName: String) {
        var names = Set(settings.nativeMessagingBlockedHosts)
        if blocked { names.insert(hostName.lowercased()) } else { names.remove(hostName.lowercased()) }
        settings.nativeMessagingBlockedHosts = Array(names).sorted()
        if blocked { disconnectAll(hostNamed: hostName.lowercased()) }
        onChange?()
    }

    // MARK: - The two things the engine asks for

    /// `runtime.sendNativeMessage`: start the host, say one thing, take one
    /// answer, stop the host.
    func send(_ message: Any?,
              toHostNamed name: String?,
              from identity: NativeMessagingExtensionIdentity,
              hasPermission: Bool) async throws -> Any {
        let host = try await resolve(name, for: identity, hasPermission: hasPermission)
        let connection = NativeMessagingConnection(host: host)
        do {
            let payload = try NativeMessagingFraming.data(from: message)
            try await connection.open(as: identity)
            let reply = try NativeMessagingFraming.message(
                from: try await connection.request(payload, timeout: replyTimeout)
            )
            await connection.close()
            record(Event(at: .now, hostName: host.name, extensionName: identity.displayName, outcome: .replied))
            return reply
        } catch {
            await connection.close()
            let failure = error as? NativeMessagingConnection.Failure ?? .notConnected
            record(Event(at: .now, hostName: host.name, extensionName: identity.displayName,
                         outcome: .failed(failure.detail)))
            throw failure
        }
    }

    /// `runtime.connectNative`: start the host and leave it running, with
    /// messages crossing in both directions until one side hangs up.
    func connect(_ port: any NativeMessagingPort,
                 from identity: NativeMessagingExtensionIdentity,
                 hasPermission: Bool) async throws {
        let host: NativeMessagingHost
        do {
            host = try await resolve(port.hostName, for: identity, hasPermission: hasPermission)
        } catch {
            // Closed with the reason on it as well as refused through the
            // completion handler. The engine currently hands the extension a
            // port that "closed cleanly" either way -- `runtime.lastError` is
            // empty in `onDisconnect` -- so the reason reaches the user
            // through Settings and the log rather than the extension. A
            // one-shot `sendNativeMessage` does carry it.
            if !port.isClosed { port.close(with: Self.error(error)) }
            throw error
        }
        let connection = NativeMessagingConnection(host: host)
        do {
            try await connection.open(as: identity)
        } catch {
            if !port.isClosed { port.close(with: Self.error(error)) }
            throw error
        }

        let key = UUID()
        connections[key] = connection
        ports[key] = port

        // Host to extension.
        await connection.observe(
            messages: { [weak self] payload in
                Task { @MainActor in
                    guard let port = self?.ports[key], !port.isClosed else { return }
                    guard let message = try? NativeMessagingFraming.message(from: payload) else { return }
                    port.deliver(message)
                }
            },
            closed: { [weak self] failure in
                Task { @MainActor in
                    guard let self else { return }
                    if let port = self.ports[key], !port.isClosed {
                        port.close(with: Self.error(failure))
                    }
                    self.forget(key)
                    self.record(Event(at: .now, hostName: host.name, extensionName: identity.displayName,
                                      outcome: .closed, isPersistent: true))
                }
            }
        )

        // Extension to host.
        port.receive = { [weak self] message in
            // The engine hands over a JSON value; the wire takes bytes. The
            // conversion happens here, on the main actor, so nothing that is
            // not `Sendable` is carried into the connection.
            let payload = try? NativeMessagingFraming.data(from: message)
            Task { @MainActor in
                guard let connection = self?.connections[key] else { return }
                guard let payload else {
                    await connection.close()
                    return
                }
                do {
                    try await connection.send(payload)
                } catch {
                    await connection.close()
                }
            }
        }
        port.closed = { [weak self] in
            Task { @MainActor in
                guard let self, let connection = self.connections[key] else { return }
                await connection.close()
                self.forget(key)
            }
        }

        record(Event(at: .now, hostName: host.name, extensionName: identity.displayName,
                     outcome: .connected, isPersistent: true))
    }

    /// Every live connection, ended. Called when the app quits, when the
    /// feature is switched off, and when an extension is removed.
    func disconnectAll() {
        for key in connections.keys { end(key) }
    }

    func disconnectAll(hostNamed name: String) {
        for (key, connection) in connections where connection.host.name == name {
            _ = connection
            end(key)
        }
    }

    var liveConnectionCount: Int { connections.count }

    // MARK: - Gates

    private func resolve(_ name: String?,
                         for identity: NativeMessagingExtensionIdentity,
                         hasPermission: Bool) async throws -> NativeMessagingHost {
        func refuse(_ denial: Denial, _ hostName: String) throws -> Never {
            record(Event(at: .now, hostName: hostName, extensionName: identity.displayName,
                         outcome: .refused(Self.reason(denial))))
            throw denial
        }
        guard let name, !name.isEmpty else { try refuse(.noHostNamed, "") }
        let lowered = name.lowercased()
        guard settings.nativeMessagingEnabled else { try refuse(.turnedOff, lowered) }
        guard !policies.isNativeMessagingDisabled else { try refuse(.blockedByPolicy, lowered) }
        if let allowed = policies.nativeMessagingHostAllowlist, !allowed.isEmpty,
           !allowed.contains(where: { $0.caseInsensitiveCompare(lowered) == .orderedSame }) {
            try refuse(.blockedByPolicy, lowered)
        }
        guard NativeMessagingHost.isValidName(lowered) else { try refuse(.noSuchHost(lowered), lowered) }
        guard !isBlocked(lowered) else { try refuse(.hostBlocked(lowered), lowered) }
        guard hasPermission else { try refuse(.permissionMissing, lowered) }
        guard let host = await registry.host(named: lowered, includingOtherBrowsers: usesOtherBrowsersHosts) else {
            try refuse(.noSuchHost(lowered), lowered)
        }
        guard host.allows(identity) else { try refuse(.notAllowedByHost(lowered), lowered) }
        return host
    }

    private func forget(_ key: UUID) {
        connections[key] = nil
        ports[key] = nil
        onChange?()
    }

    private func end(_ key: UUID) {
        guard let connection = connections[key] else { return }
        let port = ports[key]
        forget(key)
        Task {
            await connection.close()
            await MainActor.run {
                if let port, !port.isClosed { port.close(with: nil) }
            }
        }
    }

    private func record(_ event: Event) {
        events.insert(event, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
        onChange?()
        if Self.isLogging {
            NSLog("kylmora.native-messaging: %@ %@ %@", event.hostName, event.extensionName, String(describing: event.outcome))
        }
    }

    // MARK: - Words

    static func reason(_ denial: Denial) -> String {
        switch denial {
        case .turnedOff:
            return "Native messaging is switched off in Settings."
        case .blockedByPolicy:
            return "Your organisation does not allow native messaging."
        case .hostBlocked(let name):
            return "\(name) is switched off in Settings."
        case .noSuchHost(let name):
            return "No app on this Mac installed a native messaging host named \(name)."
        case .notAllowedByHost(let name):
            return "\(name) does not list this extension as one it will talk to."
        case .permissionMissing:
            return "The extension did not ask for the nativeMessaging permission."
        case .noHostNamed:
            return "The extension did not say which host to connect to."
        }
    }

    /// Chrome's wording on the outside, ours underneath.
    static let errorDomain = "com.kylmora.native-messaging"

    static func error(_ denial: Denial) -> NSError {
        let chrome: String
        switch denial {
        case .noSuchHost:
            chrome = "Specified native messaging host not found."
        default:
            chrome = "Access to the specified native messaging host is forbidden."
        }
        return NSError(domain: errorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: chrome,
            NSLocalizedFailureReasonErrorKey: reason(denial),
        ])
    }

    static func error(_ failure: NativeMessagingConnection.Failure) -> NSError {
        NSError(domain: errorDomain, code: 2, userInfo: [
            NSLocalizedDescriptionKey: failure.chromeMessage,
            NSLocalizedFailureReasonErrorKey: failure.detail,
        ])
    }

    static func error(_ error: Error) -> NSError {
        if let denial = error as? Denial { return self.error(denial) }
        if let failure = error as? NativeMessagingConnection.Failure { return self.error(failure) }
        return NSError(domain: errorDomain, code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Error when communicating with the native messaging host.",
            NSLocalizedFailureReasonErrorKey: error.localizedDescription,
        ])
    }
}
