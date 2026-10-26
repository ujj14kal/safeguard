import Foundation

/// On-device summary for one track, sent with a /verify call.
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

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case score, reasons, trend, speed, persistence, facing, isolation, blocking, cornering
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
    }
}

/// Everything one /verify call carries. Built on the detection queue.
public struct VerifyPayload: Sendable {
    public var frames: [Data]
    /// Person boxes on the (first) frame in JPEG pixels [x0, y0, x1, y1].
    public var boxes: [[Double]]
    public var features: [VerifyFeatureSummary]

    public init(frames: [Data], boxes: [[Double]], features: [VerifyFeatureSummary]) {
        self.frames = frames
        self.boxes = boxes
        self.features = features
    }
}

/// Parsed /verify verdict.
public struct VerifyResult: Sendable, Equatable {
    public var threatLevel: String
    public var behaviours: [String]
    public var confidence: Double
    public var reason: String
    public var path: String
    public var sam2LatencyMs: Double?
    public var museLatencyMs: Double
}

/// Backend connection config. No keys in the app: the backend holds them.
public struct VerifierConfig: Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Backend URL from Info.plist `BackendBaseURL`, else localhost (dev).
    /// On-device runs must point this at the Mac running the backend.
    public static var `default`: VerifierConfig {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        let url = raw.flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8000")!
        return VerifierConfig(baseURL: url)
    }
}

public enum VerifierError: Error, Equatable {
    case serverStatus(Int)
    case invalidResponse(String)
}

/// POSTs one /verify call. URLSession is thread-safe; config is immutable.
public final class VerifierClient: @unchecked Sendable {
    private let config: VerifierConfig
    private let session: URLSession

    public init(config: VerifierConfig = .default, session: URLSession = .shared) {
        self.config = config
        self.session = session
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
        let (data, response) = try await session.data(for: request)
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
}
