import CoreVideo
import Foundation
import ImageIO
import Vision

/// On-device person detector (Apple Vision human rectangles + body pose).
/// Behaviour-only pipeline: boxes and facing cues out, no identity, no face
/// recognition. Synchronous; call off the main thread. Orientation defaults
/// to `.up`; the camera delivers upright portrait buffers.
/// Boxes are UPPER-BODY on purpose (see DECISIONS.md): they stay stable when
/// legs are occluded or out of frame, which is what distance-trend needs.
public final class PersonDetector {
    private let poseMatchDistance: Double
    private var poseUnavailable = false
    /// MediaPipe hands/face (gestures + expressions). Nil when the models
    /// are missing or failed to start: the Vision cues below take over.
    private lazy var cueEngine: CueEngine? = CueEngineFactory.make()

    /// - Parameter poseMatchDistance: fallback pose-to-detection matching
    ///   radius (normalized units). Defaults to ThreatConfig's value so all
    ///   numbers live in config.
    public init(poseMatchDistance: Double = ThreatConfig().poseMatchDistance) {
        self.poseMatchDistance = poseMatchDistance
    }

    public func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [DetectedPerson] {
        let rectRequest = VNDetectHumanRectanglesRequest()
        rectRequest.upperBodyOnly = true
        let poseRequest = VNDetectHumanBodyPoseRequest()
        #if targetEnvironment(simulator)
            // The Simulator has no usable GPU/Neural Engine path for Vision and
            // fails with "Could not create inference context". Devices are unaffected.
            rectRequest.usesCPUOnly = true
            poseRequest.usesCPUOnly = true
        #endif
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]
        )
        // Rectangles are critical (tracking must not die); pose is enrichment
        // (facing degrades to unknown). Performed separately so a pose failure
        // — e.g. unsupported in the Simulator — never takes down the frame.
        try LatencyMeter.shared.measure("persons") { try handler.perform([rectRequest]) }
        var detections = (rectRequest.results ?? []).map {
            DetectedPerson(box: $0.boundingBox, confidence: $0.confidence)
        }
        do {
            try LatencyMeter.shared.measure("pose") { try handler.perform([poseRequest]) }
            poseUnavailable = false
            let poses = (poseRequest.results ?? []).map { Self.bodyPose(from: $0) }
            attach(poses: poses, to: &detections)
        } catch {
            if !poseUnavailable {
                poseUnavailable = true
                NSLog(
                    "PersonDetector: body pose unavailable (%@); facing unknown",
                    error.localizedDescription
                )
            }
        }
        attachCues(to: &detections, handler: handler, pixelBuffer: pixelBuffer)
        return detections
    }

    /// Hands and face are enrichment like pose: a failure leaves the frame
    /// with no cues, never without people.
    private func attachCues(
        to detections: inout [DetectedPerson], handler: VNImageRequestHandler,
        pixelBuffer: CVPixelBuffer
    ) {
        guard !detections.isEmpty else { return }
        if let engine = cueEngine, let frame = engine.process(pixelBuffer) {
            attachMediaPipeCues(frame, to: &detections, pixelBuffer: pixelBuffer)
            return
        }
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 6
        let faceRequest = VNDetectFaceLandmarksRequest()
        #if targetEnvironment(simulator)
            handRequest.usesCPUOnly = true
            faceRequest.usesCPUOnly = true
        #endif
        try? handler.perform([handRequest, faceRequest])
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))

        var cues = [GestureCues](repeating: GestureCues(), count: detections.count)
        for hand in handRequest.results ?? [] {
            guard let points = try? hand.recognizedPoints(.all).values
                .filter({ $0.confidence > 0.3 }).map(\.location),
                  let box = Self.boundingBox(of: points),
                  let index = owner(of: box, in: detections)
            else { continue }
            cues[index].hands.append(HandCue(box: box))
        }
        for face in faceRequest.results ?? [] {
            guard let index = owner(of: face.boundingBox, in: detections),
                  let ratio = Self.mouthOpenRatio(face, width: width, height: height)
            else { continue }
            cues[index].mouthOpen = max(cues[index].mouthOpen ?? 0, ratio)
        }
        for index in detections.indices where !cues[index].isEmpty {
            detections[index].cues = cues[index]
        }
    }

    /// Maps MediaPipe hands and faces to their people and classifies them.
    /// Replaces the two Vision requests (hand pose, face landmarks) when
    /// the engine is running, so there is one pass, not two.
    private func attachMediaPipeCues(
        _ frame: MPFrame, to detections: inout [DetectedPerson], pixelBuffer: CVPixelBuffer
    ) {
        var cues = [GestureCues](repeating: GestureCues(), count: detections.count)
        for hand in frame.hands {
            guard let index = owner(of: hand.box, in: detections) else { continue }
            cues[index].hands.append(HandCue(box: hand.box))
            if let gesture = HandGestureClassifier.classify(
                points: hand.points, cannedLabel: hand.cannedLabel,
                cannedScore: hand.cannedScore, box: hand.box
            ) {
                cues[index].gestures.append(gesture)
            }
        }
        for face in frame.faces {
            guard let index = owner(of: face.box, in: detections) else { continue }
            if let ratio = face.mouthOpen {
                cues[index].mouthOpen = max(cues[index].mouthOpen ?? 0, ratio)
            }
            if !face.blendshapes.isEmpty {
                let expression = ExpressionClassifier.classify(blendshapes: face.blendshapes)
                if (cues[index].expression?.score ?? 0) <= expression.score {
                    cues[index].expression = expression
                }
            }
        }
        for index in detections.indices where !cues[index].isEmpty {
            detections[index].cues = cues[index]
        }
    }

    /// The detection whose box, grown to include reaching arms, holds the
    /// centre of `box`; the nearest centre wins when several do.
    private func owner(of box: CGRect, in detections: [DetectedPerson]) -> Int? {
        let centre = CGPoint(x: box.midX, y: box.midY)
        return detections.indices
            .filter {
                let b = detections[$0].box
                return b.insetBy(dx: -b.width * 0.5, dy: -b.height * 0.4).contains(centre)
            }
            .min(by: {
                distance(self.center(of: detections[$0].box), centre)
                    < distance(self.center(of: detections[$1].box), centre)
            })
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    /// Inner-lip height over width, measured in pixels (landmark points are
    /// normalized to the face box, which is not square).
    private static func mouthOpenRatio(
        _ face: VNFaceObservation, width: Double, height: Double
    ) -> Double? {
        guard let lips = face.landmarks?.innerLips?.normalizedPoints, lips.count >= 4,
              let box = boundingBox(of: lips)
        else { return nil }
        let w = Double(box.width) * Double(face.boundingBox.width) * width
        let h = Double(box.height) * Double(face.boundingBox.height) * height
        guard w > 1 else { return nil }
        return h / w
    }

    private static func bodyPose(from observation: VNHumanBodyPoseObservation) -> BodyPose {
        func keypoint(_ joint: VNHumanBodyPoseObservation.JointName) -> BodyPose.Keypoint? {
            guard let point = try? observation.recognizedPoint(joint),
                  point.confidence > 0
            else {
                return nil
            }
            return BodyPose.Keypoint(point: point.location, confidence: point.confidence)
        }
        return BodyPose(
            nose: keypoint(.nose),
            leftEye: keypoint(.leftEye),
            rightEye: keypoint(.rightEye),
            leftShoulder: keypoint(.leftShoulder),
            rightShoulder: keypoint(.rightShoulder)
        )
    }

    /// Attach each pose to the detection containing its nose (falling back to
    /// the nearest detection centre within range). Poses that match nothing
    /// are dropped: no facing evidence is better than wrong evidence.
    private func attach(poses: [BodyPose], to detections: inout [DetectedPerson]) {
        for pose in poses {
            guard let anchor = pose.nose?.point ?? pose.midShoulder() else { continue }
            if let index = detections.indices
                .filter({ detections[$0].box.contains(anchor) })
                .max(by: { detections[$0].confidence < detections[$1].confidence })
            {
                detections[index].pose = pose
                continue
            }
            let nearest = detections.indices.min(by: {
                distance(center(of: detections[$0].box), anchor)
                    < distance(center(of: detections[$1].box), anchor)
            })
            if let nearest,
               distance(center(of: detections[nearest].box), anchor) < poseMatchDistance
            {
                detections[nearest].pose = pose
            }
        }
    }

    private func center(of box: CGRect) -> CGPoint {
        CGPoint(x: box.midX, y: box.midY)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
