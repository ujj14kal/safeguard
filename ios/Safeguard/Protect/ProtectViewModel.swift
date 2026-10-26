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

    private var source: (any FrameSource)?
    private var framesReceived = 0
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
        detectionQueue.sync { pipeline.tracker.reset() }
        UIApplication.shared.isIdleTimerDisabled = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    private func beginSession(status: String) {
        statusLine = status
        // Foreground-only app: keep the screen awake while protecting.
        UIApplication.shared.isIdleTimerDisabled = true
        framesReceived = 0
        lastFpsSample = 0
        personCount = 0
        debugTracks = []
        detectionQueue.sync { pipeline.tracker.reset() }
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFps() }
        }
    }

    private func tickFps() {
        let fps = framesReceived - lastFpsSample
        lastFpsSample = framesReceived
        let base = usingReplay ? "Replay mode: \(replayName ?? "video")" : "Monitoring with phone camera"
        let people = personCount == 1 ? "1 person" : "\(personCount) people"
        statusLine = "\(base) • \(fps) fps • \(people)"
    }

    fileprivate func publishReplayFrame(_ image: UIImage?) {
        if let image {
            replayImage = image
        }
        framesReceived += 1
    }

    fileprivate func countFrame() {
        framesReceived += 1
    }

    fileprivate func publishDetection(tracks: [Track], frameSize: CGSize) {
        debugTracks = tracks
        debugFrameSize = frameSize
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
    let detector = PersonDetector()
    let tracker = IoUTracker()
    var lastDetect = Date.distantPast
    let detectInterval: TimeInterval = 0.2

    func handleFrame(_ frame: SafeguardFrame, isReplay: Bool, owner: ProtectViewModel) {
        if isReplay {
            let image = Self.makeImage(from: frame.pixelBuffer)
            Task { await owner.publishReplayFrame(image) }
        } else {
            Task { await owner.countFrame() }
        }

        let now = Date()
        guard now.timeIntervalSince(lastDetect) >= detectInterval else { return }
        lastDetect = now
        guard let people = try? detector.detect(in: frame.pixelBuffer) else { return }
        let tracks = tracker.update(detections: people)
        let live = tracks.filter { $0.missed == 0 }
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        Task { await owner.publishDetection(tracks: live, frameSize: size) }
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
        let isReplay = source is VideoFileSource
        detectionQueue.async { [weak self] in
            guard let self else { return }
            self.pipeline.handleFrame(frame, isReplay: isReplay, owner: self)
        }
    }

    nonisolated func frameSource(_ source: any FrameSource, didFailWith error: Error) {
        let message = error.localizedDescription
        Task { await self.handleSourceError(message) }
    }
}
