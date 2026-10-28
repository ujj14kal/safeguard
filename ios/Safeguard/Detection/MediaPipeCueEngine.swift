import CoreGraphics
import CoreVideo
import Foundation
import MediaPipeTasksVision

final class MediaPipeCueEngine: CueEngine {
    private let gestures: GestureRecognizer
    private let faces: FaceLandmarker
    private var lastTimestampMs = 0

    init?() {
        guard let gesturePath = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task"),
              let facePath = Bundle.main.path(forResource: "face_landmarker", ofType: "task")
        else {
            NSLog("MediaPipeCueEngine: model files missing; using Vision cues")
            return nil
        }
        do {
            let g = GestureRecognizerOptions()
            g.baseOptions.modelAssetPath = gesturePath
            g.runningMode = .video
            g.numHands = 4
            g.minHandDetectionConfidence = 0.4
            g.minHandPresenceConfidence = 0.4
            g.minTrackingConfidence = 0.4
            let f = FaceLandmarkerOptions()
            f.baseOptions.modelAssetPath = facePath
            f.runningMode = .video
            f.numFaces = 4
            f.outputFaceBlendshapes = true
            f.minFaceDetectionConfidence = 0.4
            f.minFacePresenceConfidence = 0.4
            f.minTrackingConfidence = 0.4
            #if !targetEnvironment(simulator)
                g.baseOptions.delegate = .GPU
                f.baseOptions.delegate = .GPU
            #endif
            gestures = try GestureRecognizer(options: g)
            faces = try FaceLandmarker(options: f)
        } catch {
            NSLog("MediaPipeCueEngine: failed to start (%@); using Vision cues", error.localizedDescription)
            return nil
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer) -> MPFrame? {
        guard let image = try? MPImage(pixelBuffer: pixelBuffer) else { return nil }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let now = Int(ProcessInfo.processInfo.systemUptime * 1000)
        lastTimestampMs = max(now, lastTimestampMs + 1)

        var outHands: [MPHand] = []
        if let result = try? LatencyMeter.shared.measure("hands", {
            try gestures.recognize(videoFrame: image, timestampInMilliseconds: lastTimestampMs)
        }) {
            for (i, landmarks) in result.landmarks.enumerated() where landmarks.count >= 21 {
                let pixel = landmarks.map { CGPoint(x: Double($0.x) * width, y: (1 - Double($0.y)) * height) }
                let normalized = landmarks.map { CGPoint(x: Double($0.x), y: 1 - Double($0.y)) }
                guard let box = Self.box(of: normalized) else { continue }
                let top = result.gestures.indices.contains(i) ? result.gestures[i].first : nil
                outHands.append(MPHand(
                    points: pixel, box: box,
                    cannedLabel: top?.categoryName, cannedScore: Double(top?.score ?? 0)
                ))
            }
        }

        var outFaces: [MPFace] = []
        if let result = try? LatencyMeter.shared.measure("face", {
            try faces.detect(videoFrame: image, timestampInMilliseconds: lastTimestampMs)
        }) {
            for (i, landmarks) in result.faceLandmarks.enumerated() where landmarks.count > 308 {
                let normalized = landmarks.map { CGPoint(x: Double($0.x), y: 1 - Double($0.y)) }
                guard let box = Self.box(of: normalized) else { continue }
                var shapes: [String: Float] = [:]
                if result.faceBlendshapes.indices.contains(i) {
                    for category in result.faceBlendshapes[i].categories {
                        if let name = category.categoryName { shapes[name] = category.score }
                    }
                }
                let openH = abs(Double(landmarks[13].y - landmarks[14].y)) * height
                let openW = abs(Double(landmarks[78].x - landmarks[308].x)) * width
                outFaces.append(MPFace(
                    box: box, blendshapes: shapes, mouthOpen: openW > 1 ? openH / openW : nil
                ))
            }
        }
        return MPFrame(hands: outHands, faces: outFaces)
    }

    private static func box(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }
}
