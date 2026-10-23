import XCTest
import Darwin
@testable import ArchiveCore

final class EncodingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-encoding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func storedZIP(name: Data, payload: Data, utf8: Bool = false, extra: Data = Data()) -> Data {
        var data = Data()
        func le(_ value: UInt32, _ count: Int) { for i in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8*i))) } }
        var crc: UInt32 = 0xffff_ffff
        for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 } }
        crc ^= 0xffff_ffff
        le(0x04034b50,4); le(20,2); le(utf8 ? 0x800 : 0,2); le(0,2); le(0,2); le(0,2); le(crc,4)
        le(UInt32(payload.count),4); le(UInt32(payload.count),4); le(UInt32(name.count),2); le(UInt32(extra.count),2); data.append(name); data.append(extra); data.append(payload)
        let offset = data.count
        le(0x02014b50,4); le(20,2); le(20,2); le(utf8 ? 0x800 : 0,2); le(0,2); le(0,2); le(0,2); le(crc,4)
        le(UInt32(payload.count),4); le(UInt32(payload.count),4); le(UInt32(name.count),2)
        le(UInt32(extra.count),2); for _ in 0..<3 { le(0,2) }; le(0,4); le(0,4); data.append(name); data.append(extra)
        let size = data.count - offset
        le(0x06054b50,4); le(0,2); le(0,2); le(1,2); le(1,2); le(UInt32(size),4); le(UInt32(offset),4); le(0,2)
        return data
    }
    func testUnicodeExtraFieldWinsAndAdditionalZIPCodePagesRoundTrip() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"],
              ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Set real engines.") }
        let root = try root(), payload = Data("test".utf8)
        let samples: [(ZIPNameEncoding, PreviewTextEncoding, String)] = [
            (.cp850, .cp850, "café.txt"), (.windows1252, .windows1252, "café–test.txt"),
            (.cp866, .cp866, "Русский.txt"), (.windows1251, .windows1251, "Русский.txt")]
        for (zipEncoding, textEncoding, name) in samples {
            let source = root.appendingPathComponent("\(zipEncoding.codePage!).zip")
            try storedZIP(name: XCTUnwrap(name.data(using: XCTUnwrap(textEncoding.foundationEncoding))), payload: payload).write(to: source)
            let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(source, password: "", using: .sevenZip, encoding: zipEncoding)) { _, _ in }
            XCTAssertEqual(listing.status, 0, listing.stderr)
            XCTAssertEqual(listing.archiveEntries(backend: .sevenZip).first?.path, name)
            let output = try await BatchExtractor.extract(source, parent: root, engine: engine, runner: CLIRunner(), password: "", encoding: zipEncoding, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(name)), payload)
        }
        let raw = try XCTUnwrap("中文旧文件名.txt".data(using: XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)))
        let unicode = Data("Unicode優先.txt".utf8)
        var crc: UInt32 = 0xffff_ffff
        for byte in raw { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 } }
        crc ^= 0xffff_ffff
        var extra = Data([0x75,0x70,UInt8(unicode.count+5),0,1])
        for i in 0..<4 { extra.append(UInt8(truncatingIfNeeded: crc >> (i*8))) }; extra.append(unicode)
        let source = root.appendingPathComponent("unicode-extra.zip")
        try storedZIP(name: raw, payload: payload, extra: extra).write(to: source)
        let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(source, password: "", using: .sevenZip)) { _, _ in }
        XCTAssertEqual(listing.status, 0, listing.stderr)
        XCTAssertEqual(listing.archiveEntries(backend: .sevenZip).first?.path, "Unicode優先.txt")
        let output = try await BatchExtractor.extract(source, parent: root, engine: engine, runner: CLIRunner(), password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Unicode優先.txt")), payload)
    }
    func testLegacyDocumentChoicesAndStrictRoundTrips() throws {
        let samples: [(PreviewTextEncoding, String)] = [
            (.gbk, "中文说明，测试预览。\n"), (.gb18030, "中文说明，测试预览。\n"),
            (.cp932, "日本語テキストのプレビューです。\n"), (.big5, "繁體中文測試預覽。\n"),
            (.korean, "한국어 텍스트 미리보기입니다.\n"), (.cp437, "café résumé\n"),
            (.cp850, "café résumé\n"), (.windows1252, "café – résumé\n"),
            (.cp866, "Русский текст\n"), (.windows1251, "Русский текст\n"),
            (.utf16LE, "中文 🙂\n"), (.utf16BE, "中文 🙂\n")]
        for (encoding, original) in samples {
            let codec = try XCTUnwrap(encoding.foundationEncoding, encoding.rawValue)
            let data = try XCTUnwrap(original.data(using: codec, allowLossyConversion: false), encoding.rawValue)
            let result = try FilePreviewContent.decodeText(data, encoding: encoding)
            XCTAssertEqual(result.text, original, encoding.rawValue)
            XCTAssertFalse(result.inferred)
        }
        let chinese = try XCTUnwrap(String(repeating: "这是中文说明，支持只读文本预览。\n", count: 8).data(using: XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)))
        let result = try FilePreviewContent.decodeText(chinese)
        XCTAssertEqual(result.encoding, "GB18030")
        XCTAssertTrue(result.inferred)
        XCTAssertTrue(result.text.contains("只读文本预览"))
        XCTAssertThrowsError(try FilePreviewContent.decodeText(chinese, encoding: .utf8))
    }
    func testLegacySafetyBOMAndMultibyteBoundary() throws {
        for bytes in [Data([0xc3,0x28]), Data([0,1,2,3]), Data("bplist00fake".utf8), Data([0x50,0x4b,3,4,0xc3,0xc3,0xc3,0xc3])] {
            XCTAssertThrowsError(try FilePreviewContent.decodeText(bytes))
        }
        for encoding in PreviewTextEncoding.allCases {
            XCTAssertThrowsError(try FilePreviewContent.decodeText(Data("hello\0world".utf8), encoding: encoding), encoding.rawValue)
            XCTAssertThrowsError(try FilePreviewContent.decodeText(Data("bplist00fake".utf8), encoding: encoding), encoding.rawValue)
        }
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data([0xff,0xfe,0,0xd8]), encoding: .gb18030))
        let utf8 = Data([0xef,0xbb,0xbf]) + Data("Unicode 中文".utf8)
        XCTAssertEqual(try FilePreviewContent.decodeText(utf8, encoding: .gbk).text, "Unicode 中文")
        XCTAssertEqual(try FilePreviewContent.decodeText(utf8, encoding: .utf16LE).text, "Unicode 中文")
        XCTAssertEqual(try FilePreviewContent.decodeText(utf8, encoding: .utf16BE).text, "Unicode 中文")
        let character = try XCTUnwrap("中".data(using: XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)))
        let prefix = Data(repeating: 65, count: FilePreviewContent.textLimit - 1)
        let result = try FilePreviewContent.decodeText(prefix + character + Data("tail".utf8), encoding: .gbk)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, String(repeating: "A", count: FilePreviewContent.textLimit - 1))
    }
    func testZIPProbeIsBoundedAndHonorsUTF8Flags() throws {
        let root = try root(), zip = root.appendingPathComponent("sample.zip")
        let codec = try XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)
        let name = try XCTUnwrap("中文说明测试文件.txt".data(using: codec))
        try storedZIP(name: name, payload: Data("test".utf8)).write(to: zip)
        XCTAssertEqual(ZIPNameEncoding.auto.resolved(for: zip), .gb18030)
        XCTAssertEqual(ZIPNameEncoding.auto.switches(for: zip), ["-mcp=54936"])
        XCTAssertEqual(ZIPNameEncoding.cp932.switches(for: zip), ["-mcp=932"])
        try storedZIP(name: Data("日本語.txt".utf8), payload: Data(), utf8: true).write(to: zip)
        XCTAssertNil(ZIPFilenameProbe.detect(zip))
        try storedZIP(name: Data("日本語.txt".utf8), payload: Data()).write(to: zip)
        XCTAssertEqual(ZIPFilenameProbe.detect(zip), .utf8)
        try storedZIP(name: Data([0x82]) + Data(".txt".utf8), payload: Data()).write(to: zip)
        XCTAssertEqual(ZIPFilenameProbe.detect(zip), .cp437)
        let fifo = root.appendingPathComponent("pipe.zip")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(ZIPFilenameProbe.detect(fifo))
        let link = root.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zip)
        XCTAssertNil(ZIPFilenameProbe.detect(link))
        for bytes in [Data(), Data(repeating: 0, count: 24), Data([0x50,0x4b,5,6]) + Data(repeating: 0xff, count: 18)] {
            try bytes.write(to: zip); XCTAssertNil(ZIPFilenameProbe.detect(zip))
        }
    }
    func testAutoZIPListingExtractionAndPreviewUseSameEncoding() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"],
              ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Set real archive engines.") }
        let root = try root(), source = root.appendingPathComponent("legacy.zip")
        let original = String(repeating: "中文说明与只读文本预览。\n", count: 8)
        let codec = try XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)
        let payload = try XCTUnwrap(original.data(using: codec)), name = "中文说明测试文件.txt"
        try storedZIP(name: XCTUnwrap(name.data(using: codec)), payload: payload).write(to: source)
        let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(source, password: "", using: .sevenZip)) { _, _ in }
        XCTAssertEqual(listing.status, 0, listing.stderr)
        let rows = listing.archiveEntries(backend: .sevenZip), row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.path, name)
        let stage = root.appendingPathComponent("preview"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let preview = try await SingleFileExporter.export(row, entries: rows, source: source, root: stage, engine: engine, password: "", encoding: .auto, runner: CLIRunner()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: preview), payload)
        XCTAssertEqual(try FilePreviewContent.text(preview).text, original)
        let output = try await BatchExtractor.extract(source, parent: root, engine: engine, runner: CLIRunner(), password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(name)), payload)
    }
    func testEncodingAdapterStillRequiresCorrectPasswordBeforePreview() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"],
              ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Set real engines.") }
        let root = try root(), source = root.appendingPathComponent("encrypted.zip"), input = root.appendingPathComponent("secret.txt")
        let payload = Data("Encrypted preview fixture\n".utf8)
        try payload.write(to: input)
        var options = CreationOptions(); options.format = .zip
        _ = try await ArchiveCreator.create(output: source, inputs: [input], password: "encoding-fixture", headers: false, volumeMB: 0, recovery: 0, options: options, executable: engine, runner: CLIRunner()) { _, _ in }
        let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(source, password: "", using: .sevenZip, encoding: .gb18030)) { _, _ in }
        XCTAssertEqual(listing.status, 0, listing.stderr)
        let rows = listing.archiveEntries(backend: .sevenZip), row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isEncrypted)
        for password in ["", "wrong-fixture", "encoding-fixture"] {
            let stage = try self.root()
            do {
                let url = try await SingleFileExporter.export(row, entries: rows, source: source, root: stage, engine: engine, password: password, encoding: .gb18030, runner: CLIRunner()) { _, _ in }
                XCTAssertEqual(password, "encoding-fixture")
                XCTAssertEqual(try Data(contentsOf: url), payload)
            } catch let error as FileExportPasswordError {
                XCTAssertNotEqual(password, "encoding-fixture")
                XCTAssertEqual(error, password.isEmpty ? .required : .incorrect)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
            }
        }
    }
    @MainActor func testPreviewEncodingSwitchCanRecoverWithoutReextractingAndClosesCleanly() async throws {
        let root = try root(), file = root.appendingPathComponent("short.txt")
        let bytes = try XCTUnwrap("中文".data(using: XCTUnwrap(PreviewTextEncoding.gbk.foundationEncoding)))
        try bytes.write(to: file)
        let session = PreviewSession(), id = session.begin(name: "short.txt", kind: .text)
        session.load(file, ownedRoot: root, requestID: id)
        for _ in 0..<100 where !session.hasTextData { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(session.hasTextData)
        session.setTextEncoding(.utf8)
        for _ in 0..<100 where session.phase == .preparing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        session.setTextEncoding(.gbk)
        for _ in 0..<100 where session.phase == .preparing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.text?.text, "中文")
        session.setTextEncoding(.windows1252); session.close()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(session.phase, .closed)
        XCTAssertFalse(session.hasTextData)
        XCTAssertNil(session.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testOptionalPrivateLegacyZIP() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_LEGACY_ZIP"],
              let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Private legacy ZIP is never bundled.") }
        let source = URL(fileURLWithPath: path), root = try root()
        XCTAssertEqual(ZIPFilenameProbe.detect(source), .gb18030)
        let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(source, password: "", using: .sevenZip)) { _, _ in }
        XCTAssertEqual(listing.status, 0, listing.stderr)
        let rows = listing.archiveEntries(backend: .sevenZip)
        XCTAssertEqual(rows.count, 9)
        let name = "不读我刷成砖.txt", row = try XCTUnwrap(rows.first { $0.path == name })
        let file = try await SingleFileExporter.export(row, entries: rows, source: source, root: root, engine: engine, password: "", encoding: .auto, runner: CLIRunner()) { _, _ in }
        let text = try FilePreviewContent.text(file)
        XCTAssertTrue(text.inferred)
        XCTAssertEqual(text.encoding, "GB18030")
        XCTAssertGreaterThan(text.text.unicodeScalars.filter { (0x4e00...0x9fff).contains($0.value) }.count, 1_000)
        XCTAssertEqual(try Data(contentsOf: file).count, 3_985)
        let output = try await BatchExtractor.extract(source, parent: root, engine: engine, runner: CLIRunner(), password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        for entry in rows where !entry.isDirectory {
            let size = try output.appendingPathComponent(entry.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            XCTAssertEqual(size, Int(entry.size), entry.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("ZY1280最新说明书-V350.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("核实硬件版本再刷对应固件.jpg").path))
    }
}
