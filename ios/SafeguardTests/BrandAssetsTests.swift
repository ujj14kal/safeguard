import CoreGraphics
import ImageIO
import XCTest

/// The app icon and launch assets are generated from the supplied logo by
/// scripts/make-brand-assets.py. These tests keep the generated files, the
/// asset catalog and the launch-screen wiring honest.
final class BrandAssetsTests: XCTestCase {
    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private var catalog: URL {
        iosRoot.appendingPathComponent("Safeguard/Assets.xcassets")
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// RGBA bytes of an image, drawn over opaque white.
    private func pixels(of image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testAppIconIsOpaque1024Square() throws {
        let url = catalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png")
        let icon = try loadImage(url)
        XCTAssertEqual(icon.width, 1024)
        XCTAssertEqual(icon.height, 1024)
        // App Store icons must have no alpha channel.
        let alpha = icon.alphaInfo
        XCTAssertTrue(
            alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst,
            "icon must be opaque, got \(alpha)"
        )
    }

    func testAppIconShieldIsEnlargedAndCentredOnWhite() throws {
        let icon = try loadImage(catalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
        let bytes = try pixels(of: icon)
        let width = icon.width
        let height = icon.height

        func isPurple(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return (255 - Int(bytes[i])) + (255 - Int(bytes[i + 1])) + (255 - Int(bytes[i + 2])) > 120
        }

        // Corners are pure white (no off-white box around the logo).
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            let i = (y * width + x) * 4
            XCTAssertEqual([bytes[i], bytes[i + 1], bytes[i + 2]], [255, 255, 255])
        }

        var minX = width, maxX = 0, minY = height, maxY = 0
        for y in 0..<height {
            for x in 0..<width where isPurple(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let heightFraction = Double(maxY - minY + 1) / Double(height)
        let widthFraction = Double(maxX - minX + 1) / Double(width)
        // The supplied logo filled only ~58% of its height. Enlarged, but with a
        // margin: iOS rounds the icon corners.
        XCTAssertGreaterThanOrEqual(heightFraction, 0.78, "shield should be enlarged")
        XCTAssertLessThanOrEqual(heightFraction, 0.90, "keep a margin for the rounded mask")
        XCTAssertLessThanOrEqual(widthFraction, 0.80)
        let centreX = Double(minX + maxX) / 2 / Double(width)
        let centreY = Double(minY + maxY) / 2 / Double(height)
        XCTAssertEqual(centreX, 0.5, accuracy: 0.02)
        XCTAssertEqual(centreY, 0.5, accuracy: 0.02)
    }

    func testAppIconUsesTheBrandPurple() throws {
        // #6F3A7C, a bit lighter than the supplied logo's #582560.
        let icon = try loadImage(catalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
        let bytes = try pixels(of: icon)
        var sums = [Double](repeating: 0, count: 3)
        var count = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) where 255 - Int(bytes[i + 1]) > 190 {
            sums[0] += Double(bytes[i]); sums[1] += Double(bytes[i + 1]); sums[2] += Double(bytes[i + 2])
            count += 1
        }
        XCTAssertGreaterThan(count, 50_000, "solid purple area expected")
        XCTAssertEqual(sums[0] / count, 111, accuracy: 3)
        XCTAssertEqual(sums[1] / count, 58, accuracy: 3)
        XCTAssertEqual(sums[2] / count, 124, accuracy: 3)
    }

    func testAppIconContentsReferencesTheFile() throws {
        let url = catalog.appendingPathComponent("AppIcon.appiconset/Contents.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0]["filename"] as? String, "AppIcon.png")
        XCTAssertEqual(images[0]["size"] as? String, "1024x1024")
    }

    func testLaunchLogoIsTheSamePointSizeAt2xAnd3x() throws {
        let dir = catalog.appendingPathComponent("LaunchLogo.imageset")
        let at2x = try loadImage(dir.appendingPathComponent("LaunchLogo@2x.png"))
        let at3x = try loadImage(dir.appendingPathComponent("LaunchLogo@3x.png"))
        // 220 pt tall at both scales, so the launch screen and the splash view
        // draw the logo at the same size on every device.
        XCTAssertEqual(at2x.height, 440)
        XCTAssertEqual(at3x.height, 660)
        XCTAssertEqual(Double(at2x.width) / 2, Double(at3x.width) / 3, accuracy: 1.0)
    }

    func testLaunchScreenIsWiredToTheLogoAndWhiteBackground() throws {
        let plistURL = iosRoot.appendingPathComponent("Safeguard/Supporting/Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL), format: nil
            ) as? [String: Any]
        )
        let launch = try XCTUnwrap(plist["UILaunchScreen"] as? [String: Any])
        XCTAssertEqual(launch["UIImageName"] as? String, "LaunchLogo")
        XCTAssertEqual(launch["UIColorName"] as? String, "LaunchBackground")

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: catalog.appendingPathComponent("LaunchLogo.imageset/Contents.json").path))
        XCTAssertTrue(fm.fileExists(atPath: catalog.appendingPathComponent("LaunchBackground.colorset/Contents.json").path))
    }

    func testLaunchBackgroundIsWhiteInLightAndDarkMode() throws {
        let url = catalog.appendingPathComponent("LaunchBackground.colorset/Contents.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 2, "light and dark variants")
        for entry in colors {
            let color = try XCTUnwrap(entry["color"] as? [String: Any])
            let components = try XCTUnwrap(color["components"] as? [String: String])
            XCTAssertEqual(components["red"], "1.000")
            XCTAssertEqual(components["green"], "1.000")
            XCTAssertEqual(components["blue"], "1.000")
        }
    }
}
