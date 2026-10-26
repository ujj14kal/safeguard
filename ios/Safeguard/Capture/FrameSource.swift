import AVFoundation
import CoreMedia
import CoreVideo

/// A timestamped video frame held in memory only. Frames are never stored;
/// consumers must process and discard them. The pixel buffer is valid only
/// for the duration of the delegate call — copy or convert synchronously.
struct SafeguardFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
}

protocol FrameSourceDelegate: AnyObject {
    /// Called on the source's internal background queue. Hop to main for UI.
    func frameSource(_ source: any FrameSource, didOutput frame: SafeguardFrame)
    func frameSource(_ source: any FrameSource, didFailWith error: Error)
}

/// Produces timestamped frames for the detection pipeline.
/// Implementations: PhoneCameraSource, VideoFileSource (Replay), GlassesSource (stub).
protocol FrameSource: AnyObject {
    var delegate: (any FrameSourceDelegate)? { get set }
    var isRunning: Bool { get }
    var displayName: String { get }

    /// Validates synchronously where possible (e.g. missing file) and throws.
    /// Failures discovered during async setup or streaming arrive via didFailWith.
    func start() throws
    func stop()
}

enum FrameSourceError: Error, LocalizedError {
    case cameraUnavailable
    case permissionDenied
    case configurationFailed(String)
    case fileNotFound(URL)
    case noVideoTrack(URL)
    case readerFailed(String)
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "No camera is available on this device."
        case .permissionDenied:
            "Camera access was denied. Enable it in Settings to start protecting."
        case .configurationFailed(let detail):
            "Could not configure capture: \(detail)"
        case .fileNotFound(let url):
            "Replay file not found: \(url.lastPathComponent)"
        case .noVideoTrack(let url):
            "No video track in \(url.lastPathComponent)"
        case .readerFailed(let detail):
            "Could not read replay file: \(detail)"
        case .notAvailable(let detail):
            detail
        }
    }
}
