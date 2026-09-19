import Foundation

/// One running native messaging host, and the pipes to it.
///
/// The protocol is old and plain: the browser starts the program, writes
/// length-prefixed JSON to its standard input, reads length-prefixed JSON back
/// from its standard output, and the conversation ends when either side closes
/// the pipe. Everything hard about it is in the edges -- a host that dies
/// mid-sentence, one that writes a length it cannot fill, one that never
/// answers -- so those are what this type is mostly made of.
///
/// An actor, because a connection is state shared between a reader running on
/// a pipe's queue and callers arriving from the main actor.
actor NativeMessagingConnection {
    enum Failure: Error, Equatable {
        case launchFailed(String)
        /// The host closed its output, with whatever it left on standard error.
        case hostClosed(status: Int32, diagnostics: String)
        case notConnected
        case badFrame(String)
        case notSerializable
        case timedOut
    }

    /// `Process` and its pipes are older than `Sendable` and are not marked
    /// for it. They live in here so the compiler can see that only the actor
    /// and its own serial queue ever touch them.
    private final class Plumbing: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
    }

    let host: NativeMessagingHost
    private let plumbing = Plumbing()
    private let writeQueue: DispatchQueue
    private var reader = NativeMessagingFraming.Reader()
    private var state: State = .new
    /// Who is waiting for the host's next message, oldest first. Keyed,
    /// because a waiter that is given up on has to be taken out of the queue
    /// without disturbing the others' order.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Data, Error>)] = []
    /// Waiters given up on before they were even installed: cancellation can
    /// arrive before the continuation does, and the one that arrives second
    /// has to see it.
    private var abandoned: Set<UUID> = []
    /// Messages that arrived before anyone was listening.
    ///
    /// A host is free to speak first -- several of them announce themselves
    /// the moment they start -- and the extension may only get around to
    /// listening afterwards. Without this the greeting would be dropped and
    /// the extension would wait for something already said.
    private var unheard: [Data] = []
    private var messageSink: (@Sendable (Data) -> Void)?
    private var closeSink: (@Sendable (Failure) -> Void)?
    private var diagnostics = Data()
    private var readTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    private enum State: Equatable {
        case new
        case open
        case closed(Failure)
    }

    /// The tail of standard error kept for the message shown when a host
    /// fails. Hosts log freely; only the last few lines are of any use.
    private static let diagnosticsLimit = 4 * 1024

    init(host: NativeMessagingHost) {
        self.host = host
        writeQueue = DispatchQueue(label: "com.kylmora.native-messaging.write.\(host.name)")
    }

    var isOpen: Bool { state == .open }

    /// Starts the program and begins reading from it.
    ///
    /// `argv` follows the browser the manifest was written for. A host that
    /// came out of Chrome's folder is told the calling extension's origin,
    /// which is what Chrome passes; one from Firefox's folder is told where
    /// its manifest is and which add-on is calling, which is what Firefox
    /// passes. Hosts that check either would otherwise refuse to talk.
    func open(as identity: NativeMessagingExtensionIdentity) throws {
        guard state == .new else { return }
        let process = plumbing.process
        process.executableURL = host.executable
        process.arguments = Self.arguments(for: host, identity: identity)
        // A host that loads resources beside itself expects this, and it keeps
        // a host from inheriting whatever folder Kylmora happened to be in.
        process.currentDirectoryURL = host.executable.deletingLastPathComponent()
        process.standardInput = plumbing.input
        process.standardOutput = plumbing.output
        process.standardError = plumbing.errors

        let (messages, messageFeed) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let (errors, errorFeed) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        // An `AsyncStream` keeps what is yielded in order, which a `Task` per
        // read would not: two chunks of one message must not overtake each
        // other.
        plumbing.output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { messageFeed.finish() } else { messageFeed.yield(chunk) }
        }
        plumbing.errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { errorFeed.finish() } else { errorFeed.yield(chunk) }
        }

        do {
            try process.run()
        } catch {
            plumbing.output.fileHandleForReading.readabilityHandler = nil
            plumbing.errors.fileHandleForReading.readabilityHandler = nil
            messageFeed.finish()
            errorFeed.finish()
            let failure = Failure.launchFailed(error.localizedDescription)
            state = .closed(failure)
            throw failure
        }
        state = .open

        readTask = Task { [weak self] in
            for await chunk in messages {
                await self?.ingest(chunk)
            }
            await self?.hostClosedOutput()
        }
        errorTask = Task { [weak self] in
            for await chunk in errors {
                await self?.collect(chunk)
            }
        }
    }

    static func arguments(for host: NativeMessagingHost, identity: NativeMessagingExtensionIdentity) -> [String] {
        let manifestPath = host.manifestURL.path(percentEncoded: false)
        if host.directory.usesGeckoIdentifiers {
            let addon = host.allowedExtensionIDs.intersection(identity.geckoIdentifiers).sorted().first
                ?? identity.geckoIdentifiers.sorted().first
                ?? ""
            return [manifestPath, addon]
        }
        let origin = host.allowedOrigins.intersection(identity.origins).sorted().first
            ?? identity.origins.sorted().first
            ?? ""
        return [origin]
    }

    /// Hands the host `payload` and waits for the next thing it says.
    ///
    /// This is `runtime.sendNativeMessage`: one message, one reply, and the
    /// host is done. Replies are matched in order, which is all the protocol
    /// allows -- it carries no request identifiers.
    ///
    /// Messages cross this boundary as the JSON bytes that go on the wire.
    /// The engine's own `Any` is turned into bytes before it gets here and
    /// back into `Any` after it leaves, which keeps a type the compiler
    /// cannot reason about out of the concurrent part of the code.
    func request(_ payload: Data, timeout: Duration) async throws -> Data {
        try await send(payload)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.nextMessage() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                try Task.checkCancellation()
                throw Failure.timedOut
            }
            guard let first = try await group.next() else { throw Failure.notConnected }
            group.cancelAll()
            return first
        }
    }

    /// Writes one message. Used on its own by a persistent port, where replies
    /// arrive whenever the host has something to say.
    func send(_ payload: Data) async throws {
        guard case .open = state else { throw closureReason }
        let frame: Data
        do {
            frame = try NativeMessagingFraming.frame(payload)
        } catch {
            throw Failure.badFrame("The message is larger than \(NativeMessagingFraming.maximumMessageBytes) bytes.")
        }
        let descriptor = plumbing.input.fileHandleForWriting.fileDescriptor
        let queue = writeQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // `write(2)` rather than `FileHandle.write`: a host that has
                // already exited makes the latter raise, and an Objective-C
                // exception here would take the browser down with it.
                var written = 0
                frame.withUnsafeBytes { raw in
                    while written < raw.count {
                        let result = write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                        if result > 0 {
                            written += result
                            continue
                        }
                        if result == -1 && errno == EINTR { continue }
                        break
                    }
                }
                if written == frame.count {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure.notConnected)
                }
            }
        }
    }

    /// The next message from the host, or the reason there will not be one.
    ///
    /// Cancellable: whoever waits here has usually put a clock on it, and a
    /// continuation that ignored cancellation would keep the caller waiting
    /// for a host that has already been given up on.
    func nextMessage() async throws -> Data {
        if case .closed(let failure) = state { throw failure }
        if !unheard.isEmpty { return unheard.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation, as: id)
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func install(_ continuation: CheckedContinuation<Data, Error>, as id: UUID) {
        if !unheard.isEmpty {
            continuation.resume(returning: unheard.removeFirst())
            return
        }
        if abandoned.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        if case .closed(let failure) = state {
            continuation.resume(throwing: failure)
            return
        }
        waiters.append((id, continuation))
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            abandoned.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Everything the host says from now on, and the end of the conversation.
    /// Only a persistent port sets these.
    func observe(messages: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable (Failure) -> Void) {
        messageSink = messages
        closeSink = closed
        // Anything the host said before the extension was listening is said
        // again now, in the order it was said.
        let waiting = unheard
        unheard.removeAll()
        for message in waiting { messages(message) }
        if case .closed(let failure) = state { closed(failure) }
    }

    /// Ends the conversation: the host's standard input is closed, which is
    /// how a well-behaved host is asked to stop, and anything still running a
    /// moment later is stopped outright.
    func close() {
        finish(with: .notConnected)
    }

    // MARK: - Reading

    private func ingest(_ chunk: Data) {
        guard case .open = state else { return }
        let messages: [Data]
        do {
            messages = try reader.append(chunk)
        } catch NativeMessagingFraming.Failure.messageTooLarge(let length) {
            finish(with: .badFrame("The host announced a \(length)-byte message, past the \(NativeMessagingFraming.maximumMessageBytes)-byte limit."))
            return
        } catch {
            finish(with: .badFrame(error.localizedDescription))
            return
        }
        for data in messages {
            // Parsed here and thrown away: a host that writes something that
            // is not JSON has lost the thread, and finding that out now gives
            // a better error than the engine's would be.
            guard (try? NativeMessagingFraming.message(from: data)) != nil else {
                finish(with: .badFrame("The host sent \(data.count) bytes that are not JSON."))
                return
            }
            deliver(data)
        }
    }

    private func deliver(_ message: Data) {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: message)
        } else if let sink = messageSink {
            sink(message)
        } else {
            unheard.append(message)
        }
    }

    private func collect(_ chunk: Data) {
        diagnostics.append(chunk)
        if diagnostics.count > Self.diagnosticsLimit {
            diagnostics.removeSubrange(0..<(diagnostics.count - Self.diagnosticsLimit))
        }
    }

    private func hostClosedOutput() {
        guard case .open = state else { return }
        let status = plumbing.process.isRunning ? 0 : plumbing.process.terminationStatus
        finish(with: .hostClosed(status: status, diagnostics: diagnosticsText))
    }

    private var diagnosticsText: String {
        String(decoding: diagnostics, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var closureReason: Failure {
        if case .closed(let failure) = state { return failure }
        return .notConnected
    }

    /// The single place a connection ends, however it ends: handlers off,
    /// pipes closed, the program stopped, and everyone waiting told why.
    private func finish(with failure: Failure) {
        guard state != .closed(failure) else { return }
        if case .closed = state { return }
        state = .closed(failure)

        plumbing.output.fileHandleForReading.readabilityHandler = nil
        plumbing.errors.fileHandleForReading.readabilityHandler = nil
        readTask?.cancel()
        errorTask?.cancel()
        readTask = nil
        errorTask = nil

        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume(throwing: failure)
        }
        let sink = closeSink
        messageSink = nil
        closeSink = nil

        let plumbing = plumbing
        // Off the actor: closing a pipe and reaping a process both block, and
        // a host that ignores a closed stdin should not hold the actor while
        // it is being put down.
        writeQueue.async {
            try? plumbing.input.fileHandleForWriting.close()
            if plumbing.process.isRunning {
                plumbing.process.terminate()
                // A host gets a moment to leave on its own; one that does not
                // is not allowed to linger holding a pipe.
                let deadline = Date().addingTimeInterval(2)
                while plumbing.process.isRunning && Date() < deadline {
                    usleep(20_000)
                }
                if plumbing.process.isRunning {
                    kill(plumbing.process.processIdentifier, SIGKILL)
                }
            }
            try? plumbing.output.fileHandleForReading.close()
            try? plumbing.errors.fileHandleForReading.close()
        }
        sink?(failure)
    }
}

extension NativeMessagingConnection.Failure {
    /// Chrome's own wording where there is one.
    ///
    /// Extensions are written against Chrome, and a few of them read
    /// `runtime.lastError.message` and branch on it. Saying what Chrome says
    /// costs nothing and means an extension that handles "Native host has
    /// exited" handles it here too.
    var chromeMessage: String {
        switch self {
        case .launchFailed:
            return "Failed to start native messaging host."
        case .hostClosed:
            return "Native host has exited."
        case .notConnected:
            return "Attempting to use a disconnected port object"
        case .badFrame, .notSerializable:
            return "Error when communicating with the native messaging host."
        case .timedOut:
            return "The native messaging host did not reply."
        }
    }

    /// The same thing said usefully, for Kylmora's own log and Settings.
    var detail: String {
        switch self {
        case .launchFailed(let reason):
            return "Could not start the host: \(reason)"
        case .hostClosed(let status, let diagnostics):
            let exit = status == 0 ? "The host exited." : "The host exited with status \(status)."
            return diagnostics.isEmpty ? exit : "\(exit) It said: \(diagnostics)"
        case .notConnected:
            return "The connection is closed."
        case .badFrame(let reason):
            return reason
        case .notSerializable:
            return "The message cannot be written as JSON."
        case .timedOut:
            return "The host did not reply in time."
        }
    }
}
