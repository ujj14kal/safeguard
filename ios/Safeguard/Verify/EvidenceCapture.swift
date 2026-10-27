import AVFoundation
import CoreMedia
import Foundation

/// What records an SOS: the continuous stream (video and sound in one
/// recording) by default, with the older separate-parts recorder as a safety
/// net. If the stream writer breaks mid-SOS, recording carries on in parts
/// for the rest of the session, so evidence is never lost to the new format.
public final class EvidenceCapture: @unchecked Sendable {
    public enum Mode: Equatable, Sendable { case stream, parts }

    private let stream: HLSEvidenceRecorder
    private let parts: EvidenceRecorder
    private let lock = NSLock()
    private var mode: Mode
    private var onProgress: (@Sendable (EvidenceProgress) -> Void)?
    private var sessionID: String?

    public init(
        preferred: Mode = .stream,
        stream: HLSEvidenceRecorder = HLSEvidenceRecorder(),
        parts: EvidenceRecorder = EvidenceRecorder()
    ) {
        self.mode = preferred
        self.stream = stream
        self.parts = parts
    }

    public var currentMode: Mode { lock.withLock { mode } }

    public var isRecording: Bool { stream.isRecording || parts.isRecording }

    public func start(sessionID: String, onProgress: @escaping @Sendable (EvidenceProgress) -> Void) {
        let chosen = lock.withLock { () -> Mode in
            self.onProgress = onProgress
            self.sessionID = sessionID
            return mode
        }
        switch chosen {
        case .stream:
            stream.start(sessionID: sessionID, onProgress: onProgress) { [weak self] in
                self?.fallBackToParts()
            }
        case .parts:
            parts.start(sessionID: sessionID, onProgress: onProgress)
        }
    }

    public func stop() {
        stream.stop()
        parts.stop()
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        if currentMode == .stream {
            stream.appendVideo(pixelBuffer, at: time)
        } else {
            parts.appendVideo(pixelBuffer, at: time)
        }
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        if currentMode == .stream {
            stream.appendAudio(buffer, at: time)
        } else {
            parts.appendAudio(buffer)
        }
    }

    /// Uploads whatever an earlier recording could not send (both formats).
    public func retryPending() {
        stream.retryPending()
        parts.retryPending()
    }

    private func fallBackToParts() {
        let (callback, session) = lock.withLock { () -> ((@Sendable (EvidenceProgress) -> Void)?, String?) in
            mode = .parts
            return (onProgress, sessionID)
        }
        stream.stop()
        guard let callback, let session, !parts.isRecording else { return }
        // Same session id: the guardian page shows the parts of whichever
        // format the server holds for it.
        parts.start(sessionID: session, onProgress: callback)
    }
}
