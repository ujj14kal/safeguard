import Foundation

enum SetupPermission: String, CaseIterable, Identifiable {
    case camera
    case microphone
    case speech
    case location

    var id: String { rawValue }

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
