import AVFoundation
import CoreLocation
import Speech
import SwiftUI

/// The four setup permissions, each asked with its reason first.
enum SetupPermission: String, CaseIterable, Identifiable {
    case camera
    case microphone
    case speech
    case location

    var id: String { rawValue }

    /// Pre-localised: used both as a label and inside formatted strings.
    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .speech: String(localized: "Speech recognition")
        case .location: String(localized: "Location (while using the app)")
        }
    }

    var reason: String {
        switch self {
        case .camera:
            String(localized: "To watch for threatening behaviour by people nearby.")
        case .microphone:
            String(localized: "To hear your answers, distress words and shouting.")
        case .speech:
            String(localized: "To turn speech into text, on this phone only.")
        case .location:
            String(localized: "To share your location with your contacts during an SOS only.")
        }
    }

    /// Honest warning chip when denied.
    var missingImpact: String {
        switch self {
        case .camera: String(localized: "Without the camera, Safeguard cannot watch for threats.")
        case .microphone: String(localized: "Without the microphone, voice answers and distress words will not work.")
        case .speech: String(localized: "Without speech recognition, voice features will not work.")
        case .location: String(localized: "Without location, the SOS route and live location will not work.")
        }
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notAsked
}

/// Reads and requests the four system permissions. Status only — the views
/// decide what to show.
enum SetupPermissions {
    static func status(of permission: SetupPermission) -> PermissionStatus {
        switch permission {
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notAsked
            @unknown default: return .notAsked
            }
        case .speech:
            return map(SFSpeechRecognizer.authorizationStatus())
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notAsked
            @unknown default: return .notAsked
            }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    /// Asks one permission (the system prompt). Location has no callback —
    /// the view re-checks when the app returns to the foreground.
    static func request(_ permission: SetupPermission) async {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { _ in
                    continuation.resume()
                }
            }
        case .speech:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .location:
            await MainActor.run {
                ProtectViewModel.shared.requestLocationPermission()
            }
        }
    }
}
