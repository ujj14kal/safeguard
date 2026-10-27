import Foundation

/// Builds Uber deep links for the SOS ride. No Uber account, API key or
/// SDK: the link opens the Uber app (or its web page) with the trip already
/// filled in, and the rider confirms there. Uber's deep links have no field
/// for a note to the driver, so the places' nicknames carry "SOS" instead.
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

    /// `uber://` link: opens the installed Uber app.
    public static func appURL(pickup: Place, dropoff: Place?) -> URL? {
        var components = URLComponents()
        components.scheme = "uber"
        components.host = ""
        components.queryItems = items(pickup: pickup, dropoff: dropoff)
        return components.url
    }

    /// `https://m.uber.com/ul/` link: the universal link, which opens the
    /// app when it is installed and the web page otherwise.
    public static func webURL(pickup: Place, dropoff: Place?) -> URL? {
        guard var components = URLComponents(string: "https://m.uber.com/ul/") else { return nil }
        components.queryItems = items(pickup: pickup, dropoff: dropoff)
        return components.url
    }
}
