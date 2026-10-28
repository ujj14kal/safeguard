import UIKit

public enum AvatarImage {
    public static let maxSide: CGFloat = 512
    public static let maxBytes = 450_000

    public static func jpeg(from image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let target = min(side, maxSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        let square = renderer.image { _ in
            let scale = target / side
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (target - drawn.width) / 2, y: (target - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
        }
        for quality in stride(from: 0.85, through: 0.3, by: -0.15) {
            if let data = square.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
        }
        return square.jpegData(compressionQuality: 0.2)
    }

    public static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
