import AVFoundation
import CoreMedia
import XCTest

/// URLProtocol stub: records every upload and answers with a chosen status.
final class EvidenceStubProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Int] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var failuresBeforeSuccess = 0
    static let lock = NSLock()

    static func reset(status: Int = 200, failures: Int = 0) {
        lock.withLock {
            requests = []; bodies = []
            self.status = status; failuresBeforeSuccess = failures
        }
    }

    static var count: Int { lock.withLock { requests.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var size = 0
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                size += read
            }
            stream.close()
        }
        let code: Int = Self.lock.withLock {
            Self.requests.append(request)
            Self.bodies.append(size)
            if Self.failuresBeforeSuccess > 0 {
                Self.failuresBeforeSuccess -= 1
                return 503
            }
            return Self.status
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class EvidenceUploadTests: XCTestCase {
    private func makeUploader(policyDelays: [TimeInterval] = [0, 0, 0]) -> EvidenceUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvidenceStubProtocol.self]
        var policy = EvidenceRetryPolicy()
        policy.delays = policyDelays
        return EvidenceUploader(
            config: { VerifierConfig(baseURL: URL(string: "http://10.0.0.5:8000")!) },
            urlSession: URLSession(configuration: config),
            token: nil,
            policy: policy
        )
    }

    private func tempFile(_ bytes: Int = 64) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testSegmentNamesRoundTrip() {
        XCTAssertEqual(EvidenceSegmentName.filename(kind: .video, seq: 3), "video-00003.mp4")
        XCTAssertEqual(EvidenceSegmentName.filename(kind: .audio, seq: 12), "audio-00012.m4a")
        let parsed = EvidenceSegmentName.parse("audio-00012.m4a")
        XCTAssertEqual(parsed?.kind, .audio)
        XCTAssertEqual(parsed?.seq, 12)
        XCTAssertNil(EvidenceSegmentName.parse("video-00001.m4a"))
        XCTAssertNil(EvidenceSegmentName.parse("notes.txt"))
    }

    func testSessionIDMatchesTheBackendRule() {
        let id = EvidenceSessionID.make()
        XCTAssertTrue(id.hasPrefix("sos-"))
        XCTAssertNotNil(id.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression))
        XCTAssertNotEqual(id, EvidenceSessionID.make())
    }

    func testRequestCarriesSessionKindSeqAndExtension() {
        let request = makeUploader().request(sessionID: "sos-abc12345", kind: .audio, seq: 4)
        XCTAssertEqual(request.httpMethod, "POST")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(request.url?.path, "/evidence")
        XCTAssertEqual(items.first { $0.name == "session" }?.value, "sos-abc12345")
        XCTAssertEqual(items.first { $0.name == "kind" }?.value, "audio")
        XCTAssertEqual(items.first { $0.name == "seq" }?.value, "4")
        XCTAssertEqual(items.first { $0.name == "ext" }?.value, "m4a")
    }

    func testRetryPolicyGrowsThenStops() {
        let policy = EvidenceRetryPolicy()
        XCTAssertEqual(policy.delay(beforeRetry: 1), 1)
        XCTAssertEqual(policy.delay(beforeRetry: 6), 60)
        XCTAssertNil(policy.delay(beforeRetry: 7))
        XCTAssertNil(policy.delay(beforeRetry: 0))
    }

    func testUploadSucceedsFirstTry() async throws {
        EvidenceStubProtocol.reset()
        let file = try tempFile()
        let ok = await makeUploader().upload(file: file, sessionID: "sos-abc12345", kind: .video, seq: 0)
        XCTAssertTrue(ok)
        XCTAssertEqual(EvidenceStubProtocol.count, 1)
    }

    func testUploadRetriesThroughServerErrors() async throws {
        EvidenceStubProtocol.reset(failures: 2)
        let file = try tempFile()
        let ok = await makeUploader().upload(file: file, sessionID: "sos-abc12345", kind: .video, seq: 0)
        XCTAssertTrue(ok)
        XCTAssertEqual(EvidenceStubProtocol.count, 3)
    }

    func testUploadGivesUpAfterTheScheduleAndKeepsTheFile() async throws {
        EvidenceStubProtocol.reset(status: 503)
        let file = try tempFile()
        let ok = await makeUploader().upload(file: file, sessionID: "sos-abc12345", kind: .video, seq: 0)
        XCTAssertFalse(ok)
        XCTAssertEqual(EvidenceStubProtocol.count, 4, "first try plus three retries")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectedSegmentIsNotRetried() async throws {
        EvidenceStubProtocol.reset(status: 422)
        let file = try tempFile()
        let ok = await makeUploader().upload(file: file, sessionID: "sos-abc12345", kind: .video, seq: 0)
        XCTAssertFalse(ok)
        XCTAssertEqual(EvidenceStubProtocol.count, 1)
    }

    func testProgressSummary() {
        XCTAssertEqual(
            EvidenceProgress(segments: 3, uploaded: 2, failed: 0).summary,
            "Recording • 2 of 3 parts saved to the cloud"
        )
        XCTAssertTrue(EvidenceProgress(segments: 3, uploaded: 1, failed: 2).summary.contains("2 waiting to retry"))
    }
}

/// The recorder end to end: real audio and video segments are written,
/// uploaded through the stub, and deleted after a successful upload.
final class EvidenceRecorderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-" + UUID().uuidString)
        EvidenceStubProtocol.reset()
    }

    private func recorder() -> EvidenceRecorder {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvidenceStubProtocol.self]
        var policy = EvidenceRetryPolicy()
        policy.delays = [0, 0]
        let uploader = EvidenceUploader(
            config: { VerifierConfig(baseURL: URL(string: "http://10.0.0.5:8000")!) },
            urlSession: URLSession(configuration: config), token: nil, policy: policy
        )
        return EvidenceRecorder(uploader: uploader, root: root)
    }

    private func waitForUploads(_ n: Int, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while EvidenceStubProtocol.count < n, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func audioBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
        return buffer
    }

    private func pixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 96, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    func testNothingIsRecordedBeforeStart() {
        let r = recorder()
        r.appendAudio(audioBuffer())
        r.appendVideo(pixelBuffer(), at: CMTime(value: 0, timescale: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(r.isRecording)
        XCTAssertEqual(EvidenceStubProtocol.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAudioSegmentIsWrittenUploadedAndDeleted() throws {
        let r = recorder()
        let progress = expectation(description: "uploaded")
        progress.assertForOverFulfill = false
        r.start(sessionID: "sos-audiotest01") { p in if p.uploaded == 1 { progress.fulfill() } }
        for _ in 0..<10 { r.appendAudio(audioBuffer()) }
        r.stop()
        wait(for: [progress], timeout: 10)
        let request = try XCTUnwrap(EvidenceStubProtocol.requests.first)
        XCTAssertTrue(request.url!.absoluteString.contains("kind=audio"))
        XCTAssertTrue(request.url!.absoluteString.contains("session=sos-audiotest01"))
        XCTAssertGreaterThan(EvidenceStubProtocol.bodies.first ?? 0, 1000, "real encoded audio was sent")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sos-audiotest01").path)
        XCTAssertEqual(leftovers, [], "the file is deleted after a successful upload")
    }

    func testVideoSegmentIsWrittenAndUploaded() throws {
        let r = recorder()
        let progress = expectation(description: "uploaded")
        progress.assertForOverFulfill = false
        r.start(sessionID: "sos-videotest01") { p in if p.uploaded == 1 { progress.fulfill() } }
        for i in 0..<20 { r.appendVideo(pixelBuffer(), at: CMTime(value: CMTimeValue(i), timescale: 30)) }
        r.stop()
        wait(for: [progress], timeout: 15)
        let request = try XCTUnwrap(EvidenceStubProtocol.requests.first)
        XCTAssertTrue(request.url!.absoluteString.contains("kind=video"))
        XCTAssertTrue(request.url!.absoluteString.contains("ext=mp4"))
        XCTAssertGreaterThan(EvidenceStubProtocol.bodies.first ?? 0, 100)
    }

    func testFailedUploadKeepsTheFileAndRetryPendingSendsIt() throws {
        EvidenceStubProtocol.reset(status: 503)
        let r = recorder()
        let failed = expectation(description: "failed")
        failed.assertForOverFulfill = false
        r.start(sessionID: "sos-retrytest01") { p in if p.failed == 1 { failed.fulfill() } }
        for _ in 0..<10 { r.appendAudio(audioBuffer()) }
        r.stop()
        wait(for: [failed], timeout: 10)
        let folder = root.appendingPathComponent("sos-retrytest01")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["audio-00000.m4a"])

        EvidenceStubProtocol.reset(status: 200)
        r.retryPending()
        waitForUploads(1)
        XCTAssertEqual(EvidenceStubProtocol.count, 1)
        let deadline = Date().addingTimeInterval(5)
        while !(try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
