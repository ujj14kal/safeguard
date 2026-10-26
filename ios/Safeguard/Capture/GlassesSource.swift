import Foundation

/// Stub for Meta AI glasses input. Roadmap: Meta's Wearables Device Access
/// Toolkit will deliver frames here; everything downstream (detector, tracker,
/// scorer, state machine) already speaks FrameSource and changes not at all.
final class GlassesSource: FrameSource {
    weak var delegate: (any FrameSourceDelegate)?
    var isRunning: Bool { false }
    let displayName = "Meta AI Glasses"

    func start() throws {
        throw FrameSourceError.notAvailable(
            "Glasses input arrives via Meta's Wearables Device Access Toolkit (roadmap). " +
                "Use the phone camera or Replay mode for now."
        )
    }

    func stop() {}
}
