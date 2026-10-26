import CoreGraphics

/// Minimal 2D body pose: the joints the facing heuristic needs.
/// Coordinates are normalized Vision coordinates (origin lower-left).
public struct BodyPose: Sendable, Equatable {
    public struct Keypoint: Sendable, Equatable {
        public var point: CGPoint
        public var confidence: Float

        public init(point: CGPoint, confidence: Float) {
            self.point = point
            self.confidence = confidence
        }
    }

    public var nose: Keypoint?
    public var leftEye: Keypoint?
    public var rightEye: Keypoint?
    public var leftShoulder: Keypoint?
    public var rightShoulder: Keypoint?

    public init(
        nose: Keypoint? = nil,
        leftEye: Keypoint? = nil,
        rightEye: Keypoint? = nil,
        leftShoulder: Keypoint? = nil,
        rightShoulder: Keypoint? = nil
    ) {
        self.nose = nose
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
    }

    /// 0...1 facing-toward-user score. Needs a visible face (nose + eyes) and
    /// a frontal torso (wide shoulder spread). Profile or back-of-head views
    /// score near 0: without a visible face there is no facing evidence.
    public func facingScore(using config: ThreatConfig) -> Double {
        let nose = Double(nose?.confidence ?? 0)
        let eyes = Double(leftEye?.confidence ?? 0) + Double(rightEye?.confidence ?? 0)
        let face = config.facingNoseWeight * nose + config.facingEyeWeight * eyes
        guard let left = leftShoulder?.point, let right = rightShoulder?.point else {
            return min(1, face) * 0.5
        }
        let spread = hypot(left.x - right.x, left.y - right.y)
        let gate = min(1, spread / max(config.facingMinSpread, 1e-6))
        return min(1, face) * gate
    }

    /// Tight box around the known keypoints, for pose-to-detection matching.
    public func keypointBox() -> CGRect? {
        let points = [nose, leftEye, rightEye, leftShoulder, rightShoulder]
            .compactMap { $0?.point }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    /// Mid-shoulder point, used as a fallback association anchor.
    public func midShoulder() -> CGPoint? {
        guard let left = leftShoulder?.point, let right = rightShoulder?.point else {
            return nil
        }
        return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
    }
}

/// One hand seen near a person: its box and how far the person is reaching.
public struct HandCue: Sendable, Equatable {
    /// Normalized Vision box around the visible hand joints.
    public var box: CGRect

    public init(box: CGRect) {
        self.box = box
    }
}

/// Gesture and expression cues from hand pose and face landmarks. Behaviour
/// only: a hand box and a mouth-open ratio, never identity or appearance.
public struct GestureCues: Sendable, Equatable {
    public var hands: [HandCue]
    /// Inner-lip height over width (0 closed, ~0.5+ wide open: shouting,
    /// yelling). Nil when no face landmarks were found for this person.
    public var mouthOpen: Double?

    public init(hands: [HandCue] = [], mouthOpen: Double? = nil) {
        self.hands = hands
        self.mouthOpen = mouthOpen
    }

    public var isEmpty: Bool { hands.isEmpty && mouthOpen == nil }
}
