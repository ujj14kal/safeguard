import Foundation

/// Indian emergency and women's helplines, and the Apple Maps searches for
/// help nearby. The app never dials by itself: these only open the phone
/// or Maps when the person taps.
public enum Helplines {
    public struct Line: Equatable, Sendable {
        public let number: String
        public let titleKey: String
    }

    public static let police = Line(number: "112", titleKey: "Call police (112)")
    public static let women = Line(number: "1091", titleKey: "Women helpline (1091)")
    public static let domesticAbuse = Line(number: "181", titleKey: "Women in distress (181)")

    public static let all: [Line] = [police, women, domesticAbuse]

    public static func dialURL(_ line: Line) -> URL? {
        URL(string: "tel:\(line.number)")
    }

    public enum Place: String, Sendable {
        case police = "police station"
        case hospital = "hospital"
    }

    /// Opens Apple Maps with a search around the person's current location.
    public static func mapsURL(for place: Place) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: place.rawValue)]
        return components?.url
    }
}
