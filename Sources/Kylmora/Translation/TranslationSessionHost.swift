import AppKit
import Foundation
#if canImport(Translation)
import SwiftUI
@preconcurrency import Translation

/// Where Apple's translation model does its work.
///
/// `TranslationSession` cannot be created directly on the macOS versions this
/// app supports: the Translation framework hands one to a SwiftUI view through
/// `translationTask`, and presents its "download this language" sheet on that
/// view's window. So each browser window that translates gets an invisible
/// one-point hosting view, and requests for that window queue through it one
/// at a time.
@available(macOS 15.0, *)
@MainActor
final class TranslationSessionHost {
    static let shared = TranslationSessionHost()

    private var bridges: [ObjectIdentifier: TranslationBridge] = [:]

    private init() {}

    func translate(
        _ texts: [String],
        from source: Locale.Language?,
        to target: Locale.Language,
        in window: NSWindow,
        onChunk: @escaping @MainActor (Range<Int>, [String]) async -> Void
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let bridge = bridge(for: window)
        return try await withCheckedThrowingContinuation { continuation in
            bridge.enqueue(TranslationBridge.Job(
                texts: texts, source: source, target: target,
                onChunk: onChunk, continuation: continuation
            ))
        }
    }

    /// How many windows currently carry a hosting view. For tests.
    var hostedWindowCount: Int {
        bridges.values.filter { $0.window != nil }.count
    }

    private func bridge(for window: NSWindow) -> TranslationBridge {
        bridges = bridges.filter { $0.value.window != nil }
        let key = ObjectIdentifier(window)
        if let existing = bridges[key], existing.window === window {
            return existing
        }
        let bridge = TranslationBridge(window: window)
        let hosting = NSHostingView(rootView: TranslationHostView(bridge: bridge))
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        hosting.autoresizingMask = []
        // Present but invisible: SwiftUI only runs the task for a view that
        // is in a window, and Apple's download sheet needs that window.
        hosting.alphaValue = 0
        hosting.setAccessibilityElement(false)
        window.contentView?.addSubview(hosting)
        bridge.hostingView = hosting
        bridges[key] = bridge
        return bridge
    }
}

/// One window's queue of translation jobs and the SwiftUI configuration that
/// drives its `translationTask`.
@available(macOS 15.0, *)
@MainActor
final class TranslationBridge: ObservableObject {
    struct Job: Sendable {
        let texts: [String]
        let source: Locale.Language?
        let target: Locale.Language
        let onChunk: @MainActor (Range<Int>, [String]) async -> Void
        let continuation: CheckedContinuation<[String], Error>
    }

    @Published var configuration: TranslationSession.Configuration?
    private(set) weak var window: NSWindow?
    var hostingView: NSView?

    private var queue: [Job] = []
    private var active: Job?

    init(window: NSWindow) {
        self.window = window
    }

    func enqueue(_ job: Job) {
        queue.append(job)
        pump()
    }

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        if var current = configuration, current.source == job.source, current.target == job.target {
            // Same pair as last time: the task only re-runs when the
            // configuration changes, and invalidating is how it changes.
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: job.source, target: job.target)
        }
    }

    private func currentJob() -> Job? { active }

    private func finish() {
        active = nil
        pump()
    }

    /// Called by SwiftUI with a live session whenever `configuration`
    /// changes. Runs off the main actor: the session's requests are not
    /// Sendable, so the work stays in one place and only the results and the
    /// progress callbacks cross back.
    nonisolated func run(_ session: TranslationSession) async {
        guard let job = await currentJob() else { return }
        do {
            // Downloads the language pack if it is missing, asking first.
            try await session.prepareTranslation()
            var results: [String] = []
            results.reserveCapacity(job.texts.count)
            for range in TranslationBatch.ranges(count: job.texts.count) {
                let requests = range.map { index in
                    TranslationSession.Request(sourceText: job.texts[index], clientIdentifier: String(index))
                }
                let responses = try await session.translations(from: requests)
                var byIndex: [Int: String] = [:]
                for response in responses {
                    if let id = response.clientIdentifier, let index = Int(id) {
                        byIndex[index] = response.targetText
                    }
                }
                // Anything the model returned nothing for keeps its original.
                let translated = range.map { byIndex[$0] ?? job.texts[$0] }
                results.append(contentsOf: translated)
                await job.onChunk(range, translated)
            }
            job.continuation.resume(returning: results)
        } catch {
            job.continuation.resume(throwing: error)
        }
        await finish()
    }
}

@available(macOS 15.0, *)
private struct TranslationHostView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
    }
}
#endif
