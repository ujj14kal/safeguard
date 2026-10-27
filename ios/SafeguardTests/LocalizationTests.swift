import XCTest

/// Every Localizable key needs a non-empty Hindi value. Reads the
/// catalog the test target compiles (same files as the app).
final class LocalizationTests: XCTestCase {
    private func strings(for language: String) throws -> [String: String] {
        let bundle = Bundle(for: LocalizationTests.self)
        let url = try XCTUnwrap(bundle.url(
            forResource: "Localizable", withExtension: "strings",
            subdirectory: "\(language).lproj"
        ))
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        XCTAssertFalse(dict.isEmpty, "\(language) strings empty")
        return dict
    }

    func testEveryKeyHasNonEmptyHindi() throws {
        let en = try strings(for: "en")
        let hi = try strings(for: "hi")
        for key in en.keys {
            guard let value = hi[key] else {
                XCTFail("missing Hindi value for: \(key)")
                continue
            }
            XCTAssertFalse(value.isEmpty, "empty Hindi value for: \(key)")
        }
        for key in hi.keys {
            XCTAssertNotNil(en[key], "orphan Hindi key: \(key)")
        }
    }

    func testHindiKeepsFormatSpecifiers() throws {
        let en = try strings(for: "en")
        let hi = try strings(for: "hi")
        for (key, english) in en {
            guard let hindi = hi[key] else { continue }
            XCTAssertEqual(
                specifiers(in: hindi), specifiers(in: english),
                "specifier mismatch for: \(key)"
            )
        }
    }

    private func specifiers(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?[@d]")
        let range = NSRange(text.startIndex..., in: text)
        // Positional specifiers (%2$d) let Hindi reorder arguments, so
        // compare the multiset of specifier kinds, not their order.
        return pattern.matches(in: text, range: range).map {
            (text as NSString).substring(with: $0.range)
                .replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression)
        }.sorted()
    }

    func testSpotCheck() throws {
        let hi = try strings(for: "hi")
        XCTAssertEqual(hi["Are you safe?"], "क्या आप सुरक्षित हैं?")
        XCTAssertEqual(hi["SOS"], "SOS")
        XCTAssertEqual(hi["Step %d of %d"], "चरण %d / %d")
    }
}
