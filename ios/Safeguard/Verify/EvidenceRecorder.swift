import AVFoundation
import CoreMedia
import Foundation

public final class EvidenceRecorder: @unchecked Sendable {
    public static let segmentSeconds: TimeInterval = 4
    public static let frameInterval: TimeInterval = 1.0 / 15
    public static let videoBitRate = 900_000
    public static let maxVideoWidth = 960

    private let queue = DispatchQueue(label: "app.safeguard.evidence")
    private let uploader: EvidenceUploader
    private let root: URL
    private var sessionID: String?
    private var progress = EvidenceProgress()
    private var onProgress: (@Sendable (EvidenceProgress) -> Void)?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoSegmentStart: CMTime?
    private var videoSeq = 0
    private var videoURL: URL?
    private var lastVideoFrameTime: CMTime?

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
            self.lastVideoFrameTime = nil
            try? FileManager.default.createDirectory(
                at: self.folder(for: sessionID), withIntermediateDirectories: true
            )
            onProgress(self.progress)
        }
    }

    public func stop() {
        activeLock.withLock { active = false }
        queue.async {
            self.closeVideoSegment()
            self.closeAudioSegment()
            self.sessionID = nil
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else { return }
        queue.async {
            guard self.sessionID != nil else { return }
            if let last = self.lastVideoFrameTime,
               CMTimeGetSeconds(CMTimeSubtract(time, last)) < Self.frameInterval * 0.9
            {
                return
            }
            self.lastVideoFrameTime = time
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
        let size = Self.outputSize(
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 15,
            ],
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

    static func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > maxVideoWidth else { return (width & ~1, height & ~1) }
        let scale = Double(maxVideoWidth) / Double(width)
        return (maxVideoWidth, Int((Double(height) * scale).rounded()) & ~1)
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
        audioFile = nil
        audioURL = nil
        audioSegmentStartedAt = nil
        finished(url: url, session: session, kind: .audio, seq: seq)
    }

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
