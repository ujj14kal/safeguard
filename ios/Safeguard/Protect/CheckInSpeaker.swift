import AVFoundation

/// Speaks the check-in question. The delegate callback reports exactly once
/// per `speakAsk` call — on start, finish, or cancel, whichever comes first —
/// so the machine's 10 s clock always runs even if audio is interrupted.
protocol CheckInSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    func speakAsk(phrase: String, volume: Float, onStarted: @escaping () -> Void)
    func stop()
}

final class CheckInSpeaker: NSObject, CheckInSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var onStarted: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speakAsk(phrase: String, volume: Float, onStarted: @escaping () -> Void) {
        fireStarted() // never leak a previous callback
        self.onStarted = onStarted
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.volume = volume
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        fireStarted()
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
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        fireStarted()
    }

    private func fireStarted() {
        let callback = onStarted
        onStarted = nil
        callback?()
    }
}
