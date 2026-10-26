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

    /// Vision boxes are normalized with the origin at the LOWER-left; SAM 2
    /// expects pixel [x0, y0, x1, y1] with the origin at the TOP-left. Passing
    /// Vision's y straight through mirrored every box vertically.
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

    /// UserDefaults key for the backend URL typed into Settings (debug builds).
    public static let backendURLDefaultsKey = "backendBaseURL"

    /// Localhost: only reachable from the Simulator. On a real iPhone this
    /// points at the phone itself, so device runs must set a real URL.
    public static let fallbackURL = URL(string: "http://127.0.0.1:8000")!

    /// Backend URL, in priority order: the Settings override, the Info.plist
    /// `BackendBaseURL` (set at build time with `BACKEND_BASE_URL=...`), else
    /// localhost. Evaluated on every call, so changing it in Settings applies
    /// immediately without relaunching.
    public static var `default`: VerifierConfig {
        resolve(
            override: UserDefaults.standard.string(forKey: backendURLDefaultsKey),
            plistValue: Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        )
    }

    public static func resolve(override: String?, plistValue: String?) -> VerifierConfig {
        let url = validURL(override) ?? validURL(plistValue) ?? fallbackURL
        return VerifierConfig(baseURL: url)
    }

    /// Trimmed http(s) URL with a host, or nil. Anything else (empty, no
    /// scheme, ftp, junk) falls through to the next source.
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
}

public enum VerifierError: Error, Equatable {
    case serverStatus(Int)
    case invalidResponse(String)
}

/// Why a /verify (or /verify-speech) call failed, in words the wearer can
/// act on. A failure never suppresses an alert: the on-device result stands
/// and this reason is shown instead of a bare "Verify failed".
public struct VerifyFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case unreachable
        case noKey
        case rateLimit
        case serverError
    }

    public var kind: Kind
    /// Raw detail for logs (status code or system message), not for display.
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var message: String {
        switch kind {
        case .unreachable:
            "Verification is offline: backend unreachable. On-device protection only."
        case .noKey:
            "Verification unavailable: the backend has no API key."
        case .rateLimit:
            "Verification rate-limited: too many checks in a minute."
        case .serverError:
            "Verification server error (\(detail)). On-device protection only."
        }
    }

    /// `museConfigured` is the last known /health status: a 5xx from a
    /// backend that reports no key is a setup problem, not a crash.
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

/// What GET /health reported the last time it was asked.
public struct BackendStatus: Sendable, Equatable {
    /// The backend answered 200.
    public var reachable: Bool
    /// Whether the backend has a Muse API key. Nil when unknown (older
    /// backend, or /health itself unreachable).
    public var museConfigured: Bool?

    public init(reachable: Bool, museConfigured: Bool? = nil) {
        self.reachable = reachable
        self.museConfigured = museConfigured
    }
}

/// POSTs one /verify call. URLSession is thread-safe; config is immutable.
public final class VerifierClient: @unchecked Sendable {
    private let fixedConfig: VerifierConfig?
    private let session: URLSession

    /// `config` nil (the app) resolves `VerifierConfig.default` on every call,
    /// so a URL changed in Settings takes effect immediately.
    public init(config: VerifierConfig? = nil, session: URLSession = .shared) {
        self.fixedConfig = config
        self.session = session
    }

    private var config: VerifierConfig { fixedConfig ?? .default }

    /// GET /health. False on any failure (unreachable, ATS, wrong URL, non-200).
    public func checkHealth(timeout: TimeInterval = 5) async -> Bool {
        await fetchStatus(timeout: timeout).reachable
    }

    /// GET /health with the Muse-key flag. Drives the HUD backend dot and
    /// the no-key failure reason. Old backends omit the flag (nil), which
    /// still counts as reachable.
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
