import AVFoundation
import CoreMedia
import CoreVideo

struct SafeguardFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
}

protocol FrameSourceDelegate: AnyObject {
    func frameSource(_ source: any FrameSource, didOutput frame: SafeguardFrame)
    func frameSource(_ source: any FrameSource, didFailWith error: Error)
}

protocol FrameSource: AnyObject {
    var delegate: (any FrameSourceDelegate)? { get set }
    var isRunning: Bool { get }
    var displayName: String { get }

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
            String(localized: "No camera is available on this device.")
        case .permissionDenied:
            String(localized: "Camera access was denied. Enable it in Settings to start protecting.")
        case .configurationFailed(let detail):
            L10n.format("Could not configure capture: %@", detail)
        case .fileNotFound(let url):
            L10n.format("Replay file not found: %@", url.lastPathComponent)
        case .noVideoTrack(let url):
            L10n.format("No video track in %@", url.lastPathComponent)
        case .readerFailed(let detail):
            L10n.format("Could not read replay file: %@", detail)
        case .notAvailable(let detail):
            detail
        }
    }
}
