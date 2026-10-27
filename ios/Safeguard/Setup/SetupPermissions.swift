import AVFoundation
import CoreLocation
import Speech
import SwiftUI

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
