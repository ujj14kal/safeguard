import XCTest

final class IncidentClientTests: XCTestCase {
    private var fakeToken: String { ["not", "a", "real", "token"].joined(separator: "-") }

    private func stubSession(status: Int = 200, body: String) -> URLSession {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func client(_ session: URLSession) -> IncidentClient {
        IncidentClient(
            config: { VerifierConfig(baseURL: URL(string: "http://example.test:9")!) },
            session: session
        )
    }

    private func captureSession(status: Int = 200, body: String) -> (URLSession, MockURLProtocol.Capture) {
        let capture = MockURLProtocol.Capture()
        MockURLProtocol.handler = { [status, body] request in
            capture.request = request
            if let body = request.httpBody {
                capture.body = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let capacity = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: capacity)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                capture.body = data
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return (URLSession(configuration: config), capture)
    }

    private func jsonBody(_ capture: MockURLProtocol.Capture) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(capture.body)) as? [String: Any]
        )
    }

    func testAuthorizeStampsToken() {
        let request = URLRequest(url: URL(string: "http://example.test:9/x")!)
        let stamped = VerifierConfig.authorize(request, token: fakeToken)
        XCTAssertEqual(
            stamped.value(forHTTPHeaderField: "X-Safeguard-Token"), fakeToken
        )
        let bare = VerifierConfig.authorize(request, token: nil)
        XCTAssertNil(bare.value(forHTTPHeaderField: "X-Safeguard-Token"))
        let empty = VerifierConfig.authorize(request, token: "")
        XCTAssertNil(empty.value(forHTTPHeaderField: "X-Safeguard-Token"))
    }

    private let startJSON = """
        {"id": "inc-abc", "share_token": "share123", "live_url": "https://demo.test/live/share123",
         "delivery": [{"code": "c1", "name": "Meera", "status": "dry-run", "detail": ""}],
         "fresh": true}
        """

    func testStartRequestShape() async throws {
        let (session, capture) = captureSession(body: startJSON)
        _ = try await client(session).startIncident(
            sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: ["c1"],
            dryRun: false, latitude: 12.9, longitude: 77.5
        )
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.path, "/incident/start")
        XCTAssertEqual(request.httpMethod, "POST")
        let json = try jsonBody(capture)
        XCTAssertEqual(json["session"] as? String, "sos-abcdef12")
        XCTAssertEqual(json["wearer_name"] as? String, "Aarav")
        XCTAssertEqual(json["contact_codes"] as? [String], ["c1"])
        XCTAssertEqual(json["dry_run"] as? Bool, false)
        XCTAssertEqual(json["test"] as? Bool, false)
        XCTAssertEqual(json["lat"] as? Double, 12.9)
        XCTAssertEqual(json["lon"] as? Double, 77.5)
    }

    func testStartDefaultsToDryRun() async throws {
        let (session, capture) = captureSession(body: startJSON)
        _ = try await client(session).startIncident(
            sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: []
        )
        XCTAssertEqual(try jsonBody(capture)["dry_run"] as? Bool, true)
    }

    func testStartParsesResult() async throws {
        let result = try await client(stubSession(body: startJSON)).startIncident(
            sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: ["c1"]
        )
        XCTAssertEqual(result.id, "inc-abc")
        XCTAssertEqual(result.shareToken, "share123")
        XCTAssertEqual(result.liveURL, "https://demo.test/live/share123")
        XCTAssertEqual(result.fresh, true)
        XCTAssertEqual(
            result.delivery,
            [IncidentDelivery(code: "c1", name: "Meera", status: "dry-run", detail: "")]
        )
    }

    func testStartSendsLangAndParsesPreview() async throws {
        let body = startJSON.replacingOccurrences(
            of: "\"fresh\": true", with: "\"fresh\": true, \"preview_text\": \"SOS from Aarav\""
        )
        let (session, capture) = captureSession(body: body)
        let result = try await client(session).startIncident(
            sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: [],
            lang: "hi"
        )
        XCTAssertEqual(try jsonBody(capture)["lang"] as? String, "hi")
        XCTAssertEqual(result.previewText, "SOS from Aarav")
    }

    func testStartPreviewDefaultsToEmpty() async throws {
        let result = try await client(stubSession(body: startJSON)).startIncident(
            sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: []
        )
        XCTAssertEqual(result.previewText, "")
    }

    func testUnauthorizedMapsToServerStatus() async {
        do {
            _ = try await client(stubSession(status: 401, body: "{}")).startIncident(
                sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: []
            )
            XCTFail("expected throw")
        } catch let error as VerifierError {
            XCTAssertEqual(error, .serverStatus(401))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testLocationRequestShape() async throws {
        let (session, capture) = captureSession(body: "{\"stored\": 3}")
        try await client(session).sendLocation(
            incidentID: "inc-abc", latitude: 12.9, longitude: 77.5,
            accuracy: 8, timestamp: 1700000001
        )
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.path, "/incident/inc-abc/location")
        let json = try jsonBody(capture)
        XCTAssertEqual(json["lat"] as? Double, 12.9)
        XCTAssertEqual(json["accuracy"] as? Double, 8)
        XCTAssertEqual(json["ts"] as? Double, 1700000001)
    }

    func testEndReturnsEnded() async throws {
        let (session, capture) = captureSession(body: "{\"ended\": true, \"already_ended\": false}")
        let ended = try await client(session).endIncident("inc-abc")
        XCTAssertTrue(ended)
        XCTAssertEqual(try XCTUnwrap(capture.request).url?.path, "/incident/inc-abc/end")
    }

    func testCabRequestShape() async throws {
        let (session, capture) = captureSession(body: "{\"sent\": 1, \"delivery\": []}")
        let sent = try await client(session).shareCab(
            incidentID: "inc-abc", driver: "Demo Driver", plate: "DL-1D-EMO", etaMinutes: 4
        )
        XCTAssertEqual(sent, 1)
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.path, "/incident/inc-abc/cab")
        let json = try jsonBody(capture)
        XCTAssertEqual(json["driver"] as? String, "Demo Driver")
        XCTAssertEqual(json["eta_min"] as? Int, 4)
    }

    func testInviteParses() async throws {
        let body = "{\"name\": \"Meera\", \"code\": \"abc123\", \"link\": \"https://t.me/bot?start=abc123\"}"
        let (session, capture) = captureSession(body: body)
        let invite = try await client(session).inviteContact(name: "Meera")
        XCTAssertEqual(invite.code, "abc123")
        XCTAssertEqual(invite.link, "https://t.me/bot?start=abc123")
        XCTAssertEqual(try XCTUnwrap(capture.request).url?.path, "/contacts/invite")
    }

    func testContactStatusParses() async throws {
        let (session, capture) = captureSession(body: "{\"name\": \"Meera\", \"linked\": true}")
        let status = try await client(session).contactStatus(code: "abc123")
        XCTAssertEqual(status, LinkedContactStatus(name: "Meera", linked: true))
        XCTAssertEqual(try XCTUnwrap(capture.request).url?.path, "/contacts/abc123")
        XCTAssertEqual(try XCTUnwrap(capture.request).httpMethod, "GET")
    }

    func testDeleteEvidenceUsesDelete() async throws {
        let (session, capture) = captureSession(body: "{\"deleted\": true}")
        let deleted = try await client(session).deleteEvidence(sessionID: "sos-abcdef12")
        XCTAssertTrue(deleted)
        XCTAssertEqual(try XCTUnwrap(capture.request).url?.path, "/evidence/sos-abcdef12")
        XCTAssertEqual(try XCTUnwrap(capture.request).httpMethod, "DELETE")
    }

    func testDeleteContactUsesDelete() async throws {
        let (session, capture) = captureSession(body: "{\"deleted\": false}")
        let deleted = try await client(session).deleteContact(code: "abc123")
        XCTAssertFalse(deleted, "idempotent miss still parses")
        XCTAssertEqual(try XCTUnwrap(capture.request).url?.path, "/contacts/abc123")
        XCTAssertEqual(try XCTUnwrap(capture.request).httpMethod, "DELETE")
    }

    func testInvalidJSONThrows() async {
        do {
            _ = try await client(stubSession(body: "not json")).startIncident(
                sessionID: "sos-abcdef12", wearerName: "Aarav", contactCodes: []
            )
            XCTFail("expected throw")
        } catch let error as VerifierError {
            if case .invalidResponse = error {
            } else {
                XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
