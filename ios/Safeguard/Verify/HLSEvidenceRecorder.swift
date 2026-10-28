import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

public final class HLSEvidenceRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    public static let pieceSeconds: Double = 2
    private static let framesToWaitForAudio = 45

    private let queue = DispatchQueue(label: "app.safeguard.evidence.hls")
    private let uploader: EvidenceUploader
    private let root: URL

    private let activeLock = NSLock()
    private var active = false

    private var sessionID: String?
    private var progress = EvidenceProgress()
    private var onProgress: (@Sendable (EvidenceProgress) -> Void)?
    private var onFailure: (@Sendable () -> Void)?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: AVAudioFormat?
    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime?
    private var framesWaitingForAudio = 0
    private var pieceSeq = 0
    private var failed = false

    public init(uploader: EvidenceUploader = EvidenceUploader(), root: URL? = nil) {
        self.uploader = uploader
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evidence", isDirectory: true)
    }

    public var isRecording: Bool { activeLock.withLock { active } }

    public func start(
        sessionID: String,
        onProgress: @escaping @Sendable (EvidenceProgress) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        let alreadyActive = activeLock.withLock { () -> Bool in
            defer { active = true }
            return active
        }
        guard !alreadyActive else { return }
        queue.async {
            self.sessionID = sessionID
            self.onProgress = onProgress
            self.onFailure = onFailure
            self.progress = EvidenceProgress()
            self.writer = nil
            self.videoInput = nil
            self.adaptor = nil
            self.audioInput = nil
            self.audioFormat = nil
            self.sessionStart = nil
            self.lastVideoTime = nil
            self.framesWaitingForAudio = 0
            self.pieceSeq = 0
            self.failed = false
            try? FileManager.default.createDirectory(
                at: self.folder(for: sessionID), withIntermediateDirectories: true
            )
            onProgress(self.progress)
        }
    }

    public func stop() {
        activeLock.withLock { active = false }
        queue.async {
            guard let writer = self.writer, writer.status == .writing else {
                self.sessionID = nil
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                self.queue.async { self.sessionID = nil }
            }
            self.writer = nil
        }
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else { return }
        queue.async {
            guard self.sessionID != nil, !self.failed else { return }
            if let last = self.lastVideoTime,
               CMTimeGetSeconds(CMTimeSubtract(time, last)) < EvidenceRecorder.frameInterval * 0.9
            {
                return
            }
            if self.writer == nil {
                if self.audioFormat == nil, self.framesWaitingForAudio < Self.framesToWaitForAudio {
                    self.framesWaitingForAudio += 1
                    return
                }
                self.openWriter(for: pixelBuffer, at: time)
            }
            guard let input = self.videoInput, input.isReadyForMoreMediaData,
                  self.writer?.status == .writing
            else {
                self.checkWriter()
                return
            }
            self.lastVideoTime = time
            self.adaptor?.append(pixelBuffer, withPresentationTime: time)
        }
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime) {
        guard isRecording, let copy = Self.copy(buffer) else { return }
        let hostTime = audioTime.hostTime
        queue.async {
            guard self.sessionID != nil, !self.failed else { return }
            if self.audioFormat == nil { self.audioFormat = copy.format }
            guard let input = self.audioInput, input.isReadyForMoreMediaData,
                  self.writer?.status == .writing, let start = self.sessionStart
            else { return }
            let seconds = AVAudioTime.seconds(forHostTime: hostTime)
            let pts = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            let length = CMTime(seconds: Double(copy.frameLength) / copy.format.sampleRate, preferredTimescale: 1_000_000_000)
            guard CMTimeAdd(pts, length) > start else { return }
            if let sample = Self.sampleBuffer(from: copy, at: pts) {
                input.append(sample)
            }
        }
    }

    private func folder(for session: String) -> URL {
        root.appendingPathComponent(session, isDirectory: true)
    }

    private func openWriter(for pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard sessionID != nil else { return }
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.pieceSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = time
        writer.delegate = self

        let size = EvidenceRecorder.outputSize(
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: EvidenceRecorder.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalDurationKey: Self.pieceSeconds,
                AVVideoExpectedSourceFrameRateKey: 15,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil
        )
        guard writer.canAdd(video) else { fail("cannot add video input"); return }
        writer.add(video)

        if let format = audioFormat {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: min(Int(format.channelCount), 2),
                AVEncoderBitRateKey: 64_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }

        guard writer.startWriting() else {
            fail("startWriting: \(writer.error?.localizedDescription ?? "?")")
            return
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = video
        self.adaptor = adaptor
        sessionStart = time
    }

    private func checkWriter() {
        if let writer, writer.status == .failed {
            fail("writer failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        NSLog("HLSEvidenceRecorder: %@", reason)
        AppLog.shared.event("evidence_stream_failed", ["reason": String(reason.prefix(120))])
        writer = nil
        let callback = onFailure
        DispatchQueue.main.async { callback?() }
    }

    public func assetWriter(
        _ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?
    ) {
        queue.async {
            guard let session = self.sessionID else { return }
            let kind: EvidenceKind
            var seq = 0
            var durationMs: Int?
            switch segmentType {
            case .initialization:
                kind = .initSegment
            case .separable:
                kind = .mediaSegment
                self.pieceSeq += 1
                seq = self.pieceSeq
                let seconds = segmentReport?.trackReports
                    .map { CMTimeGetSeconds($0.duration) }.max() ?? Self.pieceSeconds
                durationMs = max(100, min(20_000, Int((seconds * 1000).rounded())))
            @unknown default:
                return
            }
            let url = self.folder(for: session).appendingPathComponent(
                EvidenceSegmentName.filename(kind: kind, seq: seq, durationMs: durationMs)
            )
            do {
                try segmentData.write(to: url, options: .atomic)
            } catch {
                self.progress.failed += 1
                self.onProgress?(self.progress)
                return
            }
            self.pieceUploaded(url: url, session: session, kind: kind, seq: seq, durationMs: durationMs)
        }
    }

    private func pieceUploaded(
        url: URL, session: String, kind: EvidenceKind, seq: Int, durationMs: Int?
    ) {
        progress.segments += 1
        onProgress?(progress)
        let uploader = uploader
        Task.detached { [weak self] in
            let ok = await uploader.upload(
                file: url, sessionID: session, kind: kind, seq: seq, durationMs: durationMs
            )
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
                    guard let parsed = EvidenceSegmentName.parseAny(file.lastPathComponent),
                          parsed.kind == .initSegment || parsed.kind == .mediaSegment
                    else { continue }
                    let uploader = self.uploader
                    let session = folder.lastPathComponent
                    Task.detached {
                        if await uploader.upload(
                            file: file, sessionID: session, kind: parsed.kind,
                            seq: parsed.seq, durationMs: parsed.durationMs
                        ) {
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

    static func sampleBuffer(from buffer: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var description = buffer.format.streamDescription.pointee
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(description.mSampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }
}
