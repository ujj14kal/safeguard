import Foundation

public enum EvidenceKind: String, Sendable, CaseIterable {
    case video
    case audio
    case initSegment = "init"
    case mediaSegment = "seg"

    public var fileExtension: String {
        switch self {
        case .video: "mp4"
        case .audio: "m4a"
        case .initSegment: "mp4"
        case .mediaSegment: "m4s"
        }
    }
}

public enum EvidenceSessionID {
    public static func make() -> String {
        "sos-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }
}

public enum EvidenceSegmentName {
    public static func filename(kind: EvidenceKind, seq: Int) -> String {
        String(format: "%@-%05d.%@", kind.rawValue, seq, kind.fileExtension)
    }

    public static func filename(kind: EvidenceKind, seq: Int, durationMs: Int?) -> String {
        switch kind {
        case .initSegment:
            return "init.mp4"
        case .mediaSegment:
            return String(format: "seg-%05d-%04d.m4s", seq, durationMs ?? 2000)
        case .video, .audio:
            return filename(kind: kind, seq: seq)
        }
    }

    public static func parseAny(_ filename: String) -> (kind: EvidenceKind, seq: Int, durationMs: Int?)? {
        if filename == "init.mp4" { return (.initSegment, 0, nil) }
        if filename.hasPrefix("seg-"), filename.hasSuffix(".m4s") {
            let core = filename.dropFirst(4).dropLast(4).split(separator: "-")
            if core.count == 2, let seq = Int(core[0]), let dur = Int(core[1]) {
                return (.mediaSegment, seq, dur)
            }
            return nil
        }
        if let old = parse(filename) { return (old.kind, old.seq, nil) }
        return nil
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

public struct EvidenceRetryPolicy: Sendable {
    public var delays: [TimeInterval] = [1, 3, 6, 15, 30, 60]

    public init() {}

    public func delay(beforeRetry attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

public enum EvidenceUploadError: Error, Equatable {
    case badStatus(Int)
    case notHTTP
}

public struct EvidenceUploader: Sendable {
    private let config: @Sendable () -> VerifierConfig
    private let urlSession: URLSession
    private let token: String?
    private let policy: EvidenceRetryPolicy

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

    public func request(
        sessionID: String, kind: EvidenceKind, seq: Int, durationMs: Int? = nil
    ) -> URLRequest {
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
        if kind == .mediaSegment {
            components.queryItems?.append(URLQueryItem(name: "dur", value: String(durationMs ?? 2000)))
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request = base.authorize(request)
        if let token { request.setValue(token, forHTTPHeaderField: "X-Evidence-Token") }
        return request
    }

    public func uploadOnce(
        file: URL, sessionID: String, kind: EvidenceKind, seq: Int, durationMs: Int? = nil
    ) async throws {
        let request = request(sessionID: sessionID, kind: kind, seq: seq, durationMs: durationMs)
        let (_, response) = try await urlSession.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw EvidenceUploadError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw EvidenceUploadError.badStatus(http.statusCode) }
    }

    public func upload(
        file: URL, sessionID: String, kind: EvidenceKind, seq: Int, durationMs: Int? = nil
    ) async -> Bool {
        var attempt = 0
        while true {
            do {
                try await uploadOnce(
                    file: file, sessionID: sessionID, kind: kind, seq: seq, durationMs: durationMs
                )
                return true
            } catch {
                attempt += 1
                if case EvidenceUploadError.badStatus(let code) = error, (400..<500).contains(code), code != 408, code != 429 {
                    return false
                }
                guard let wait = policy.delay(beforeRetry: attempt) else { return false }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
}

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
