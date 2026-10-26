import AVFoundation

/// Replay mode: feeds a recorded video file through the same pipeline as the
/// camera. Used for development and demos (the Simulator has no camera).
/// Loops by default. Frames are paced at the clip's nominal frame rate.
final class VideoFileSource: NSObject, FrameSource {
    weak var delegate: (any FrameSourceDelegate)?
    let displayName = "Replay"
    var loops = true

    var isRunning: Bool { stateLock.withLock { _isRunning } }

    private let url: URL
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _stopped = false
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        super.init()
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FrameSourceError.fileNotFound(url)
        }
        stateLock.withLock {
            _isRunning = true
            _stopped = false
        }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        stateLock.withLock {
            _isRunning = false
            _stopped = true
        }
        task?.cancel()
        task = nil
    }

    private var stopped: Bool { stateLock.withLock { _stopped } }

    private func run() async {
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack?
        do {
            track = try await asset.loadTracks(withMediaType: .video).first
        } catch {
            fail(.readerFailed(error.localizedDescription))
            return
        }
        guard let track else {
            fail(.noVideoTrack(url))
            return
        }
        let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let fps = nominalRate > 0 ? Double(nominalRate) : 30

        repeat {
            do {
                let frames = try await playOnce(asset: asset, track: track, fps: fps)
                // A pass that yields nothing would otherwise loop hot forever.
                if frames == 0 && !stopped {
                    fail(.readerFailed("The video contains no frames."))
                    return
                }
            } catch {
                fail(.readerFailed(error.localizedDescription))
                return
            }
        } while loops && !stopped
        stateLock.withLock { _isRunning = false }
    }

    /// Plays the clip once; returns how many frames were delivered.
    private func playOnce(asset: AVAsset, track: AVAssetTrack, fps: Double) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else {
            throw FrameSourceError.readerFailed("cannot add track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FrameSourceError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        let intervalNs = UInt64(1_000_000_000.0 / max(fps, 1))
        var delivered = 0
        while !stopped {
            guard let sample = output.copyNextSampleBuffer() else { break }
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                delegate?.frameSource(
                    self, didOutput: SafeguardFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
                )
                delivered += 1
            }
            CMSampleBufferInvalidate(sample)
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        if reader.status == .failed {
            throw FrameSourceError.readerFailed(reader.error?.localizedDescription ?? "read failed")
        }
        return delivered
    }

    private func fail(_ error: FrameSourceError) {
        stateLock.withLock { _isRunning = false }
        delegate?.frameSource(self, didFailWith: error)
    }
}
