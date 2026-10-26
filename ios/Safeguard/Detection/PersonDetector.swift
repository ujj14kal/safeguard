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
        try handler.perform([rectRequest])
        var detections = (rectRequest.results ?? []).map {
            DetectedPerson(box: $0.boundingBox, confidence: $0.confidence)
        }
        do {
            try handler.perform([poseRequest])
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
        return detections
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
