import CoreGraphics

public struct DetectedPerson: Sendable, Equatable {
    public let box: CGRect
    public let confidence: Float
    public var pose: BodyPose?
    public var cues: GestureCues?

    public init(box: CGRect, confidence: Float, pose: BodyPose? = nil, cues: GestureCues? = nil) {
        self.box = box
        self.confidence = confidence
        self.pose = pose
        self.cues = cues
    }
}
