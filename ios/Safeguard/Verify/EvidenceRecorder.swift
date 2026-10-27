import AVFoundation
import CoreMedia
import Foundation

/// Records video and audio in short segments while an SOS runs and uploads
/// each closed segment at once, so evidence is already off the phone if the
/// phone is taken. Segments are 8 s; files are deleted after a successful
/// upload and kept (and retried later) if the backend cannot be reached.
///
/// Video comes from the camera frames the app already receives; audio from
/// the single microphone tap the listener owns. Nothing is recorded unless
/// `start` was called, which only an SOS does.
public final class EvidenceRecorder: @unchecked Sendable {
    public static let segmentSeconds: TimeInterval = 8

    private let queue = DispatchQueue(label: "app.safeguard.evidence")
    private let uploader: EvidenceUploader
    private let root: URL
    private var sessionID: String?
    private var progress = EvidenceProgress()
    private var onProgress: (@Sendable (EvidenceProgress) -> Void)?

    // Video segment state (queue-confined).
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoSegmentStart: CMTime?
    private var videoSeq = 0
    private var videoURL: URL?

    // Audio segment state (queue-confined).
    private var audioFile: AVAudioFile?
    private var audioURL: URL?
    private var audioSeq = 0
    private var audioSegmentStartedAt: Date?

    private let activeLock = NSLock()
    private var active = false

    public init(uploader: EvidenceUploader = EvidenceUploader(), root: URL? = nil) {
        self.uploader = uploader
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evidence", isDirectory: true)
    }

    public var isRecording: Bool { activeLock.withLock { active } }

    public func start(sessionID: String, onProgress: @escaping @Sendable (EvidenceProgress) -> Void) {
        let alreadyActive = activeLock.withLock { () -> Bool in
            defer { active = true }
            return active
        }
        guard !alreadyActive else { return }
        queue.async {
            self.sessionID = sessionID
            self.onProgress = onProgress
            self.progress = EvidenceProgress()
            self.videoSeq = 0
            self.audioSeq = 0
            try? FileManager.default.createDirectory(
                at: self.folder(for: sessionID), withIntermediateDirectories: true
            )
            onProgress(self.progress)
        }
    }

    /// Closes the open segments, uploads them, and stops recording.
    public func stop() {
        activeLock.withLock { active = false }
        queue.async {
            self.closeVideoSegment()
            self.closeAudioSegment()
            self.sessionID = nil
        }
    }

    // MARK: - Input

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else { return }
        queue.async {
            guard self.sessionID != nil else { return }
            if let start = self.videoSegmentStart,
               CMTimeGetSeconds(CMTimeSubtract(time, start)) >= Self.segmentSeconds
            {
                self.closeVideoSegment()
            }
            if self.writer == nil { self.openVideoSegment(for: pixelBuffer, at: time) }
            guard let input = self.videoInput, input.isReadyForMoreMediaData,
                  self.writer?.status == .writing
            else { return }
            self.adaptor?.append(pixelBuffer, withPresentationTime: time)
        }
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let copy = Self.copy(buffer) else { return }
        queue.async {
            guard self.sessionID != nil else { return }
            if let started = self.audioSegmentStartedAt,
               Date().timeIntervalSince(started) >= Self.segmentSeconds
            {
                self.closeAudioSegment()
            }
            if self.audioFile == nil { self.openAudioSegment(format: copy.format) }
            try? self.audioFile?.write(from: copy)
        }
    }

    // MARK: - Segments

    private func folder(for session: String) -> URL {
        root.appendingPathComponent(session, isDirectory: true)
    }

    private func openVideoSegment(for pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session = sessionID else { return }
        let url = folder(for: session).appendingPathComponent(
            EvidenceSegmentName.filename(kind: .video, seq: videoSeq)
        )
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(url: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
            AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil
        )
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = input
        self.adaptor = adaptor
        videoSegmentStart = time
        videoURL = url
    }

    private func closeVideoSegment() {
        guard let writer, let url = videoURL, let session = sessionID else { return }
        let seq = videoSeq
        videoSeq += 1
        self.writer = nil
        videoInput?.markAsFinished()
        videoInput = nil
        adaptor = nil
        videoSegmentStart = nil
        videoURL = nil
        writer.finishWriting { [self] in
            if writer.status == .completed {
                queue.async { self.finished(url: url, session: session, kind: .video, seq: seq) }
            }
        }
    }

    private func openAudioSegment(format: AVAudioFormat) {
        guard let session = sessionID else { return }
        let url = folder(for: session).appendingPathComponent(
            EvidenceSegmentName.filename(kind: .audio, seq: audioSeq)
        )
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        audioFile = try? AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        audioURL = url
        audioSegmentStartedAt = Date()
    }

    private func closeAudioSegment() {
        guard audioFile != nil, let url = audioURL, let session = sessionID else { return }
        let seq = audioSeq
        audioSeq += 1
        audioFile = nil // closing the file finalizes it
        audioURL = nil
        audioSegmentStartedAt = nil
        finished(url: url, session: session, kind: .audio, seq: seq)
    }

    /// A segment is closed on disk: count it and upload it.
    private func finished(url: URL, session: String, kind: EvidenceKind, seq: Int) {
        progress.segments += 1
        onProgress?(progress)
        let uploader = uploader
        Task.detached { [weak self] in
            let ok = await uploader.upload(file: url, sessionID: session, kind: kind, seq: seq)
            self?.queue.async {
                guard let self else { return }
                if ok {
                    try? FileManager.default.removeItem(at: url)
                    self.progress.uploaded += 1
                } else {
                    self.progress.failed += 1
                }
                self.onProgress?(self.progress)
            }
        }
    }

    // MARK: - Leftovers

    /// Uploads segments a previous SOS could not send (no connection, app
    /// closed mid-upload). Call at launch and when an SOS starts.
    public func retryPending() {
        queue.async {
            let fm = FileManager.default
            guard let sessions = try? fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) else { return }
            for folder in sessions where folder.lastPathComponent != self.sessionID {
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files {
                    guard let parsed = EvidenceSegmentName.parse(file.lastPathComponent) else { continue }
                    let uploader = self.uploader
                    let session = folder.lastPathComponent
                    Task.detached {
                        if await uploader.upload(file: file, sessionID: session, kind: parsed.kind, seq: parsed.seq) {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                }
            }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}
