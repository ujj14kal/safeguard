import AVFoundation
import XCTest
@testable import Safeguard

final class HLSEvidenceTests: XCTestCase {
    func testStreamPieceNamesRoundTrip() {
        XCTAssertEqual(EvidenceSegmentName.filename(kind: .initSegment, seq: 0, durationMs: nil), "init.mp4")
        XCTAssertEqual(
            EvidenceSegmentName.filename(kind: .mediaSegment, seq: 7, durationMs: 2000), "seg-00007-2000.m4s"
        )
        let parsed = EvidenceSegmentName.parseAny("seg-00007-2000.m4s")
        XCTAssertEqual(parsed?.kind, .mediaSegment)
        XCTAssertEqual(parsed?.seq, 7)
        XCTAssertEqual(parsed?.durationMs, 2000)
        XCTAssertEqual(EvidenceSegmentName.parseAny("init.mp4")?.kind, .initSegment)
        XCTAssertNotNil(EvidenceSegmentName.parseAny("video-00003.mp4"))
        XCTAssertNil(EvidenceSegmentName.parseAny("notes.txt"))
        XCTAssertNil(EvidenceSegmentName.parseAny("seg-abc-20.m4s"))
    }

    func testMediaPieceUploadCarriesDuration() {
        let uploader = EvidenceUploader()
        let request = uploader.request(sessionID: "s1", kind: .mediaSegment, seq: 3, durationMs: 1800)
        XCTAssertTrue(request.url?.absoluteString.contains("dur=1800") ?? false)
        let plain = uploader.request(sessionID: "s1", kind: .initSegment, seq: 0, durationMs: nil)
        XCTAssertFalse(plain.url?.absoluteString.contains("dur=") ?? true)
    }

    func testMicrophoneBufferBecomesTimedSample() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let pts = CMTime(seconds: 12.5, preferredTimescale: 1_000_000_000)
        let sample = try XCTUnwrap(HLSEvidenceRecorder.sampleBuffer(from: buffer, at: pts))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 480)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), 12.5, accuracy: 0.001)
    }

    func testCaptureUsesStreamFirst() {
        XCTAssertEqual(EvidenceCapture().currentMode, .stream)
        XCTAssertEqual(EvidenceCapture(preferred: .parts).currentMode, .parts)
        XCTAssertFalse(EvidenceCapture().isRecording)
    }
}
