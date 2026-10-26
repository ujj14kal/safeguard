import AVFoundation
import CoreImage
import SwiftUI

/// Protect tab model: owns the active FrameSource, runs the detect-then-track
/// pipeline on a serial queue, keeps the screen awake while protecting
/// (foreground-only app), and surfaces frame flow + errors.
@MainActor
final class ProtectViewModel: ObservableObject {
    @Published var state: ProtectionState = .idle
    @Published var usingReplay = false
    @Published var replayName: String?
    @Published var replayImage: UIImage?
    @Published var cameraSession: AVCaptureSession?
    @Published var statusLine = "Not protecting"
    @Published var errorMessage: String?
    @Published var showingPicker = false
    @Published var debugTracks: [Track] = []
    @Published var debugFrameSize: CGSize = .zero
    @Published var debugScores: [Int: Double] = [:]
    @Published var personCount = 0

    // CIContext is Sendable; shared for off-main replay frame conversion.
    fileprivate nonisolated static let ciContext = CIContext()

    /// Serial queue for the whole detection pipeline (render + detect + track).
    private nonisolated let detectionQueue = DispatchQueue(
        label: "app.safeguard.detection", qos: .userInitiated
    )

    /// Pipeline state. Confined to `detectionQueue` by convention: every
    /// access runs on that queue (delegate callbacks funnel through it;
    /// resets use `sync`).
    private nonisolated(unsafe) let pipeline = DetectionPipeline()

    // Frames arrive on a background queue. A lock-based counter avoids spawning
    // a Task per frame, and the gate drops frames while the previous one is
    // still being handled (no unbounded backlog at 30 fps).
    private nonisolated let frameCounter = FrameCounter()
    private nonisolated let pipelineGate = ConversionGate()

    private var source: (any FrameSource)?
    private var lastFpsSample = 0
    private var fpsTimer: Timer?

    var isProtecting: Bool { state == .monitoring }

    func startCamera() async {
        errorMessage = nil
        guard await PhoneCameraSource.requestPermission() else {
            errorMessage = FrameSourceError.permissionDenied.localizedDescription
            return
        }
        do {
            let camera = PhoneCameraSource()
            camera.delegate = self
            try camera.start()
            source = camera
            cameraSession = camera.captureSession
            usingReplay = false
            replayName = nil
            state = .monitoring
            beginSession(status: "Monitoring with phone camera")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startReplay(url: URL) {
        errorMessage = nil
        do {
            let replay = VideoFileSource(url: url)
            replay.delegate = self
            try replay.start()
            source = replay
            cameraSession = nil
            usingReplay = true
            replayName = url.lastPathComponent
            state = .monitoring
            beginSession(status: "Replay mode: \(url.lastPathComponent)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        source?.stop()
        source = nil
        cameraSession = nil
        replayImage = nil
        debugTracks = []
        personCount = 0
        state = .idle
        statusLine = "Not protecting"
        debugScores = [:]
        detectionQueue.sync { pipeline.reset() }
        UIApplication.shared.isIdleTimerDisabled = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    private func beginSession(status: String) {
        statusLine = status
        // Foreground-only app: keep the screen awake while protecting.
        UIApplication.shared.isIdleTimerDisabled = true
        frameCounter.reset()
        lastFpsSample = 0
        personCount = 0
        debugTracks = []
        debugScores = [:]
        detectionQueue.sync { pipeline.reset() }
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFps() }
        }
    }

    private func tickFps() {
        let total = frameCounter.value
        let fps = total - lastFpsSample
        lastFpsSample = total
        let base = usingReplay ? "Replay mode: \(replayName ?? "video")" : "Monitoring with phone camera"
        let people = personCount == 1 ? "1 person" : "\(personCount) people"
        statusLine = "\(base) • \(fps) fps • \(people)"
    }

    fileprivate func publishReplayFrame(_ image: UIImage?) {
        // A frame still in flight when stop() ran must not repaint the screen.
        guard isProtecting else { return }
        if let image {
            replayImage = image
        }
    }

    fileprivate func publishDetection(tracks: [Track], frameSize: CGSize, scores: [Int: Double]) {
        guard isProtecting else { return }
        debugTracks = tracks
        debugFrameSize = frameSize
        debugScores = scores
        personCount = tracks.count
    }

    private func handleSourceError(_ message: String) {
        stop()
        errorMessage = message
    }
}

/// Detection pipeline state: frame render, throttled Vision detection, IoU
/// tracking. All methods run on the view model's `detectionQueue`.
private final class DetectionPipeline {
    let config: ThreatConfig
    let detector: PersonDetector
    let tracker = IoUTracker()
    let extractor: FeatureExtractor
    let scorer: ThreatScorer
    var lastDetect = Date.distantPast
    let detectInterval: TimeInterval = 0.2

    init(config: ThreatConfig = ThreatConfig()) {
        self.config = config
        self.detector = PersonDetector(poseMatchDistance: config.poseMatchDistance)
        self.extractor = FeatureExtractor(config: config)
        self.scorer = ThreatScorer(config: config)
    }

    func reset() {
        tracker.reset()
        extractor.reset()
    }

    func handleFrame(_ frame: SafeguardFrame, isReplay: Bool, owner: ProtectViewModel) {
        if isReplay {
            let image = Self.makeImage(from: frame.pixelBuffer)
            Task { await owner.publishReplayFrame(image) }
        }

        let now = Date()
        guard now.timeIntervalSince(lastDetect) >= detectInterval else { return }
        lastDetect = now
        guard let people = try? detector.detect(in: frame.pixelBuffer) else { return }
        let tracks = tracker.update(detections: people)
        let live = tracks.filter { $0.missed == 0 }
        let nowSeconds = ProcessInfo.processInfo.systemUptime
        extractor.update(tracks: live, at: nowSeconds)
        var scores: [Int: Double] = [:]
        for track in live {
            if let features = extractor.features(for: track.id, at: nowSeconds) {
                scores[track.id] = scorer.score(features).value
            }
        }
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        Task { await owner.publishDetection(tracks: live, frameSize: size, scores: scores) }
    }

    nonisolated private static func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ProtectViewModel.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

extension ProtectViewModel: FrameSourceDelegate {
    nonisolated func frameSource(_ source: any FrameSource, didOutput frame: SafeguardFrame) {
        frameCounter.increment()
        // Drop frames while one is still being handled: bounds the queue
        // and the detection work under a 30 fps source.
        guard pipelineGate.tryEnter() else { return }
        let isReplay = source is VideoFileSource
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.pipeline.handleFrame(frame, isReplay: isReplay, owner: self)
            self.pipelineGate.leave()
        }
    }

    nonisolated func frameSource(_ source: any FrameSource, didFailWith error: Error) {
        let message = error.localizedDescription
        Task { await self.handleSourceError(message) }
    }
}

/// Thread-safe frame counter shared between the capture queue and the main actor.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

/// Lets one frame be handled at a time; later frames are dropped until the
/// previous one finishes.
private final class ConversionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func tryEnter() -> Bool {
        lock.withLock {
            if busy { return false }
            busy = true
            return true
        }
    }

    func leave() { lock.withLock { busy = false } }
}
