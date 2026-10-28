import CoreVideo
import XCTest

final class VerifierTests: XCTestCase {

    func testEdgeTrigger() {
        var gate = VerifierGate()
        XCTAssertFalse(gate.consume(maxScore: 0.2))
        XCTAssertTrue(gate.consume(maxScore: 0.6))
        XCTAssertFalse(gate.consume(maxScore: 0.7))
        XCTAssertFalse(gate.consume(maxScore: 0.3))
        XCTAssertTrue(gate.consume(maxScore: 0.6))
    }

    func testNoRearmWithoutDip() {
        var gate = VerifierGate()
        XCTAssertTrue(gate.consume(maxScore: 0.6))
        XCTAssertFalse(gate.consume(maxScore: 0.45))
        XCTAssertFalse(gate.consume(maxScore: 0.6))
    }

    func testProximityCannotTrigger() {
        var gate = VerifierGate()
        for _ in 0..<50 {
            XCTAssertFalse(gate.consume(maxScore: 0.2))
        }
    }

    private func stubSession(
        status: Int = 200, body: String = """
        {"threat_level": "low", "behaviours_observed": ["standing still"],
         "confidence": 0.9, "reason": "Person is stationary, not a threat.",
         "path": "muse-only", "sam2_latency_ms": null, "muse_latency_ms": 812.5}
        """
    ) -> (URLSession, MockURLProtocol.Capture) {
        let capture = MockURLProtocol.Capture()
        MockURLProtocol.handler = { request in
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

    private func payload() -> VerifyPayload {
        VerifyPayload(
            frames: [Data([0xFF, 0xD8, 0x00]), Data([0xFF, 0xD8, 0x01])],
            boxes: [[10, 10, 50, 100]],
            features: [
                VerifyFeatureSummary(
                    track: Track(
                        id: 1, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                        confidence: 0.9, age: 10, missed: 0
                    ),
                    features: PersonFeatures(trend: 0.8, persistence: 0.7),
                    score: 0.74,
                    reasons: ["approaching", "persistent"]
                )
            ]
        )
    }

    func testRequestShape() async throws {
        let (session, capture) = stubSession()
        let client = VerifierClient(
            config: VerifierConfig(baseURL: URL(string: "http://example.test:9")!, timeout: 12),
            session: session
        )
        _ = try await client.verify(payload())
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.url?.path, "/verify")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 12)
        let body = try XCTUnwrap(capture.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual((json["frames_b64"] as? [String])?.count, 2)
        XCTAssertEqual((json["boxes_xyxy"] as? [[Double]])?.count, 1)
        let features = try XCTUnwrap(json["on_device_features"] as? [String: Any])
        XCTAssertEqual(features["max_score"] as? Double, 0.74)
        XCTAssertEqual((features["tracks"] as? [[String: Any]])?.count, 1)
    }

    func testParsesResult() async throws {
        let (session, _) = stubSession()
        let client = VerifierClient(
            config: VerifierConfig(baseURL: URL(string: "http://example.test:9")!),
            session: session
        )
        let result = try await client.verify(payload())
        XCTAssertEqual(result.threatLevel, "low")
        XCTAssertEqual(result.behaviours, ["standing still"])
        XCTAssertEqual(result.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(result.reason, "Person is stationary, not a threat.")
        XCTAssertEqual(result.path, "muse-only")
        XCTAssertNil(result.sam2LatencyMs)
        XCTAssertEqual(result.museLatencyMs, 812.5, accuracy: 1e-9)
    }

    func testServerErrorThrows() async {
        let (session, _) = stubSession(status: 503, body: "{}")
        let client = VerifierClient(
            config: VerifierConfig(baseURL: URL(string: "http://example.test:9")!),
            session: session
        )
        do {
            _ = try await client.verify(payload())
            XCTFail("expected throw")
        } catch let error as VerifierError {
            XCTAssertEqual(error, .serverStatus(503))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testInvalidJSONThrows() async {
        let (session, _) = stubSession(body: "not json")
        let client = VerifierClient(
            config: VerifierConfig(baseURL: URL(string: "http://example.test:9")!),
            session: session
        )
        do {
            _ = try await client.verify(payload())
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

    func testConfigPriorityOverrideThenPlistThenLocalhost() {
        let withBoth = VerifierConfig.resolve(
            override: "http://192.168.1.20:8000", plistValue: "http://10.0.0.5:8000"
        )
        XCTAssertEqual(withBoth.baseURL.absoluteString, "http://192.168.1.20:8000")
        let plistOnly = VerifierConfig.resolve(override: nil, plistValue: "http://10.0.0.5:8000")
        XCTAssertEqual(plistOnly.baseURL.absoluteString, "http://10.0.0.5:8000")
        let neither = VerifierConfig.resolve(override: nil, plistValue: nil)
        XCTAssertEqual(neither.baseURL, VerifierConfig.fallbackURL)
    }

    func testInvalidValuesFallThrough() {
        for junk in ["", "   ", "not a url", "ftp://host", "http://", "192.168.1.20:8000"] {
            XCTAssertEqual(
                VerifierConfig.resolve(override: junk, plistValue: nil).baseURL,
                VerifierConfig.fallbackURL, "\"\(junk)\" should be ignored"
            )
        }
        let fellThrough = VerifierConfig.resolve(
            override: "nope", plistValue: "https://abc.trycloudflare.com"
        )
        XCTAssertEqual(fellThrough.baseURL.host, "abc.trycloudflare.com")
    }

    func testOverrideIsTrimmed() {
        let config = VerifierConfig.resolve(override: "  http://192.168.1.20:8000 \n", plistValue: nil)
        XCTAssertEqual(config.baseURL.absoluteString, "http://192.168.1.20:8000")
    }

    func testInfoPlistAllowsLocalBackend() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safeguard/Supporting/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNotNil(plist["BackendBaseURL"], "build-time backend URL key missing")
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(ats["NSAllowsArbitraryLoads"], "do not open App Transport Security wide")
        let reason = plist["NSLocalNetworkUsageDescription"] as? String ?? ""
        XCTAssertFalse(reason.isEmpty, "local network permission needs a usage description")
    }

    func testInfoPlistHasAppTokenKey() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safeguard/Supporting/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let value = try XCTUnwrap(plist["SafeguardAppToken"] as? String)
        XCTAssertTrue(value.hasPrefix("$("), "app token must be a build setting")
    }

    func testInfoPlistHasSpeechDescriptions() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safeguard/Supporting/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let text = plist[key] as? String ?? ""
            XCTAssertFalse(text.isEmpty, "\(key) needs a usage description")
        }
    }

    func testClientResolvesConfigOnEveryCall() async throws {
        let (session, capture) = stubSession()
        let key = VerifierConfig.backendURLDefaultsKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let client = VerifierClient(session: session)

        UserDefaults.standard.set("http://first.test:9", forKey: key)
        _ = try await client.verify(payload())
        XCTAssertEqual(capture.request?.url?.host, "first.test")

        UserDefaults.standard.set("http://second.test:9", forKey: key)
        _ = try await client.verify(payload())
        XCTAssertEqual(capture.request?.url?.host, "second.test")
    }

    func testClassifyUnreachable() {
        for code: URLError.Code in [
            .cannotConnectToHost, .notConnectedToInternet, .timedOut, .dnsLookupFailed,
        ] {
            let failure = VerifyFailure.classify(URLError(code), museConfigured: true)
            XCTAssertEqual(failure.kind, .unreachable, "\(code)")
            XCTAssertTrue(failure.message.contains("unreachable"))
        }
    }

    func testClassifyRateLimit() {
        let failure = VerifyFailure.classify(
            VerifierError.serverStatus(429), museConfigured: true
        )
        XCTAssertEqual(failure.kind, .rateLimit)
        XCTAssertTrue(failure.message.contains("rate-limited"))
    }

    func testClassifyNoKeyNeedsUnconfiguredBackend() {
        let noKey = VerifyFailure.classify(
            VerifierError.serverStatus(503), museConfigured: false
        )
        XCTAssertEqual(noKey.kind, .noKey)
        XCTAssertTrue(noKey.message.contains("no API key"))
        let server = VerifyFailure.classify(
            VerifierError.serverStatus(503), museConfigured: true
        )
        XCTAssertEqual(server.kind, .serverError)
        let unknown = VerifyFailure.classify(
            VerifierError.serverStatus(503), museConfigured: nil
        )
        XCTAssertEqual(unknown.kind, .serverError)
    }

    func testClassifyBadResponse() {
        let failure = VerifyFailure.classify(
            VerifierError.invalidResponse("truncated"), museConfigured: true
        )
        XCTAssertEqual(failure.kind, .serverError)
    }

    func testFetchStatusParsesKeyFlag() async {
        let config = VerifierConfig(baseURL: URL(string: "http://example.test:9")!)
        let (session, capture) = stubSession(
            status: 200, body: "{\"status\": \"ok\", \"muse_configured\": false}"
        )
        let status = await VerifierClient(config: config, session: session).fetchStatus()
        XCTAssertEqual(status, BackendStatus(reachable: true, museConfigured: false))
        XCTAssertEqual(capture.request?.url?.path, "/health")
    }

    func testFetchStatusToleratesOldBackend() async {
        let config = VerifierConfig(baseURL: URL(string: "http://example.test:9")!)
        let (session, _) = stubSession(status: 200, body: "{\"status\": \"ok\"}")
        let status = await VerifierClient(config: config, session: session).fetchStatus()
        XCTAssertEqual(status, BackendStatus(reachable: true, museConfigured: nil))
    }

    func testFetchStatusUnreachable() async {
        let config = VerifierConfig(baseURL: URL(string: "http://example.test:9")!)
        let (session, _) = stubSession(status: 503, body: "{}")
        let status = await VerifierClient(config: config, session: session).fetchStatus()
        XCTAssertEqual(status, BackendStatus(reachable: false, museConfigured: nil))
    }

    func testHealthCheck() async {
        let config = VerifierConfig(baseURL: URL(string: "http://example.test:9")!)
        let (okSession, capture) = stubSession(status: 200, body: "{\"status\": \"ok\"}")
        let healthy = await VerifierClient(config: config, session: okSession).checkHealth()
        XCTAssertTrue(healthy)
        XCTAssertEqual(capture.request?.url?.path, "/health")

        let (badSession, _) = stubSession(status: 503, body: "{}")
        let unhealthy = await VerifierClient(config: config, session: badSession).checkHealth()
        XCTAssertFalse(unhealthy)

        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let unreachable = await VerifierClient(
            config: config, session: URLSession(configuration: sessionConfig)
        ).checkHealth()
        XCTAssertFalse(unreachable)
    }

    func testPixelBoxesFlipYAxis() {
        let boxes = VerifyPayload.pixelBoxes(
            [CGRect(x: 0.4, y: 0.65, width: 0.2, height: 0.30)],
            in: CGSize(width: 512, height: 512)
        )
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0][0], 204.8, accuracy: 1e-6)
        XCTAssertEqual(boxes[0][1], 25.6, accuracy: 1e-6)
        XCTAssertEqual(boxes[0][2], 307.2, accuracy: 1e-6)
        XCTAssertEqual(boxes[0][3], 179.2, accuracy: 1e-6)
        XCTAssertLessThan(boxes[0][1], boxes[0][3], "y0 must be above y1")
    }

    func testPixelBoxesScaleToNonSquareFrames() {
        let full = VerifyPayload.pixelBoxes(
            [CGRect(x: 0, y: 0, width: 1, height: 1)], in: CGSize(width: 288, height: 512)
        )
        XCTAssertEqual(full[0], [0, 0, 288, 512])
        XCTAssertEqual(VerifyPayload.pixelBoxes([], in: CGSize(width: 288, height: 512)).count, 0)
    }

    func testClipStartsAtOldestFrameWithPeople() throws {
        let buffer = FrameBuffer(maxFrames: 8)
        let early = CGRect(x: 0.20, y: 0.30, width: 0.2, height: 0.3)
        let late = CGRect(x: 0.30, y: 0.30, width: 0.3, height: 0.5)
        for _ in 0..<3 {
            buffer.append(pixelBuffer: try TestHelpers.makePixelBuffer(), at: 0)
        }
        buffer.append(pixelBuffer: try TestHelpers.makePixelBuffer(), at: 1, boxes: [early])
        for step in 0..<4 {
            buffer.append(
                pixelBuffer: try TestHelpers.makePixelBuffer(), at: Double(2 + step), boxes: [late]
            )
        }
        let clip = buffer.clip()
        XCTAssertEqual(clip.frames.count, 5, "the 3 empty leading frames are dropped")
        XCTAssertEqual(clip.boxes, [early], "boxes are the ones seen on the first clip frame")
    }

    func testClipWithoutPeopleKeepsAllFramesAndNoBoxes() throws {
        let buffer = FrameBuffer(maxFrames: 8)
        for _ in 0..<4 {
            buffer.append(pixelBuffer: try TestHelpers.makePixelBuffer(), at: 0)
        }
        let clip = buffer.clip()
        XCTAssertEqual(clip.frames.count, 4)
        XCTAssertTrue(clip.boxes.isEmpty)
    }

    func testClipBoxesFollowTheRingAsOldFramesDropOut() throws {
        let buffer = FrameBuffer(maxFrames: 4)
        var boxesByStep: [CGRect] = []
        for step in 0..<6 {
            let box = CGRect(x: 0.1 + 0.05 * Double(step), y: 0.3, width: 0.2, height: 0.4)
            boxesByStep.append(box)
            buffer.append(
                pixelBuffer: try TestHelpers.makePixelBuffer(), at: Double(step), boxes: [box]
            )
        }
        let clip = buffer.clip()
        XCTAssertEqual(clip.frames.count, 4)
        XCTAssertEqual(clip.boxes, [boxesByStep[2]])
    }

    func testFrameBufferRing() throws {
        let buffer = FrameBuffer(maxFrames: 8)
        for _ in 0..<10 {
            let pixelBuffer = try TestHelpers.makePixelBuffer(fill: 128)
            buffer.append(pixelBuffer: pixelBuffer, at: 0)
        }
        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.frames.count, 8)
        XCTAssertGreaterThan(snapshot.size.width, 0)
        XCTAssertEqual(snapshot.frames[0].prefix(2), Data([0xFF, 0xD8]))
        XCTAssertLessThanOrEqual(max(snapshot.size.width, snapshot.size.height), 512)
    }

    func testFrameBufferClear() throws {
        let buffer = FrameBuffer()
        let pixelBuffer = try TestHelpers.makePixelBuffer()
        buffer.append(pixelBuffer: pixelBuffer, at: 0)
        buffer.clear()
        XCTAssertEqual(buffer.snapshot().frames.count, 0)
    }
}

final class MockURLProtocol: URLProtocol {
    final class Capture {
        var request: URLRequest?
        var body: Data?
    }

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? {
                let fallback = HTTPURLResponse(
                    url: request.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil
                )!
                return (fallback, Data())
            }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
