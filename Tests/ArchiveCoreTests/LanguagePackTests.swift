import XCTest
@testable import ArchiveCore

final class LanguagePackTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources") }
    func testBuiltinsHaveSameKeysAndValidPlaceholders() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        for id in ["zh-Hans", "ja"] {
            let pack = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/\(id).json")), reference: english)
            XCTAssertEqual(Set(pack.strings.keys), Set(english.strings.keys))
            XCTAssertNotEqual(pack.text("打开", fallback: english), "Open")
        }
        XCTAssertEqual(english.text("{0} 个条目", fallback: nil, values: ["7"]), "7 items")
    }
    func testDemoFallbackAndLiteralSubstitution() throws {
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        let french = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("LocalizationDemo/fr-demo.json")), reference: english)
        XCTAssertEqual(french.text("打开", fallback: english), "Ouvrir")
        XCTAssertEqual(french.text("检测", fallback: english), "Check")
        XCTAssertEqual(english.text("{0} 个条目 · {1}", fallback: nil, values: ["3", "file{0}.rar"]), "3 items · file{0}.rar")
    }
    func testRejectsMalformedPacks() throws {
        func data(_ strings: [String: String], id: String = "xx-demo") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": id, "locale": "en", "name": "Demo", "strings": strings])
        }
        XCTAssertThrowsError(try LanguagePack.decode(data([:], id: "../escape")))
        XCTAssertThrowsError(try LanguagePack.decode(data(["{0} 个条目": "items"])))
        XCTAssertThrowsError(try LanguagePack.decode(data(["打开": "\u{0}Open"])))
        XCTAssertThrowsError(try LanguagePack.decode(Data(repeating: 0, count: 1_048_577)))
        let english = try LanguagePack.decode(Data(contentsOf: resources.appendingPathComponent("Languages/en.json")))
        XCTAssertThrowsError(try LanguagePack.decode(data(["unknown-key": "unknown"]), reference: english))
    }
}
