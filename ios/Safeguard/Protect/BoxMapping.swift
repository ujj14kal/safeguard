import CoreGraphics
import Foundation

public enum AspectFillMapper {
    public static func boxRect(_ box: CGRect, frame: CGSize, view: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0, view.width > 0, view.height > 0 else {
            return .zero
        }
        let scale = max(view.width / frame.width, view.height / frame.height)
        let scaled = CGSize(width: frame.width * scale, height: frame.height * scale)
        let dx = (view.width - scaled.width) / 2
        let dy = (view.height - scaled.height) / 2
        return CGRect(
            x: dx + box.minX * scaled.width,
            y: dy + (1 - box.maxY) * scaled.height,
            width: box.width * scaled.width,
            height: box.height * scaled.height
        )
    }
}

public enum PersonBoxLevel {
    public static func level(
        alert: Bool, height: Double, config: ThreatConfig
    ) -> Proximity {
        if alert || height >= config.tooCloseHeight {
            return .tooClose
        }
        if height >= config.nearHeight {
            return .near
        }
        return .clear
    }
}

public struct HudStatus: Sendable, Equatable {
    public var text: String
    public var symbol: String

    public init(text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    public static func resolve(
        asking: Bool = false,
        safe: Bool = false,
        listeningWindow: Bool = false,
        alert: Bool = false,
        proximity: Proximity = .clear,
        listenerLive: Bool = false
    ) -> HudStatus {
        if asking {
            return HudStatus(text: String(localized: "Are you safe?"), symbol: "questionmark.circle.fill")
        }
        if safe {
            return HudStatus(text: String(localized: "You're safe"), symbol: "checkmark.shield.fill")
        }
        if listeningWindow {
            return HudStatus(text: String(localized: "Stay quiet, listening"), symbol: "ear.fill")
        }
        if alert {
            return HudStatus(text: String(localized: "Something seems off"), symbol: "exclamationmark.shield.fill")
        }
        switch proximity {
        case .tooClose:
            return HudStatus(text: String(localized: "Too close"), symbol: "exclamationmark.triangle.fill")
        case .near:
            return HudStatus(text: String(localized: "Someone is near"), symbol: "person.fill")
        case .clear:
            break
        }
        if listenerLive {
            return HudStatus(text: String(localized: "Listening"), symbol: "mic.fill")
        }
        return HudStatus(text: String(localized: "Protecting"), symbol: "shield.fill")
    }
}
