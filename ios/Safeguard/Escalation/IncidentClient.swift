import Foundation

public struct IncidentDelivery: Sendable, Equatable, Decodable {
    public var code: String
    public var name: String?
    public var status: String
    public var detail: String?
}

public struct IncidentStartResult: Sendable, Equatable {
    public var id: String
    public var shareToken: String
    public var liveURL: String
    public var delivery: [IncidentDelivery]
    public var fresh: Bool
    public var previewText: String
}

public struct LinkedContactStatus: Sendable, Equatable {
    public var name: String
    public var linked: Bool
}

public struct IncidentClient: Sendable {
    private let config: @Sendable () -> VerifierConfig
    private let session: URLSession

    public init(
        config: @escaping @Sendable () -> VerifierConfig = { VerifierConfig.default },
        session: URLSession = .shared
    ) {
        self.config = config
        self.session = session
    }

    private func post(_ path: String, json body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(
            url: config().baseURL.appendingPathComponent(path), timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return config().authorize(request)
    }

    private func get(_ path: String) -> URLRequest {
        let request = URLRequest(
            url: config().baseURL.appendingPathComponent(path), timeoutInterval: 30
        )
        return config().authorize(request)
    }

    private func delete(_ path: String) -> URLRequest {
        var request = URLRequest(
            url: config().baseURL.appendingPathComponent(path), timeoutInterval: 30
        )
        request.httpMethod = "DELETE"
        return config().authorize(request)
    }

    public func postTranscript(incidentID: String, lines: [[String: Any]]) async throws {
        let (data, response) = try await session.data(
            for: post("incident/\(incidentID)/transcript", json: ["lines": lines])
        )
        try check(data: data, response: response)
    }

    public func postItems(incidentID: String, items: [[String: Any]]) async throws {
        let request = try post("incident/\(incidentID)/items", json: ["items": items])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VerifierError.invalidResponse("items not stored")
        }
    }

    private struct StartBody: Decodable {
        var id: String
        var share_token: String
        var live_url: String
        var delivery: [IncidentDelivery]
        var fresh: Bool
        var preview_text: String?
    }

    public func startIncident(
        sessionID: String,
        wearerName: String,
        contactCodes: [String],
        dryRun: Bool = true,
        test: Bool = false,
        lang: String = AppLanguage.alertLang,
        latitude: Double? = nil,
        longitude: Double? = nil,
        mode: String = "sos",
        channelToken: String? = nil,
        guardianCode: String? = nil
    ) async throws -> IncidentStartResult {
        var body: [String: Any] = [
            "session": sessionID,
            "wearer_name": wearerName,
            "contact_codes": contactCodes,
            "dry_run": dryRun,
            "test": test,
            "lang": lang,
        ]
        if let latitude, let longitude {
            body["lat"] = latitude
            body["lon"] = longitude
        }
        if mode != "sos" { body["mode"] = mode }
        if let channelToken, !channelToken.isEmpty { body["channel_token"] = channelToken }
        if let guardianCode, !guardianCode.isEmpty { body["guardian_code"] = guardianCode }
        let (data, response) = try await session.data(for: post("incident/start", json: body))
        let parsed: StartBody = try decode(data, response: response)
        return IncidentStartResult(
            id: parsed.id,
            shareToken: parsed.share_token,
            liveURL: parsed.live_url,
            delivery: parsed.delivery,
            fresh: parsed.fresh,
            previewText: parsed.preview_text ?? ""
        )
    }

    public func sendLocation(
        incidentID: String, latitude: Double, longitude: Double,
        accuracy: Double? = nil, timestamp: TimeInterval? = nil
    ) async throws {
        var body: [String: Any] = ["lat": latitude, "lon": longitude]
        if let accuracy { body["accuracy"] = accuracy }
        if let timestamp { body["ts"] = timestamp }
        let (data, response) = try await session.data(
            for: post("incident/\(incidentID)/location", json: body)
        )
        try check(data: data, response: response)
    }

    private struct EndBody: Decodable {
        var ended: Bool
        var already_ended: Bool
    }

    @discardableResult
    public func endIncident(_ incidentID: String) async throws -> Bool {
        let (data, response) = try await session.data(
            for: post("incident/\(incidentID)/end", json: [:])
        )
        let parsed: EndBody = try decode(data, response: response)
        return parsed.ended
    }

    private struct CabBody: Decodable {
        var sent: Int
    }

    @discardableResult
    public func shareCab(
        incidentID: String, driver: String, plate: String, etaMinutes: Int
    ) async throws -> Int {
        let body: [String: Any] = ["driver": driver, "plate": plate, "eta_min": etaMinutes]
        let (data, response) = try await session.data(
            for: post("incident/\(incidentID)/cab", json: body)
        )
        let parsed: CabBody = try decode(data, response: response)
        return parsed.sent
    }

    private struct InviteBody: Decodable {
        var name: String
        var code: String
        var link: String
    }

    public func inviteContact(name: String) async throws -> (name: String, code: String, link: String) {
        let (data, response) = try await session.data(
            for: post("contacts/invite", json: ["name": name])
        )
        let parsed: InviteBody = try decode(data, response: response)
        return (parsed.name, parsed.code, parsed.link)
    }

    private struct StatusBody: Decodable {
        var name: String
        var linked: Bool
    }

    public func contactStatus(code: String) async throws -> LinkedContactStatus {
        let (data, response) = try await session.data(for: get("contacts/\(code)"))
        let parsed: StatusBody = try decode(data, response: response)
        return LinkedContactStatus(name: parsed.name, linked: parsed.linked)
    }

    private struct DeleteBody: Decodable {
        var deleted: Bool
    }

    @discardableResult
    public func deleteEvidence(sessionID: String) async throws -> Bool {
        let (data, response) = try await session.data(for: delete("evidence/\(sessionID)"))
        let parsed: DeleteBody = try decode(data, response: response)
        return parsed.deleted
    }

    @discardableResult
    public func deleteContact(code: String) async throws -> Bool {
        let (data, response) = try await session.data(for: delete("contacts/\(code)"))
        let parsed: DeleteBody = try decode(data, response: response)
        return parsed.deleted
    }

    private struct ChannelBody: Decodable {
        var token: String
        var live_url: String
    }

    public func createChannel(deviceID: String, wearerName: String) async throws -> (token: String, url: String) {
        let (data, response) = try await session.data(
            for: post("live/channel", json: ["device_id": deviceID, "wearer_name": wearerName])
        )
        let parsed: ChannelBody = try decode(data, response: response)
        return (parsed.token, parsed.live_url)
    }

    private struct RevokedBody: Decodable {
        var revoked: Bool
    }

    @discardableResult
    public func revokeChannel(deviceID: String) async throws -> Bool {
        let (data, response) = try await session.data(for: delete("live/channel/\(deviceID)"))
        let parsed: RevokedBody = try decode(data, response: response)
        return parsed.revoked
    }

    private struct ValidBody: Decodable {
        var valid: Bool
    }

    public func guardianCodeExists(_ code: String) async throws -> Bool {
        let (data, response) = try await session.data(for: get("guardian/check/\(code)"))
        let parsed: ValidBody = try decode(data, response: response)
        return parsed.valid
    }

    private func check(data _: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VerifierError.invalidResponse("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw VerifierError.serverStatus(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data, response: URLResponse) throws -> T {
        try check(data: data, response: response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VerifierError.invalidResponse(error.localizedDescription)
        }
    }
}
