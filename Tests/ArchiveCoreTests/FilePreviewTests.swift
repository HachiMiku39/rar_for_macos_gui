import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import ArchiveCore

final class FilePreviewTests: XCTestCase {
    func testEncryptedEntryListingPreservesPerFileFlag() {
        let listing = "Path = folder/secret.txt\nSize = 3\nEncrypted = +\n\nPath = folder/plain.txt\nSize = 5\nEncrypted = -\n\nPath = folder/\nFolder = +\n"
        let rows = ArchiveCommands.parse(listing, backend: .sevenZip)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].isEncrypted)
        XCTAssertFalse(rows[1].isEncrypted)
        XCTAssertFalse(rows[2].isEncrypted)
    }
    func testPasswordDiagnosticDoesNotMisclassifyCRCOrCancellation() {
        func result(_ message: String, status: Int32 = 2, cancelled: Bool = false) -> CLIResult {
            CLIResult(status: status, stdout: "", stderr: message, cancelled: cancelled, listingOutput: "")
        }
        XCTAssertTrue(FileExportPasswordError.isPasswordFailure(result("ERROR: Data Error in encrypted file. Wrong password? : secret.txt")))
        XCTAssertTrue(FileExportPasswordError.isPasswordFailure(result("ERROR: Wrong password : secret.txt")))
        XCTAssertTrue(FileExportPasswordError.isPasswordFailure(result("  0%\u{8}\u{8}    \u{8}ERROR: Wrong password : secret.txt")))
        XCTAssertFalse(FileExportPasswordError.isPasswordFailure(result("ERROR: CRC Failed : note.txt")))
        XCTAssertFalse(FileExportPasswordError.isPasswordFailure(result("ERROR: Data Error : note.txt")))
        XCTAssertFalse(FileExportPasswordError.isPasswordFailure(result("Wrong password", status: 0)))
        XCTAssertFalse(FileExportPasswordError.isPasswordFailure(result("Wrong password", cancelled: true)))
    }
    func testEncryptedTextExportPasswordRetryAndNoPlaintextOnFailure() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ.") }
        let root = try root(), file = root.appendingPathComponent("secret.txt"), archive = root.appendingPathComponent("encrypted.zip")
        let payload = Data("Private preview fixture — 中文 日本語\n".utf8)
        try payload.write(to: file)
        var options = CreationOptions(); options.format = .zip
        _ = try await ArchiveCreator.create(output: archive, inputs: [file], password: "fixture-preview", headers: false, volumeMB: 0, recovery: 0, options: options, executable: engine, runner: CLIRunner()) { _, _ in }
        let listing = try await CLIRunner().run(executable: engine, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip), update: { _, _ in })
        let rows = listing.archiveEntries(backend: .sevenZip)
        let row = try XCTUnwrap(rows.first { $0.path == "secret.txt" })
        XCTAssertTrue(row.isEncrypted)
        for secret in ["", "incorrect-fixture-password"] {
            let stage = try self.root()
            var diagnostic = ""
            do {
                _ = try await SingleFileExporter.export(row, entries: rows, source: archive, root: stage, engine: engine, password: secret, encoding: .auto, runner: CLIRunner()) { _, b in diagnostic = b }
                XCTFail("Locked text must never become a preview URL")
            } catch let error as FileExportPasswordError {
                switch error {
                case .required: XCTAssertTrue(secret.isEmpty)
                case .incorrect: XCTAssertFalse(secret.isEmpty)
                }
            } catch {
                XCTFail("Expected a typed password failure, got \(error); engine: \(diagnostic)")
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        }
        let stage = try self.root()
        let extracted = try await SingleFileExporter.export(row, entries: rows, source: archive, root: stage, engine: engine, password: "fixture-preview", encoding: .auto, runner: CLIRunner()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: extracted), payload)
        XCTAssertEqual(try FilePreviewContent.text(extracted).text, String(decoding: payload, as: UTF8.self))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-preview-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wav() -> Data {
        var data = Data("RIFF".utf8)
        func le(_ value: UInt32, _ count: Int) { for index in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) } }
        le(36 + 48000 * 4, 4); data.append(Data("WAVEfmt ".utf8)); le(16, 4); le(1, 2); le(2, 2)
        le(48000, 4); le(48000 * 4, 4); le(4, 2); le(16, 2); data.append(Data("data".utf8)); le(48000 * 4, 4)
        data.append(Data(repeating: 0, count: 48000 * 4))
        return data
    }
    func testRoutingDoesNotEnableExternalExecution() {
        let row = ArchiveEntry(path: "folder/main.swift", size: "1", modified: "", isDirectory: false, isLink: false)
        XCTAssertEqual(row.previewKind, .text)
        XCTAssertFalse(row.canOpenCopy)
        XCTAssertNil(ArchiveEntry(path: "App.app/icon.png", size: "1", modified: "", isDirectory: false, isLink: false).previewKind)
        XCTAssertNil(ArchiveEntry(path: "../image.png", size: "1", modified: "", isDirectory: false, isLink: false).previewKind)
        XCTAssertNil(ArchiveEntry(path: "image.png", size: "1", modified: "", isDirectory: false, isLink: true).previewKind)
        XCTAssertEqual(FilePreviewKind.forPath("test.SVG"), .text)
        XCTAssertNil(FilePreviewKind.forPath("archive.zip"))
        XCTAssertNil(FilePreviewKind.forPath("run.command"))
        XCTAssertNil(FilePreviewKind.forPath("stream.m3u8"))
    }
    func testUnicodeAndBOMDecoding() throws {
        let text = "简体中文 繁體中文 日本語 한국어 Русский العربية 🪄 e\u{301}\n"
        XCTAssertEqual(try FilePreviewContent.decodeText(Data(text.utf8)).text, text)
        XCTAssertEqual(try FilePreviewContent.decodeText(Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)).text, text)
        for (bom, encoding) in [(Data([0xff, 0xfe]), String.Encoding.utf16LittleEndian), (Data([0xfe, 0xff]), .utf16BigEndian)] {
            XCTAssertEqual(try FilePreviewContent.decodeText(bom + XCTUnwrap(text.data(using: encoding))).text, text)
        }
        XCTAssertEqual(try FilePreviewContent.decodeText(Data()).text, "")
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data([0xff, 0xfe, 0x00])))
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data([0xff, 0xfe, 0x00, 0xd8])))
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data([0xff, 0xfe, 0, 0])))
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data([0xc3, 0x28])))
        XCTAssertThrowsError(try FilePreviewContent.decodeText(Data("hello\u{0}world".utf8)))
        let tag = NativeMediaPreview.boundedTag("e" + String(repeating: "\u{301}", count: 10000))
        XCTAssertLessThanOrEqual(tag.text.utf8.count, 2048)
        XCTAssertTrue(tag.limited)
        XCTAssertEqual(NativeMediaPreview.boundedTag("a\u{0}b").text, "ab")
    }
    func testTruncatedUnicodeAndPlainMarkup() throws {
        let input = Data(repeating: 65, count: FilePreviewContent.textLimit - 1) + Data("🪄tail".utf8)
        let result = try FilePreviewContent.decodeText(input)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, FilePreviewContent.textLimit - 1)
        let utf16 = Data([0xff, 0xfe]) + Data(repeating: 0x20, count: FilePreviewContent.textLimit - 4) + Data([0x3e, 0xd8, 0x84, 0xde])
        XCTAssertTrue(try FilePreviewContent.decodeText(utf16).truncated)
        let html = "<script>fetch('https://invalid.example')</script>"
        XCTAssertEqual(try FilePreviewContent.decodeText(Data(html.utf8)).text, html)
    }
    func testBoundedReadRejectsLinksDevicesAndLargeFiles() throws {
        let root = try root(), file = root.appendingPathComponent("text.txt")
        try Data(repeating: 65, count: FilePreviewContent.textLimit * 2).write(to: file)
        XCTAssertTrue(try FilePreviewContent.text(file).truncated)
        XCTAssertEqual(try FilePreviewContent.readPrefix(file, limit: 16).count, 16)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try FilePreviewContent.text(link))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try FilePreviewContent.readPrefix(fifo, limit: 16))
        XCTAssertThrowsError(try FilePreviewContent.readPrefix(URL(string: "https://example.com/video.mp4")!, limit: 16))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PreviewSafety.maximumBytes) + 1); try handle.close()
        XCTAssertThrowsError(try FilePreviewContent.readPrefix(file, limit: 16))
    }
    func testDownsampleAndMalformedImage() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 512 * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let thumbnail = try FilePreviewContent.thumbnail(data as Data, maximumEdge: 128)
        XCTAssertEqual(thumbnail.width, 128); XCTAssertEqual(thumbnail.height, 64)
        XCTAssertThrowsError(try FilePreviewContent.thumbnail(Data("not an image".utf8), maximumEdge: 128))
    }
    func testMediaHeadersRejectPlaylistsAndExternalReferences() throws {
        XCTAssertFalse(FilePreviewContent.isMediaHeader(Data("#EXTM3U\nhttps://example.com/stream.ts".utf8)))
        XCTAssertFalse(FilePreviewContent.isMediaHeader(Data("<ASX><REF HREF='file:///etc/passwd'/></ASX>".utf8)))
        let root = try root(), file = root.appendingPathComponent("track.wav")
        try wav().write(to: file)
        let asset = try NativeMediaPreview.asset(file)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
        try Data("#EXTM3U\nhttps://example.com/stream.ts".utf8).write(to: file)
        XCTAssertThrowsError(try NativeMediaPreview.asset(file))
    }
    func testNativeAudioInspection() async throws {
        let file = try root().appendingPathComponent("track.wav")
        try wav().write(to: file)
        let details = try await NativeMediaPreview.inspect(NativeMediaPreview.asset(file))
        XCTAssertEqual(details.duration, 1, accuracy: 0.01)
        XCTAssertFalse(details.hasVideo)
        XCTAssertTrue(details.tags.isEmpty)
    }
    @MainActor func testSessionCloseAndStaleResultCleanup() async throws {
        let session = PreviewSession(), firstRoot = try root(), secondRoot = try root()
        let first = firstRoot.appendingPathComponent("first.txt"), second = secondRoot.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let old = session.begin(name: "first.txt", kind: .text)
        let current = session.begin(name: "second.txt", kind: .text)
        session.load(first, ownedRoot: firstRoot, requestID: old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRoot.path))
        session.load(second, ownedRoot: secondRoot, requestID: current)
        for _ in 0..<200 where session.phase == .preparing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.phase, .ready); XCTAssertEqual(session.text?.text, "second")
        session.fail("late error", requestID: old)
        XCTAssertEqual(session.phase, .ready)
        session.close()
        XCTAssertNil(session.text); XCTAssertNil(session.player); XCTAssertNil(session.requestID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondRoot.path))
    }
    @MainActor func testImmediateCancellationCannotReopenPreview() async throws {
        let session = PreviewSession(), root = try root(), file = root.appendingPathComponent("track.wav")
        try wav().write(to: file)
        let id = session.begin(name: "track.wav", kind: .audio)
        session.load(file, ownedRoot: root, requestID: id); session.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.phase, .closed); XCTAssertNil(session.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testClosingLoadedPlayerReleasesItemAndObservers() async throws {
        let session = PreviewSession(), root = try root(), file = root.appendingPathComponent("track.wav")
        try wav().write(to: file)
        let id = session.begin(name: "track.wav", kind: .audio)
        session.load(file, ownedRoot: root, requestID: id)
        for _ in 0..<200 where session.phase == .preparing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.phase, .ready)
        let player = try XCTUnwrap(session.player)
        XCTAssertNotNil(player.currentItem); XCTAssertEqual(player.rate, 0, "Preview must not autoplay")
        session.seek(to: 0.5)
        session.volume = 0.25
        XCTAssertEqual(player.volume, 0.25)
        session.close()
        XCTAssertNil(player.currentItem); XCTAssertEqual(player.rate, 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(session.position, 0); XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testDecoderFailureIsNotAnArchiveFailure() async throws {
        let session = PreviewSession(), root = try root(), file = root.appendingPathComponent("bad.mp4")
        try Data("not a movie".utf8).write(to: file)
        let id = session.begin(name: "bad.mp4", kind: .video)
        session.load(file, ownedRoot: root, requestID: id)
        for _ in 0..<200 where session.phase == .preparing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.phase, .failed); XCTAssertNil(session.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        session.close()
    }
    func testOptionalVideoAndMusicFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_MEDIA"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_MEDIA to generated media fixtures.") }
        let directory = URL(fileURLWithPath: path)
        let video = try await NativeMediaPreview.inspect(NativeMediaPreview.asset(directory.appendingPathComponent("sample.mp4")))
        XCTAssertTrue(video.hasVideo); XCTAssertGreaterThan(video.duration, 1)
        let music = try await NativeMediaPreview.inspect(NativeMediaPreview.asset(directory.appendingPathComponent("cover.mp3")))
        XCTAssertFalse(music.hasVideo); XCTAssertNotNil(music.artwork)
        XCTAssertEqual(music.tags.first { $0.label == "Title" }?.value, "Preview 日本語 中文")
    }
    func testEncryptedMediaMustPassPasswordAndCRCBeforePreview() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ.") }
        let root = try root(), file = root.appendingPathComponent("track.wav"), payload = wav()
        try payload.write(to: file)
        let row = ArchiveEntry(path: "track.wav", size: String(payload.count), modified: "", isDirectory: false, isLink: false)
        for format in [CreationFormat.zip, .sevenZip] {
            var options = CreationOptions(); options.format = format
            let archive = root.appendingPathComponent("encrypted." + format.rawValue)
            _ = try await ArchiveCreator.create(output: archive, inputs: [file], password: "preview-test", headers: true, volumeMB: 0, recovery: 0,
                                               options: options, executable: engine, runner: CLIRunner()) { _, _ in }
            let wrong = try self.root()
            do {
                _ = try await SingleFileExporter.export(row, entries: [row], source: archive, root: wrong, engine: engine, password: "wrong-password", encoding: .auto, runner: CLIRunner()) { _, _ in }
                XCTFail("Wrong password must not return a preview URL")
            } catch { /* A partial output is never sent to the preview session. */ }
            let correct = try self.root()
            let extracted = try await SingleFileExporter.export(row, entries: [row], source: archive, root: correct, engine: engine, password: "preview-test", encoding: .auto, runner: CLIRunner()) { _, _ in }
            try PreviewSafety.validate(extracted, inside: correct)
            let details = try await NativeMediaPreview.inspect(NativeMediaPreview.asset(extracted))
            XCTAssertEqual(details.duration, 1, accuracy: 0.01)
        }
    }
    func testCorruptedEntryCannotBecomePreviewURL() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ.") }
        let root = try root(), file = root.appendingPathComponent("note.txt"), archive = root.appendingPathComponent("crc.zip")
        let payload = Data("CRC-only-fixture-for-preview".utf8)
        try payload.write(to: file)
        var options = CreationOptions(); options.format = .zip; options.level = 0
        _ = try await ArchiveCreator.create(output: archive, inputs: [file], password: "", headers: false, volumeMB: 0, recovery: 0,
                                           options: options, executable: engine, runner: CLIRunner()) { _, _ in }
        var bytes = try Data(contentsOf: archive)
        let range = try XCTUnwrap(bytes.range(of: payload)); bytes[range.lowerBound] ^= 1
        try bytes.write(to: archive)
        let row = ArchiveEntry(path: "note.txt", size: String(payload.count), modified: "", isDirectory: false, isLink: false)
        do {
            _ = try await SingleFileExporter.export(row, entries: [row], source: archive, root: self.root(), engine: engine, password: "", encoding: .auto, runner: CLIRunner()) { _, _ in }
            XCTFail("CRC failure must not return a preview URL")
        } catch { }
    }
}
