import CoreVideo
import XCTest

/// Verifier gate edges, client request/response shape, frame buffer.
/// Uses a URLProtocol stub: no network, no keys, fake data only.
final class VerifierTests: XCTestCase {
    // MARK: - Gate

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
        // 0.45 never falls below 0.50 - 0.10: stays disarmed.
        XCTAssertFalse(gate.consume(maxScore: 0.45))
        XCTAssertFalse(gate.consume(maxScore: 0.6))
    }

    func testProximityCannotTrigger() {
        // The gate takes scores only — there is no proximity input to wire
        // up. Low scores stay silent no matter how often they arrive.
        var gate = VerifierGate()
        for _ in 0..<50 {
            XCTAssertFalse(gate.consume(maxScore: 0.2))
        }
    }

    // MARK: - Client

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

    // MARK: - Frame buffer

    func testFrameBufferRing() throws {
        let buffer = FrameBuffer(maxFrames: 8)
        for _ in 0..<10 {
            let pixelBuffer = try TestHelpers.makePixelBuffer(fill: 128)
            buffer.append(pixelBuffer: pixelBuffer, at: 0)
        }
        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.frames.count, 8)
        XCTAssertGreaterThan(snapshot.size.width, 0)
        // Real JPEGs, downscaled to a 512 long edge.
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
