import AVFoundation
import AppKit
import Foundation

/// Provides offline, on-device Text-to-Speech playback for articles in Reader Mode.
@MainActor
public final class ReaderSpeechService: NSObject {
    public static let shared = ReaderSpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    public private(set) var isSpeaking = false
    public private(set) var isPaused = false

    public var onStateChange: ((Bool) -> Void)?

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the given text or article content.
    public func speak(text: String, title: String? = nil) {
        stop()

        guard !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let voice = AVSpeechSynthesisVoice(language: Locale.current.identifier) ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        isSpeaking = true
        isPaused = false
        onStateChange?(true)
        synthesizer.speak(utterance)
    }

    public func pause() {
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .immediate)
            isPaused = true
            onStateChange?(false)
        }
    }

    public func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            onStateChange?(true)
        }
    }

    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
        onStateChange?(false)
    }
}

extension ReaderSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.onStateChange?(false)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.onStateChange?(false)
        }
    }
}
