@preconcurrency import AVFoundation

final class PhoneCameraSource: NSObject, FrameSource {
    weak var delegate: (any FrameSourceDelegate)?
    var isRunning: Bool { session.isRunning }
    let displayName = "Phone camera"

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "app.safeguard.camera", qos: .userInitiated)
    private var observers: [any NSObjectProtocol] = []
    private var device: AVCaptureDevice?

    deinit { removeObservers() }

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

        self.device = device
        try configure(with: device)
        addObservers()
        let session = session
        queue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    private func configure(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
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

        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90)
        {
            connection.videoRotationAngle = 90
        }
    }

    var maxZoom: CGFloat {
        guard let device else { return 1 }
        return min(device.maxAvailableVideoZoomFactor, 6)
    }

    var zoomFactor: CGFloat { device?.videoZoomFactor ?? 1 }

    func setZoom(_ factor: CGFloat, ramp: Bool) {
        guard let device else { return }
        let target = max(1, min(factor, maxZoom))
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if ramp {
            device.ramp(toVideoZoomFactor: target, withRate: 3)
        } else {
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
        }
    }

    func focus(onUprightPoint point: CGPoint) {
        guard let device else { return }
        let sensor = CGPoint(x: min(max(1 - point.y, 0), 1), y: min(max(1 - point.x, 0), 1))
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = sensor
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = sensor
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    func stop() {
        removeObservers()
        let session = session
        queue.async { session.stopRunning() }
    }

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
