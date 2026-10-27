import Foundation

/// What an SOS recording segment contains.
public enum EvidenceKind: String, Sendable, CaseIterable {
    case video
    case audio

    public var fileExtension: String {
        switch self {
        case .video: "mp4"
        case .audio: "m4a"
        }
    }
}

public enum EvidenceSessionID {
    /// "sos-" plus 12 random hex digits: the backend accepts 8-64 letters,
    /// digits, "_" and "-", and uses it as a folder name.
    public static func make() -> String {
        "sos-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }
}

/// Segment file names are `<kind>-<5-digit sequence>.<ext>` on the phone and
/// on the backend, so a half-uploaded session can be resumed from names alone.
public enum EvidenceSegmentName {
    public static func filename(kind: EvidenceKind, seq: Int) -> String {
        String(format: "%@-%05d.%@", kind.rawValue, seq, kind.fileExtension)
    }

    public static func parse(_ filename: String) -> (kind: EvidenceKind, seq: Int)? {
        let parts = filename.split(separator: ".")
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"),
              let kind = EvidenceKind(rawValue: String(parts[0][..<dash])),
              parts[1] == kind.fileExtension,
              let seq = Int(parts[0][parts[0].index(after: dash)...])
        else { return nil }
        return (kind, seq)
    }
}

/// Upload retry schedule. Evidence matters more than a quick failure: keep
/// trying with growing waits, and keep the file on disk if every try fails.
public struct EvidenceRetryPolicy: Sendable {
    public var delays: [TimeInterval] = [1, 3, 6, 15, 30, 60]

    public init() {}

    /// Seconds to wait before attempt number `attempt` (1-based after the
    /// first try), or nil when the attempts are used up.
    public func delay(beforeRetry attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

public enum EvidenceUploadError: Error, Equatable {
    case badStatus(Int)
    case notHTTP
}

/// Sends one closed segment to the backend (`POST /evidence`, raw bytes).
public struct EvidenceUploader: Sendable {
    private let config: @Sendable () -> VerifierConfig
    private let urlSession: URLSession
    private let token: String?
    private let policy: EvidenceRetryPolicy

    /// One session for all segments: keep-alive connections are reused (no
    /// new TLS handshake per part), several parts upload at once, and a
    /// part waits for the network to come back instead of failing at once.
    public static let fastSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(
        config: @escaping @Sendable () -> VerifierConfig = { VerifierConfig.default },
        urlSession: URLSession = EvidenceUploader.fastSession,
        token: String? = nil,
        policy: EvidenceRetryPolicy = EvidenceRetryPolicy()
    ) {
        self.config = config
        self.urlSession = urlSession
        self.token = token
        self.policy = policy
    }

    /// The request for one segment; the file goes in as the body.
    public func request(sessionID: String, kind: EvidenceKind, seq: Int) -> URLRequest {
        let base = config()
        var components = URLComponents(
            url: base.baseURL.appendingPathComponent("evidence"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "seq", value: String(seq)),
            URLQueryItem(name: "ext", value: kind.fileExtension),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // App token everywhere; the explicit legacy evidence token still
        // goes out when provided (the backend accepts either).
        request = base.authorize(request)
        if let token { request.setValue(token, forHTTPHeaderField: "X-Evidence-Token") }
        return request
    }

    public func uploadOnce(file: URL, sessionID: String, kind: EvidenceKind, seq: Int) async throws {
        let request = request(sessionID: sessionID, kind: kind, seq: seq)
        let (_, response) = try await urlSession.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw EvidenceUploadError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw EvidenceUploadError.badStatus(http.statusCode) }
    }

    /// Uploads with the retry schedule. Returns true on success; false means
    /// the file must stay on disk for a later retry.
    public func upload(file: URL, sessionID: String, kind: EvidenceKind, seq: Int) async -> Bool {
        var attempt = 0
        while true {
            do {
                try await uploadOnce(file: file, sessionID: sessionID, kind: kind, seq: seq)
                return true
            } catch {
                attempt += 1
                // A rejected segment (4xx other than rate limits) will never
                // succeed: stop retrying instead of hammering the backend.
                if case EvidenceUploadError.badStatus(let code) = error, (400..<500).contains(code), code != 408, code != 429 {
                    return false
                }
                guard let wait = policy.delay(beforeRetry: attempt) else { return false }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
}

/// Counts for the SOS screen.
public struct EvidenceProgress: Sendable, Equatable {
    public var segments = 0
    public var uploaded = 0
    public var failed = 0

    public init(segments: Int = 0, uploaded: Int = 0, failed: Int = 0) {
        self.segments = segments
        self.uploaded = uploaded
        self.failed = failed
    }

    public var summary: String {
        var text = L10n.format("Recording • %d of %d parts saved to the cloud", uploaded, segments)
        if failed > 0 {
            text += L10n.format(" • %d waiting to retry", failed)
        }
        return text
    }
}
