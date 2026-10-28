import Foundation

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
