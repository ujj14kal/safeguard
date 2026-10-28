import CoreGraphics

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

    public func keypointBox() -> CGRect? {
        let points = [nose, leftEye, rightEye, leftShoulder, rightShoulder]
            .compactMap { $0?.point }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    public func midShoulder() -> CGPoint? {
        guard let left = leftShoulder?.point, let right = rightShoulder?.point else {
            return nil
        }
        return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
    }
}

public struct HandCue: Sendable, Equatable {
    public var box: CGRect

    public init(box: CGRect) {
        self.box = box
    }
}

public struct GestureCues: Sendable, Equatable {
    public var hands: [HandCue]
    public var mouthOpen: Double?
    public var gestures: [HandGestureCue]
    public var expression: ExpressionCue?

    public init(
        hands: [HandCue] = [], mouthOpen: Double? = nil,
        gestures: [HandGestureCue] = [], expression: ExpressionCue? = nil
    ) {
        self.hands = hands
        self.mouthOpen = mouthOpen
        self.gestures = gestures
        self.expression = expression
    }

    public var isEmpty: Bool {
        hands.isEmpty && mouthOpen == nil && gestures.isEmpty && expression == nil
    }
}
