import CoreGraphics

/// One person detection in a single frame. Behaviour-only: a box plus a
/// confidence, no identity. Box is normalized (0...1) in Vision coordinates
/// (origin at the lower-left).
public struct DetectedPerson: Sendable, Equatable {
    public let box: CGRect
    public let confidence: Float

    public init(box: CGRect, confidence: Float) {
        self.box = box
        self.confidence = confidence
    }
}
