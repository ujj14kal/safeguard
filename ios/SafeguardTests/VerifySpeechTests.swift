import XCTest

/// /verify-speech client: text-only request shape, strict response parsing,
/// failure mapping. Reuses the URLProtocol stub: no network, no keys.
final class VerifySpeechTests: XCTestCase {
    private func stubSession(
        status: Int = 200, body: String = """
        {"severity": "high", "categories": ["coercion"],
         "directed_at_wearer": true, "reason": "Direct order to follow."}
        """
    ) -> URLSession {
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

    private func client(_ session: URLSession) -> VerifierClient {
        VerifierClient(
            config: VerifierConfig(baseURL: URL(string: "http://example.test:9")!),
            session: session
        )
    }

    func testRequestIsTextOnly() async throws {
        let capture = MockURLProtocol.Capture()
        MockURLProtocol.handler = { request in
            capture.request = request
            // URLSession may stream the body instead of setting httpBody.
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
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(
                "{\"severity\": \"low\", \"categories\": [], \"directed_at_wearer\": false, \"reason\": \"ok\"}".utf8
            ))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        _ = try await client(URLSession(configuration: config)).verifySpeech(
            snippet: "come with me", onDeviceSeverity: 0.9, onDeviceCategory: "coercion"
        )
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.path, "/verify-speech")
        XCTAssertEqual(request.httpMethod, "POST")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(capture.body)) as? [String: Any]
        )
        XCTAssertEqual(json["snippet"] as? String, "come with me")
        let onDevice = try XCTUnwrap(json["on_device"] as? [String: Any])
        XCTAssertEqual(onDevice["severity"] as? Double, 0.9)
        XCTAssertEqual(onDevice["category"] as? String, "coercion")
        for key in json.keys {
            XCTAssertFalse(
                ["audio", "pcm", "wav", "frames_b64", "samples"].contains(key),
                "audio-ish key sent: \(key)"
            )
        }
    }

    func testParsesResult() async throws {
        let result = try await client(stubSession()).verifySpeech(
            snippet: "come with me", onDeviceSeverity: 0.9, onDeviceCategory: "coercion"
        )
        XCTAssertEqual(
            result,
            SpeechVerifyResult(
                severity: "high", categories: ["coercion"],
                directedAtWearer: true, reason: "Direct order to follow."
            )
        )
    }

    func testServerErrorThrows() async {
        do {
            _ = try await client(stubSession(status: 503, body: "{}")).verifySpeech(
                snippet: "x", onDeviceSeverity: 1, onDeviceCategory: "threat"
            )
            XCTFail("expected throw")
        } catch let error as VerifierError {
            XCTAssertEqual(error, .serverStatus(503))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRateLimitClassifies() async {
        do {
            _ = try await client(stubSession(status: 429, body: "{}")).verifySpeech(
                snippet: "x", onDeviceSeverity: 1, onDeviceCategory: "threat"
            )
            XCTFail("expected throw")
        } catch {
            let failure = VerifyFailure.classify(error, museConfigured: true)
            XCTAssertEqual(failure.kind, .rateLimit)
        }
    }

    func testInvalidJSONThrows() async {
        do {
            _ = try await client(stubSession(body: "not json")).verifySpeech(
                snippet: "x", onDeviceSeverity: 1, onDeviceCategory: "threat"
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
