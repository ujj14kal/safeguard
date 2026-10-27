import XCTest
import CoreLocation
import MapKit
@testable import Safeguard

final class LocationFixPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ accuracy: Double, age: Double = 1, lat: Double = 28.6139, lon: Double = 77.2090
    ) -> LocationSample {
        LocationSample(
            latitude: lat, longitude: lon, accuracy: accuracy,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    func testStaleAndInvalidFixesAreRejected() {
        XCTAssertFalse(LocationFixPolicy.isAcceptable(accuracy: 20, age: 16))
        XCTAssertFalse(LocationFixPolicy.isAcceptable(accuracy: -1, age: 1))
        XCTAssertTrue(LocationFixPolicy.isAcceptable(accuracy: 20, age: 3))
    }

    func testQualityBands() {
        XCTAssertEqual(LocationFixPolicy.quality(accuracy: 10), .precise)
        XCTAssertEqual(LocationFixPolicy.quality(accuracy: 65), .precise)
        XCTAssertEqual(LocationFixPolicy.quality(accuracy: 120), .usable)
        XCTAssertEqual(LocationFixPolicy.quality(accuracy: 900), .coarse)
    }

    func testFirstAcceptableFixIsKept() {
        XCTAssertTrue(LocationFixPolicy.shouldReplace(old: nil, with: sample(500), now: now))
        XCTAssertFalse(LocationFixPolicy.shouldReplace(old: nil, with: sample(20, age: 60), now: now))
    }

    func testCoarseFixNeverReplacesAccurateOne() {
        let good = sample(15, age: 2)
        let coarse = sample(800, age: 0.5)
        XCTAssertFalse(LocationFixPolicy.shouldReplace(old: good, with: coarse, now: now))
    }

    func testBetterAccuracyReplaces() {
        let rough = sample(400, age: 2)
        XCTAssertTrue(LocationFixPolicy.shouldReplace(old: rough, with: sample(30, age: 1), now: now))
    }

    func testWalkingUserIsTrackedNotFrozen() {
        let old = sample(20, age: 5, lat: 28.6139)
        let newer = sample(30, age: 1, lat: 28.6145)
        XCTAssertTrue(LocationFixPolicy.shouldReplace(old: old, with: newer, now: now))
    }

    func testStaleOldFixIsReplacedByAnything() {
        let old = sample(10, age: 40)
        XCTAssertTrue(LocationFixPolicy.shouldReplace(old: old, with: sample(300, age: 1), now: now))
    }

    func testRerouteWhenAccuracyBecomesPreciseAndPositionShifts() {
        let origin = sample(900, lat: 28.6139, lon: 77.2090)
        let current = sample(25, lat: 28.6139, lon: 77.2105) // ~150 m east
        XCTAssertTrue(LocationFixPolicy.shouldReroute(from: origin, to: current))
    }

    func testNoRerouteForJitter() {
        let origin = sample(20)
        let current = sample(18, lat: 28.61395, lon: 77.20905) // a few metres
        XCTAssertFalse(LocationFixPolicy.shouldReroute(from: origin, to: current))
    }

    func testRerouteWhenWalkedFar() {
        let origin = sample(20)
        let current = sample(20, lat: 28.6165) // ~290 m north
        XCTAssertTrue(LocationFixPolicy.shouldReroute(from: origin, to: current))
    }

    func testDistanceIsRoughlyRight() {
        let a = sample(10, lat: 28.6139, lon: 77.2090)
        let b = sample(10, lat: 28.6139, lon: 77.2190)
        let metres = a.distance(to: b)
        XCTAssertEqual(metres, 977, accuracy: 25) // 0.01 deg lon at 28.6N
    }

    func testAccuracyText() {
        XCTAssertEqual(LocationFixPolicy.accuracyText(4), "Location: exact")
        XCTAssertEqual(LocationFixPolicy.accuracyText(23), "Location: about 25 m")
        XCTAssertEqual(LocationFixPolicy.accuracyText(1500), "Location: about 1.5 km")
    }

    func testMapRectNeverTighterThanMinimum() throws {
        let point = CLLocationCoordinate2D(latitude: 28.6139, longitude: 77.2090)
        let rect = try XCTUnwrap(MapFraming.rect(covering: [point], minimumMeters: 600))
        let perMeter = MKMapPointsPerMeterAtLatitude(point.latitude)
        XCTAssertGreaterThanOrEqual(rect.size.width, 600 * perMeter - 1)
        XCTAssertNil(MapFraming.rect(covering: [], minimumMeters: 600))
    }
}
