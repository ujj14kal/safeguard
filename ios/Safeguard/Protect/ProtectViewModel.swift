import AVFoundation
import CoreImage
import SwiftUI

/// Protect tab model: owns the active FrameSource, keeps the screen awake
/// while protecting (foreground-only app), and surfaces frame flow + errors.
/// Detection arrives in Phase 2; for now camera frames are counted and discarded.
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

    // CIContext is Sendable; shared for off-main replay frame conversion.
    private nonisolated static let ciContext = CIContext()

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
        state = .idle
        statusLine = "Not protecting"
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
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFps() }
        }
    }

    private func tickFps() {
        let fps = framesReceived - lastFpsSample
        lastFpsSample = framesReceived
        let base = usingReplay ? "Replay mode: \(replayName ?? "video")" : "Monitoring with phone camera"
        statusLine = "\(base) • \(fps) fps"
    }

    private func publishReplayFrame(_ image: UIImage?) {
        if let image {
            replayImage = image
        }
        framesReceived += 1
    }

    private func countFrame() {
        framesReceived += 1
    }

    private func handleSourceError(_ message: String) {
        stop()
        errorMessage = message
    }
}

extension ProtectViewModel: FrameSourceDelegate {
    nonisolated func frameSource(_ source: any FrameSource, didOutput frame: SafeguardFrame) {
        if source is VideoFileSource {
            // Convert off-main, publish on main. Conversion is synchronous:
            // the pixel buffer is only valid for this call.
            let image = Self.makeImage(from: frame.pixelBuffer)
            Task { await self.publishReplayFrame(image) }
        } else {
            Task { await self.countFrame() }
        }
    }

    nonisolated func frameSource(_ source: any FrameSource, didFailWith error: Error) {
        let message = error.localizedDescription
        Task { await self.handleSourceError(message) }
    }

    nonisolated private static func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
