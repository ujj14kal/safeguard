import CoreGraphics
import CoreVideo
import Foundation

public enum HandGestureKind: String, Sendable, Equatable, CaseIterable {
    case middleFinger
    case fist
    case openPalm
    case pointing
    case thumbsUp
    case thumbsDown
    case peace
    case other
}

public struct HandGestureCue: Sendable, Equatable {
    public var kind: HandGestureKind
    public var score: Double
    public var box: CGRect

    public init(kind: HandGestureKind, score: Double, box: CGRect) {
        self.kind = kind
        self.score = score
        self.box = box
    }

    public var isHostile: Bool { kind == .middleFinger }
}

public enum ExpressionKind: String, Sendable, Equatable, CaseIterable {
    case neutral
    case happy
    case angry
    case sad
    case surprised
}

public struct ExpressionCue: Sendable, Equatable {
    public var kind: ExpressionKind
    public var score: Double

    public init(kind: ExpressionKind, score: Double) {
        self.kind = kind
        self.score = score
    }
}

public struct FingerStates: Sendable, Equatable {
    public var thumb: Bool
    public var index: Bool
    public var middle: Bool
    public var ring: Bool
    public var pinky: Bool
    public var middleDominance: Double

    public var extendedCount: Int {
        [thumb, index, middle, ring, pinky].filter { $0 }.count
    }
}

public enum FingerPose {
    enum Joint {
        static let wrist = 0
        static let thumb = (cmc: 1, mcp: 2, ip: 3, tip: 4)
        static let index = (mcp: 5, pip: 6, dip: 7, tip: 8)
        static let middle = (mcp: 9, pip: 10, dip: 11, tip: 12)
        static let ring = (mcp: 13, pip: 14, dip: 15, tip: 16)
        static let pinky = (mcp: 17, pip: 18, dip: 19, tip: 20)
    }

    public static let extensionRatio: Double = 1.18

    public static func states(from points: [CGPoint]) -> FingerStates? {
        guard points.count >= 21 else { return nil }
        func d(_ a: Int, _ b: Int) -> Double {
            hypot(Double(points[a].x - points[b].x), Double(points[a].y - points[b].y))
        }
        func extended(_ f: (mcp: Int, pip: Int, dip: Int, tip: Int)) -> (Bool, Double) {
            let reach = d(f.tip, Joint.wrist)
            let base = max(d(f.pip, Joint.wrist), 1e-6)
            let ratio = reach / base
            return (ratio >= extensionRatio, ratio)
        }
        let (index, indexRatio) = extended(Joint.index)
        let (middle, middleRatio) = extended(Joint.middle)
        let (ring, ringRatio) = extended(Joint.ring)
        let (pinky, pinkyRatio) = extended(Joint.pinky)
        let thumbReach = d(Joint.thumb.tip, Joint.index.mcp)
        let thumbBase = max(d(Joint.thumb.ip, Joint.index.mcp), 1e-6)
        let thumb = thumbReach / thumbBase >= 1.15

        let others = max(indexRatio, ringRatio, pinkyRatio)
        let dominance = max(0, min(1, (middleRatio - others) / 0.5))
        return FingerStates(
            thumb: thumb, index: index, middle: middle, ring: ring, pinky: pinky,
            middleDominance: dominance
        )
    }
}

public enum HandGestureClassifier {
    static func kind(forCanned label: String?) -> HandGestureKind? {
        switch label {
        case "Closed_Fist": return .fist
        case "Open_Palm": return .openPalm
        case "Pointing_Up": return .pointing
        case "Thumb_Up": return .thumbsUp
        case "Thumb_Down": return .thumbsDown
        case "Victory": return .peace
        case "ILoveYou": return .other
        default: return nil
        }
    }

    public static func classify(
        points: [CGPoint], cannedLabel: String?, cannedScore: Double, box: CGRect
    ) -> HandGestureCue? {
        guard let fingers = FingerPose.states(from: points) else { return nil }
        if fingers.middle, !fingers.index, !fingers.ring, !fingers.pinky,
           fingers.middleDominance >= 0.25
        {
            let score = 0.55 + 0.45 * fingers.middleDominance
            return HandGestureCue(kind: .middleFinger, score: score, box: box)
        }
        if let canned = kind(forCanned: cannedLabel), cannedScore >= 0.5 {
            return HandGestureCue(kind: canned, score: cannedScore, box: box)
        }
        switch fingers.extendedCount {
        case 0, 1 where !fingers.index:
            return HandGestureCue(kind: .fist, score: 0.6, box: box)
        case 5:
            return HandGestureCue(kind: .openPalm, score: 0.6, box: box)
        default:
            if fingers.index, !fingers.middle, !fingers.ring, !fingers.pinky {
                return HandGestureCue(kind: .pointing, score: 0.6, box: box)
            }
            return HandGestureCue(kind: .other, score: 0.4, box: box)
        }
    }
}

public enum ExpressionClassifier {
    public static let minimumScore: Double = 0.35

    public static func classify(blendshapes b: [String: Float]) -> ExpressionCue {
        func v(_ name: String) -> Double { Double(b[name] ?? 0) }
        func pair(_ base: String) -> Double { (v(base + "Left") + v(base + "Right")) / 2 }

        let smile = pair("mouthSmile")
        let frown = pair("mouthFrown")
        let browDown = pair("browDown")
        let browUp = max(v("browInnerUp"), pair("browOuterUp"))
        let squint = pair("eyeSquint")
        let wide = pair("eyeWide")
        let jaw = v("jawOpen")
        let press = pair("mouthPress")
        let sneer = pair("noseSneer")
        let cheek = pair("cheekSquint")

        let scores: [ExpressionKind: Double] = [
            .happy: clamp(smile * 1.3 + cheek * 0.4 - frown),
            .angry: clamp(browDown * 1.2 + sneer * 0.6 + press * 0.4 + squint * 0.3 - smile),
            .sad: clamp(frown * 0.9 + browUp * 0.9 - smile - browDown * 0.3),
            .surprised: clamp(wide * 0.7 + browUp * 0.4 + jaw * 0.7 - browDown),
        ]
        if let best = scores.max(by: { $0.value < $1.value }), best.value >= minimumScore {
            return ExpressionCue(kind: best.key, score: best.value)
        }
        return ExpressionCue(kind: .neutral, score: 1 - (scores.values.max() ?? 0))
    }

    private static func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
}

public struct FrameCues: Sendable, Equatable {
    public var gestures: [HandGestureCue]
    public var expression: ExpressionCue?

    public init(gestures: [HandGestureCue] = [], expression: ExpressionCue? = nil) {
        self.gestures = gestures
        self.expression = expression
    }

    public var isEmpty: Bool { gestures.isEmpty && expression == nil }

    public func hostile(minScore: Double) -> HandGestureCue? {
        gestures.filter { $0.isHostile && $0.score >= minScore }.max { $0.score < $1.score }
    }

    public var summary: String {
        var parts = gestures.filter { $0.kind != .other }.map {
            String(format: "%@ %.2f", $0.kind.rawValue, $0.score)
        }
        if let expression, expression.kind != .neutral {
            parts.append(String(format: "%@ %.2f", expression.kind.rawValue, expression.score))
        }
        return parts.joined(separator: " • ")
    }
}

struct MPHand {
    var points: [CGPoint]
    var box: CGRect
    var cannedLabel: String?
    var cannedScore: Double
}

struct MPFace {
    var box: CGRect
    var blendshapes: [String: Float]
    var mouthOpen: Double?
}

struct MPFrame {
    var hands: [MPHand]
    var faces: [MPFace]
}

protocol CueEngine: AnyObject {
    func process(_ pixelBuffer: CVPixelBuffer) -> MPFrame?
}

enum CueEngineFactory {
    nonisolated(unsafe) static var make: () -> CueEngine? = { nil }
}
