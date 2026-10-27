import AVFoundation

/// Speaks the check-in question. The delegate callback reports exactly once
/// per `speakAsk` call — on start, finish, or cancel, whichever comes first —
/// so the machine's 10 s clock always runs even if audio is interrupted.
protocol CheckInSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    func speakAsk(
        phrase: String, volume: Float,
        onStarted: @escaping () -> Void, onStopped: @escaping () -> Void
    )
    /// One-shot message (confirmations, status, help). Same callback rules.
    func speak(text: String, volume: Float, onStopped: @escaping () -> Void)
    func stop()
}

final class CheckInSpeaker: NSObject, CheckInSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var onStarted: (() -> Void)?
    private var onStopped: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speakAsk(
        phrase: String, volume: Float,
        onStarted: @escaping () -> Void, onStopped: @escaping () -> Void
    ) {
        fireStarted() // never leak previous callbacks
        fireStopped()
        self.onStarted = onStarted
        self.onStopped = onStopped
        synthesizer.speak(utterance(string: phrase, volume: volume))
    }

    func speak(text: String, volume: Float, onStopped: @escaping () -> Void) {
        fireStarted()
        fireStopped()
        self.onStopped = onStopped
        synthesizer.speak(utterance(string: text, volume: volume))
    }

    /// Hindi voice when the app runs in Hindi (nil on English keeps the
    /// system default). A missing Hindi voice falls back silently.
    private func utterance(string: String, volume: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: string)
        utterance.volume = volume
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let language = AppLanguage.speechVoiceLanguage {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        return utterance
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        fireStarted()
        fireStopped()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        fireStarted()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        fireStarted()
        fireStopped()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        fireStarted()
        fireStopped()
    }

    private func fireStarted() {
        let callback = onStarted
        onStarted = nil
        callback?()
    }

    private func fireStopped() {
        let callback = onStopped
        onStopped = nil
        callback?()
    }
}
