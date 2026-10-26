@preconcurrency import AVFoundation

/// World-facing phone camera source. First-person use: phone in a chest or
/// collar mount. Frames are BGRA pixel buffers delivered on a capture queue.
final class PhoneCameraSource: NSObject, FrameSource {
    weak var delegate: (any FrameSourceDelegate)?
    var isRunning: Bool { session.isRunning }
    let displayName = "Phone camera"

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "app.safeguard.camera", qos: .userInitiated)
    private var observers: [any NSObjectProtocol] = []

    deinit { removeObservers() }

    /// Exposed so SwiftUI can attach an AVCaptureVideoPreviewLayer.
    var captureSession: AVCaptureSession { session }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        default:
            false
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw FrameSourceError.permissionDenied
        }
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) ?? AVCaptureDevice.default(for: .video) else {
            throw FrameSourceError.cameraUnavailable
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw FrameSourceError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw FrameSourceError.configurationFailed("cannot add camera input")
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw FrameSourceError.configurationFailed("cannot add video output")
        }
        session.addOutput(output)

        // Deliver upright portrait buffers. Without this the back camera hands
        // Vision landscape buffers even though the app is portrait-only, and
        // detection would see people sideways. (The preview layer hides this.)
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90)
        {
            connection.videoRotationAngle = 90
        }

        addObservers()
        let session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        removeObservers()
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Protection must never look active when the camera is not delivering
    /// frames: report runtime errors and interruptions (call, other app) so the
    /// model stops and tells the user.
    private func addObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.report(.configurationFailed(error?.localizedDescription ?? "camera runtime error"))
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { [weak self] _ in
                self?.report(.notAvailable(
                    "The camera was interrupted, so protection stopped. Start protecting again when ready."
                ))
            },
        ]
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func report(_ error: FrameSourceError) {
        delegate?.frameSource(self, didFailWith: error)
    }
}

extension PhoneCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.frameSource(
            self, didOutput: SafeguardFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        )
    }
}
