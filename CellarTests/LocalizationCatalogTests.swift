import XCTest
@testable import Cellar

final class LocalizationCatalogTests: XCTestCase {
    func testAppBundleIncludesAllEightCompiledLocalizations() throws {
        for (language, expected) in [
            ("en", "Refresh"), ("zh-Hans", "刷新"), ("zh-Hant", "重新整理"),
            ("ja", "再読み込み"), ("ko", "새로 고침"), ("de", "Neu laden"),
            ("fr", "Actualiser"), ("es", "Actualizar información"),
        ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Refresh", value: nil, table: nil), expected, language)
        }
    }

    func testSystemLanguageRegionsResolveToSupportedBundleLocalizations() {
        for (preference, expected) in [
            ("en-US", "en"), ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"),
            ("ja-JP", "ja"), ("ko-KR", "ko"), ("de-DE", "de"),
            ("fr-FR", "fr"), ("es-ES", "es"),
        ] {
            XCTAssertEqual(Bundle.preferredLocalizations(
                from: Bundle.main.localizations,
                forPreferences: [preference]
            ).first, expected, preference)
        }
    }

    func testEveryCatalogEntryHasCompleteTranslationsAndMatchingPlaceholders() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@dlf]+"#)
        for (key, entry) in strings {
            let translations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            var signatures: [[String]] = []
            for language in ApplicationLanguage.allCases where language != .system {
                let unit = try XCTUnwrap(translations[language.rawValue]?["stringUnit"] as? [String: String], "\(key): \(language)")
                XCTAssertEqual(unit["state"], "translated", "\(key): \(language)")
                let value = try XCTUnwrap(unit["value"])
                XCTAssertFalse(value.isEmpty, "\(key): \(language)")
                signatures.append(placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                    (value as NSString).substring(with: $0.range)
                })
            }
            for signature in signatures.dropFirst() {
                XCTAssertEqual(signatures[0], signature, key)
            }
        }
    }
}
