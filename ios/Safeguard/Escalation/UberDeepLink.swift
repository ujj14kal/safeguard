import Foundation

public enum UberDeepLink {
    public struct Place: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var nickname: String

        public init(latitude: Double, longitude: Double, nickname: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.nickname = nickname
        }
    }

    private static func items(pickup: Place, dropoff: Place?) -> [URLQueryItem] {
        var out = [
            URLQueryItem(name: "action", value: "setPickup"),
            URLQueryItem(name: "pickup[latitude]", value: String(format: "%.5f", pickup.latitude)),
            URLQueryItem(name: "pickup[longitude]", value: String(format: "%.5f", pickup.longitude)),
            URLQueryItem(name: "pickup[nickname]", value: pickup.nickname),
        ]
        if let dropoff {
            out += [
                URLQueryItem(name: "dropoff[latitude]", value: String(format: "%.5f", dropoff.latitude)),
                URLQueryItem(name: "dropoff[longitude]", value: String(format: "%.5f", dropoff.longitude)),
                URLQueryItem(name: "dropoff[nickname]", value: dropoff.nickname),
            ]
        }
        return out
    }

    public static func appURL(pickup: Place, dropoff: Place?) -> URL? {
        var components = URLComponents()
        components.scheme = "uber"
        components.host = ""
        components.queryItems = items(pickup: pickup, dropoff: dropoff)
        return components.url
    }

    public static func webURL(pickup: Place, dropoff: Place?) -> URL? {
        guard var components = URLComponents(string: "https://m.uber.com/ul/") else { return nil }
        components.queryItems = items(pickup: pickup, dropoff: dropoff)
        return components.url
    }
}
