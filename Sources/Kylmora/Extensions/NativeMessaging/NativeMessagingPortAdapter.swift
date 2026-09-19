import Foundation
import WebKit

/// WebKit's message port, as the native messaging service wants it.
///
/// `WKWebExtension.MessagePort` is the engine's end of `runtime.connectNative`.
/// It exists only on macOS 15.4 and later, so everything that touches it is
/// kept here, behind the small protocol the service works against.
@available(macOS 15.4, *)
@MainActor
final class NativeMessagingPortAdapter: NativeMessagingPort {
    private let port: WKWebExtension.MessagePort

    var receive: ((Any) -> Void)? {
        didSet {
            port.messageHandler = { [weak self] message, _ in
                guard let message else { return }
                self?.receive?(message)
            }
        }
    }

    var closed: (() -> Void)? {
        didSet {
            port.disconnectHandler = { [weak self] _ in
                self?.closed?()
            }
        }
    }

    init(_ port: WKWebExtension.MessagePort) {
        self.port = port
    }

    var hostName: String? { port.applicationIdentifier }

    var isClosed: Bool { port.isDisconnected }

    func deliver(_ message: Any) {
        port.sendMessage(message) { _ in }
    }

    func close(with error: Error?) {
        if let error {
            port.disconnect(throwing: error)
        } else {
            port.disconnect()
        }
    }
}
