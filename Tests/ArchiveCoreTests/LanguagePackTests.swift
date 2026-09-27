import XCTest
@testable import ArchiveCore

final class LanguagePackTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources") }
    func testBuiltinsHaveSameKeysAndValidPlaceholders() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        XCTAssertEqual(english.schemaVersion, 2)
        XCTAssertEqual(english.sourceLanguage, "en")
        for (key, value) in english.strings { XCTAssertEqual(key, value) }
        for id in ["zh-Hans", "ja"] {
            let pack = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/\(id).json")), reference: english)
            XCTAssertEqual(Set(pack.strings.keys), Set(english.strings.keys))
            XCTAssertNotEqual(pack.text("Open", fallback: english), "Open")
        }
        XCTAssertEqual(english.text("{0} items", fallback: nil, values: ["7"]), "7 items")
    }
    func testDemoFallbackAndLiteralSubstitution() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        let french = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("LocalizationDemo/fr-demo.json")), reference: english)
        XCTAssertEqual(french.text("Open", fallback: english), "Ouvrir")
        XCTAssertEqual(french.text("Check", fallback: english), "Check")
        XCTAssertEqual(english.text("{0} items · {1}", fallback: nil, values: ["3", "file{0}.rar"]), "3 items · file{0}.rar")
    }
    func testRejectsMalformedPacks() throws {
        func data(_ strings: [String: String], id: String = "xx-demo") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "sourceLanguage": "en", "id": id, "locale": "en", "name": "Demo", "strings": strings])
        }
        XCTAssertThrowsError(try LanguagePack.decode(data([:], id: "../escape")))
        XCTAssertThrowsError(try LanguagePack.decode(data(["{0} items": "items"])))
        XCTAssertThrowsError(try LanguagePack.decode(data(["Open": "\u{0}Open"])))
        XCTAssertThrowsError(try LanguagePack.decode(Data(repeating: 0, count: 1_048_577)))
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        XCTAssertThrowsError(try LanguagePack.decode(data(["unknown-key": "unknown"]), reference: english))
    }
    func testEnglishTemplateAndSourceLanguage() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        let template = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("LocalizationDemo/en-template.json")), reference: english)
        XCTAssertEqual(template.strings, english.strings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object["sourceLanguage"] = "zh"
        XCTAssertThrowsError(try LanguagePack.decode(JSONSerialization.data(withJSONObject: object), reference: english))
        object.removeValue(forKey: "sourceLanguage")
        XCTAssertThrowsError(try LanguagePack.decode(JSONSerialization.data(withJSONObject: object), reference: english))
        XCTAssertEqual(template.text("Unknown English label", fallback: english), "Unknown English label")
    }
    func testLegacyPacksMigrateWithoutChangingTranslations() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        let mapping = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: resources.appendingPathComponent("Languages/Legacy/v1-keys.json")))
        func legacy(_ strings: [String: String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "fr-demo", "locale": "fr", "name": "Français", "strings": strings])
        }
        let old = try legacy(["打开": "Ouvrir", "{0} 个条目": "{0} éléments"])
        let pack = try LanguagePack.decode(old, reference: english, legacyKeys: mapping)
        XCTAssertEqual(pack.schemaVersion, 2)
        XCTAssertEqual(pack.sourceLanguage, "en")
        XCTAssertEqual(pack.text("Open", fallback: english), "Ouvrir")
        XCTAssertEqual(pack.text("{0} items", fallback: english, values: ["2"]), "2 éléments")
        XCTAssertEqual(pack.text("Check", fallback: english), "Check")
        XCTAssertEqual(try LanguagePack.decode(JSONEncoder().encode(pack), reference: english).strings, pack.strings)
        XCTAssertThrowsError(try LanguagePack.decode(old, reference: english))
        XCTAssertThrowsError(try LanguagePack.decode(legacy(["未知键": "unknown"]), reference: english, legacyKeys: mapping))
        XCTAssertThrowsError(try LanguagePack.decode(legacy(["{0} 个条目": "éléments"]), reference: english, legacyKeys: mapping))
    }
}
