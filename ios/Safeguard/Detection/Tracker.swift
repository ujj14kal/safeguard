import CoreGraphics

/// A person tracked across frames with a stable ID.
public struct Track: Sendable, Equatable {
    public let id: Int
    public var box: CGRect
    public var confidence: Float
    /// Frames this track has been matched to a detection.
    public var age: Int
    /// Consecutive frames without a matching detection (coasting).
    public var missed: Int
    /// Latest matched pose (kept while coasting; may be nil).
    public var pose: BodyPose?
    /// Latest hand/face cues (nil when none were seen this frame).
    public var cues: GestureCues?

    public init(
        id: Int, box: CGRect, confidence: Float, age: Int, missed: Int,
        pose: BodyPose? = nil,
        cues: GestureCues? = nil
    ) {
        self.id = id
        self.box = box
        self.confidence = confidence
        self.age = age
        self.missed = missed
        self.pose = pose
        self.cues = cues
    }
}

/// Intersection-over-union of two normalized boxes. 0 when disjoint or degenerate.
public func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    guard !inter.isNull else { return 0 }
    let interArea = Double(inter.width * inter.height)
    guard interArea > 0 else { return 0 }
    let union = Double(a.width * a.height + b.width * b.height) - interArea
    guard union > 0 else { return 0 }
    return interArea / union
}

/// Greedy IoU tracker: matches detections to tracks by descending IoU,
/// coasts unmatched tracks for `maxMissedFrames`, then drops them.
/// Not thread-safe: call from one serial queue.
public final class IoUTracker {
    public var iouThreshold: Double
    public var maxMissedFrames: Int

    private var nextID = 1
    private var tracks: [Track] = []

    public init(iouThreshold: Double = 0.3, maxMissedFrames: Int = 10) {
        self.iouThreshold = iouThreshold
        self.maxMissedFrames = maxMissedFrames
    }

    /// Match detections to tracks. Returns all live tracks (matched and
    /// coasting) sorted by ID; a track coasts exactly `maxMissedFrames`
    /// frames before being dropped.
    @discardableResult
    public func update(detections: [DetectedPerson]) -> [Track] {
        var pairs: [(iou: Double, track: Int, detection: Int)] = []
        for (trackIndex, track) in tracks.enumerated() {
            for (detectionIndex, detection) in detections.enumerated() {
                let iou = intersectionOverUnion(track.box, detection.box)
                if iou >= iouThreshold {
                    pairs.append((iou, trackIndex, detectionIndex))
                }
            }
        }
        pairs.sort { $0.iou > $1.iou }

        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()
        var matchForTrack: [Int: DetectedPerson] = [:]
        for pair in pairs where !matchedTracks.contains(pair.track)
            && !matchedDetections.contains(pair.detection)
        {
            matchedTracks.insert(pair.track)
            matchedDetections.insert(pair.detection)
            matchForTrack[pair.track] = detections[pair.detection]
        }

        for index in tracks.indices {
            if let detection = matchForTrack[index] {
                tracks[index].box = detection.box
                tracks[index].confidence = detection.confidence
                tracks[index].missed = 0
                tracks[index].age += 1
                tracks[index].pose = detection.pose
                tracks[index].cues = detection.cues
            } else {
                tracks[index].missed += 1
            }
        }
        tracks.removeAll { $0.missed > maxMissedFrames }

        for (index, detection) in detections.enumerated()
            where !matchedDetections.contains(index)
        {
            tracks.append(Track(
                id: nextID, box: detection.box,
                confidence: detection.confidence, age: 1, missed: 0,
                pose: detection.pose, cues: detection.cues
            ))
            nextID += 1
        }
        return tracks.sorted { $0.id < $1.id }
    }

    public func reset() {
        tracks = []
        nextID = 1
    }
}
