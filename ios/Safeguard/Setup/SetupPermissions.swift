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

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speech: "Speech recognition"
        case .location: "Location (while using the app)"
        }
    }

    var reason: String {
        switch self {
        case .camera:
            "To watch for threatening behaviour by people nearby."
        case .microphone:
            "To hear your answers, distress words and shouting."
        case .speech:
            "To turn speech into text, on this phone only."
        case .location:
            "To share your location with your contacts during an SOS only."
        }
    }

    /// Honest warning chip when denied.
    var missingImpact: String {
        switch self {
        case .camera: "Without the camera, Safeguard cannot watch for threats."
        case .microphone: "Without the microphone, voice answers and distress words will not work."
        case .speech: "Without speech recognition, voice features will not work."
        case .location: "Without location, the SOS route and live location will not work."
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
