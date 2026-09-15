import AppKit
import Foundation
#if canImport(Translation)
@preconcurrency import Translation
#endif

/// Whether Apple's on-device translation can handle a language pair here.
public enum TranslationAvailability: Equatable, Sendable {
    /// The language pack is on this Mac; translation starts at once.
    case installed
    /// Apple supports the pair but the pack is not downloaded yet. macOS
    /// asks the user to download it the first time it is needed.
    case downloadable
    /// Apple's models do not translate between these two languages.
    case unsupported
    /// This Mac is older than macOS 15, which introduced the framework.
    case needsNewerMacOS
}

/// The one thing the phrase-table era got right: the shape of a request.
/// A page is translated in chunks so the first paragraphs change on screen
/// while the rest is still being worked on.
public enum TranslationBatch {
    /// Apple's batch API is fastest with a few hundred short strings at a time.
    public static let size = 120

    /// Splits `count` items into consecutive ranges of at most `size`.
    public static func ranges(count: Int, size: Int = TranslationBatch.size) -> [Range<Int>] {
        guard count > 0, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            start..<min(start + size, count)
        }
    }

    /// `Locale.Language` for one of the codes `TranslationLanguages` uses.
    public static func language(for code: String) -> Locale.Language {
        Locale.Language(identifier: code)
    }
}

/// Apple's on-device translation, driven from AppKit.
///
/// Everything happens on this Mac: the Translation framework runs its models
/// locally and the page's text never leaves the machine. The framework only
/// hands out a `TranslationSession` through SwiftUI, so the actual call goes
/// through `TranslationSessionHost`, which keeps an invisible SwiftUI view in
/// the browser window for that purpose and shows Apple's language-download
/// sheet there when a pack is missing.
@MainActor
public enum NativeTranslation {
    /// Whether the pair can be translated on this Mac, and what it would take.
    public static func availability(from source: String?, to target: String) async -> TranslationAvailability {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return .needsNewerMacOS }
        let availability = LanguageAvailability()
        let targetLanguage = TranslationBatch.language(for: target)
        guard let source else {
            // Source unknown: the framework identifies it itself once it has
            // text, so all that can be checked now is the target.
            let supported = await availability.supportedLanguages
            let targetCode = targetLanguage.languageCode?.identifier
            return supported.contains(where: { $0.languageCode?.identifier == targetCode }) ? .downloadable : .unsupported
        }
        switch await availability.status(from: TranslationBatch.language(for: source), to: targetLanguage) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #else
        return .needsNewerMacOS
        #endif
    }

    /// Translates `texts` in order. `onChunk` is awaited on the main actor as
    /// each batch comes back, with the range it covers, so the caller can put
    /// it on screen before the whole page is done.
    public static func translate(
        _ texts: [String],
        from source: String?,
        to target: String,
        in window: NSWindow,
        onChunk: @escaping @MainActor (Range<Int>, [String]) async -> Void
    ) async throws -> [String] {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { throw TranslationFailure.needsNewerMacOS }
        return try await TranslationSessionHost.shared.translate(
            texts,
            from: source.map(TranslationBatch.language(for:)),
            to: TranslationBatch.language(for: target),
            in: window,
            onChunk: onChunk
        )
        #else
        throw TranslationFailure.needsNewerMacOS
        #endif
    }
}

/// Why a page could not be translated, in words the popover can show.
public enum TranslationFailure: LocalizedError, Equatable {
    case needsNewerMacOS
    case unsupportedPair(source: String?, target: String)
    case noWindow
    case nothingToTranslate

    public var errorDescription: String? {
        switch self {
        case .needsNewerMacOS:
            return "Page translation uses Apple's on-device translation, which needs macOS 15 or later."
        case .unsupportedPair(let source, let target):
            let to = TranslationLanguages.displayName(for: target)
            if let source {
                return "Apple's on-device translation cannot translate \(TranslationLanguages.displayName(for: source)) into \(to)."
            }
            return "Apple's on-device translation cannot translate into \(to)."
        case .noWindow:
            return "The page has to be on screen to be translated."
        case .nothingToTranslate:
            return "No translatable text found on this page."
        }
    }
}
