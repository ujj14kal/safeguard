import Foundation

public struct VerifyFeatureSummary: Sendable, Equatable, Codable {
    public var trackID: Int
    public var score: Double
    public var reasons: [String]
    public var trend: Double
    public var speed: Double
    public var persistence: Double
    public var facing: Double
    public var isolation: Double
    public var blocking: Double
    public var cornering: Double
    public var speech: Double
    public var hostileGesture: Double?
    public var angryFace: Double?
    public var shouting: Double?

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case score, reasons, trend, speed, persistence, facing, isolation, blocking, cornering
        case speech
        case hostileGesture = "hostile_gesture"
        case angryFace = "angry_face"
        case shouting
    }

    public init(track: Track, features: PersonFeatures, score: Double, reasons: [String]) {
        self.trackID = track.id
        self.score = score
        self.reasons = reasons
        self.trend = features.trend
        self.speed = features.speed
        self.persistence = features.persistence
        self.facing = features.facing
        self.isolation = features.isolation
        self.blocking = features.blocking
        self.cornering = features.cornering
        self.speech = features.speech
        self.hostileGesture = features.hostileGesture > 0 ? features.hostileGesture : nil
        self.angryFace = features.angryFace > 0 ? features.angryFace : nil
        self.shouting = features.shouting > 0 ? features.shouting : nil
    }
}

public struct VerifyPayload: Sendable {
    public var frames: [Data]
    public var boxes: [[Double]]
    public var features: [VerifyFeatureSummary]

    public init(frames: [Data], boxes: [[Double]], features: [VerifyFeatureSummary]) {
        self.frames = frames
        self.boxes = boxes
        self.features = features
    }

    public static func pixelBoxes(_ boxes: [CGRect], in size: CGSize) -> [[Double]] {
        boxes.map { box in
            [
                Double(box.minX) * Double(size.width),
                (1 - Double(box.maxY)) * Double(size.height),
                Double(box.maxX) * Double(size.width),
                (1 - Double(box.minY)) * Double(size.height),
            ]
        }
    }
}

public struct SpeechVerifyResult: Sendable, Equatable {
    public var severity: String
    public var categories: [String]
    public var directedAtWearer: Bool
    public var reason: String
}

public struct VerifyResult: Sendable, Equatable {
    public var threatLevel: String
    public var behaviours: [String]
    public var confidence: Double
    public var reason: String
    public var path: String
    public var sam2LatencyMs: Double?
    public var museLatencyMs: Double
}

public struct VerifierConfig: Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public static let backendURLDefaultsKey = "backendBaseURL"

    public static let fallbackURL = URL(string: "http://127.0.0.1:8000")!

    public static var `default`: VerifierConfig {
        resolve(
            override: UserDefaults.standard.string(forKey: backendURLDefaultsKey),
            plistValue: Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        )
    }

    public static let lastBuildURLDefaultsKey = "lastBuildBackendURL"

    public static func reconcileBuildURL(
        defaults: UserDefaults = .standard,
        plistValue: String? = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
    ) {
        let built = validURL(plistValue)?.absoluteString ?? ""
        let last = defaults.string(forKey: lastBuildURLDefaultsKey) ?? ""
        guard built != last else { return }
        defaults.removeObject(forKey: backendURLDefaultsKey)
        defaults.set(built, forKey: lastBuildURLDefaultsKey)
    }

    public static func resolve(override: String?, plistValue: String?) -> VerifierConfig {
        let url = validURL(override) ?? validURL(plistValue) ?? fallbackURL
        return VerifierConfig(baseURL: url)
    }

    public static func validURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            return nil
        }
        return url
    }

    public static var appToken: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "SafeguardAppToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return DeviceRegistrar.shared.current
    }

    public func authorize(_ request: URLRequest) -> URLRequest {
        Self.authorize(request, token: Self.appToken)
    }

    public static func authorize(_ request: URLRequest, token: String?) -> URLRequest {
        guard let token, !token.isEmpty else { return request }
        var copy = request
        copy.setValue(token, forHTTPHeaderField: "X-Safeguard-Token")
        return copy
    }
}

public enum VerifierError: Error, Equatable {
    case serverStatus(Int)
    case invalidResponse(String)
}

public struct VerifyFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case unreachable
        case noKey
        case rateLimit
        case serverError
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var message: String {
        switch kind {
        case .unreachable:
            String(localized: "Verification is offline: backend unreachable. On-device protection only.")
        case .noKey:
            String(localized: "Verification unavailable: the backend has no API key.")
        case .rateLimit:
            String(localized: "Verification rate-limited: too many checks in a minute.")
        case .serverError:
            L10n.format("Verification server error (%@). On-device protection only.", detail)
        }
    }

    public static func classify(_ error: Error, museConfigured: Bool?) -> VerifyFailure {
        if let urlError = error as? URLError,
           Self.unreachableCodes.contains(urlError.code)
        {
            return VerifyFailure(kind: .unreachable, detail: urlError.code.rawValue.description)
        }
        if let verifierError = error as? VerifierError {
            switch verifierError {
            case .serverStatus(429):
                return VerifyFailure(kind: .rateLimit, detail: "429")
            case let .serverStatus(code):
                if code >= 500, museConfigured == false {
                    return VerifyFailure(kind: .noKey, detail: "\(code)")
                }
                return VerifyFailure(kind: .serverError, detail: "\(code)")
            case let .invalidResponse(detail):
                return VerifyFailure(kind: .serverError, detail: detail)
            }
        }
        return VerifyFailure(kind: .serverError, detail: "\(error)")
    }

    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .notConnectedToInternet, .timedOut, .dnsLookupFailed,
        .cannotLoadFromNetwork, .secureConnectionFailed,
    ]
}

public struct BackendStatus: Sendable, Equatable {
    public var reachable: Bool
    public var museConfigured: Bool?

    public init(reachable: Bool, museConfigured: Bool? = nil) {
        self.reachable = reachable
        self.museConfigured = museConfigured
    }
}

public final class VerifierClient: @unchecked Sendable {
    private let fixedConfig: VerifierConfig?
    private let session: URLSession

    public init(config: VerifierConfig? = nil, session: URLSession = .shared) {
        self.fixedConfig = config
        self.session = session
    }

    private var config: VerifierConfig { fixedConfig ?? .default }

    public func checkHealth(timeout: TimeInterval = 5) async -> Bool {
        await fetchStatus(timeout: timeout).reachable
    }

    public func fetchStatus(timeout: TimeInterval = 5) async -> BackendStatus {
        let request = URLRequest(
            url: config.baseURL.appendingPathComponent("health"), timeoutInterval: timeout
        )
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else {
            return BackendStatus(reachable: false)
        }
        let configured = (try? JSONDecoder().decode(HealthBody.self, from: data))?
            .muse_configured
        return BackendStatus(reachable: true, museConfigured: configured)
    }

    private struct HealthBody: Decodable {
        var muse_configured: Bool?
    }

    private struct RequestBody: Encodable {
        var frames_b64: [String]
        var on_device_features: FeaturesEnvelope
        var boxes_xyxy: [[Double]]

        struct FeaturesEnvelope: Encodable {
            var max_score: Double
            var tracks: [VerifyFeatureSummary]
        }
    }

    private struct ResponseBody: Decodable {
        var threat_level: String
        var behaviours_observed: [String]
        var confidence: Double
        var reason: String
        var path: String
        var sam2_latency_ms: Double?
        var muse_latency_ms: Double
    }

    public func verify(_ payload: VerifyPayload) async throws -> VerifyResult {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent("verify"),
            timeoutInterval: config.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RequestBody(
            frames_b64: payload.frames.map { $0.base64EncodedString() },
            on_device_features: .init(
                max_score: payload.features.map(\.score).max() ?? 0,
                tracks: payload.features
            ),
            boxes_xyxy: payload.boxes
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: config.authorize(request))
        guard let http = response as? HTTPURLResponse else {
            throw VerifierError.invalidResponse("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw VerifierError.serverStatus(http.statusCode)
        }
        let parsed: ResponseBody
        do {
            parsed = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw VerifierError.invalidResponse(error.localizedDescription)
        }
        return VerifyResult(
            threatLevel: parsed.threat_level,
            behaviours: parsed.behaviours_observed,
            confidence: parsed.confidence,
            reason: parsed.reason,
            path: parsed.path,
            sam2LatencyMs: parsed.sam2_latency_ms,
            museLatencyMs: parsed.muse_latency_ms
        )
    }

    private struct SpeechRequestBody: Encodable {
        var snippet: String
        var on_device: OnDevice

        struct OnDevice: Encodable {
            var severity: Double
            var category: String
        }
    }

    private struct SpeechResponseBody: Decodable {
        var severity: String
        var categories: [String]
        var directed_at_wearer: Bool
        var reason: String
    }

    public func verifySpeech(
        snippet: String, onDeviceSeverity: Double, onDeviceCategory: String
    ) async throws -> SpeechVerifyResult {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent("verify-speech"),
            timeoutInterval: config.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SpeechRequestBody(
            snippet: snippet,
            on_device: .init(severity: onDeviceSeverity, category: onDeviceCategory)
        ))
        let (data, response) = try await session.data(for: config.authorize(request))
        guard let http = response as? HTTPURLResponse else {
            throw VerifierError.invalidResponse("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw VerifierError.serverStatus(http.statusCode)
        }
        let parsed: SpeechResponseBody
        do {
            parsed = try JSONDecoder().decode(SpeechResponseBody.self, from: data)
        } catch {
            throw VerifierError.invalidResponse(error.localizedDescription)
        }
        return SpeechVerifyResult(
            severity: parsed.severity,
            categories: parsed.categories,
            directedAtWearer: parsed.directed_at_wearer,
            reason: parsed.reason
        )
    }
}
