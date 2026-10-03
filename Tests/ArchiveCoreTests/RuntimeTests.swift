import XCTest
import Darwin
@testable import ArchiveCore

final class RuntimeTests: XCTestCase {
    func testCRCFailureNeverPublishesBinaryOutput() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Engine not configured") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload.txt"), archive = root.appendingPathComponent("corrupt.zip"), output = root.appendingPathComponent("output.txt")
        let marker = Data("CRC-test-unique-payload-0123456789".utf8)
        try marker.write(to: payload)
        let runner = CLIRunner()
        let made = try await runner.run(executable: engine, arguments: ["a", "-tzip", "-mx0", archive.path, payload.path]) { _, _ in }
        XCTAssertEqual(made.status, 0)
        var bytes = try Data(contentsOf: archive) // Deliberately tiny synthetic fixture, not production I/O.
        let range = try XCTUnwrap(bytes.range(of: marker)); bytes[range.lowerBound] ^= 0xff
        try bytes.write(to: archive)
        let result = try await runner.run(executable: engine, arguments: ["x", "-so", "--", archive.path, "payload.txt"], outputFile: output) { _, _ in }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue((result.stderr + result.stdout).localizedCaseInsensitiveContains("CRC"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try DiskSpace.require(UInt64.max, at: root))
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testLaunchFailuresAreErrorsAndRunnerReusable() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("not-an-executable")
        try Data("invalid binary".utf8).write(to: bad)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path)
        let runner = CLIRunner()
        for (exe, args, cwd) in [("/missing/7zz", [], nil as URL?), (bad.path, [], nil), ("/usr/bin/true", ["NUL\0arg"], nil), ("/usr/bin/true", [], root.appendingPathComponent("gone")), ("/usr/bin/true", [String(repeating: "a", count: 2_000_000)], nil)] {
            do { _ = try await runner.run(executable: exe, arguments: args, directory: cwd) { _, _ in }; XCTFail("Must fail launch") } catch { XCTAssertTrue(error.localizedDescription.contains("launch")) }
            let ok = try await runner.run(executable: "/usr/bin/true", arguments: []) { _, _ in }
            XCTAssertEqual(ok.status, 0)
        }
    }
    func testConcurrentRunAndCancellation() async throws {
        let runner = CLIRunner(), started = expectation(description: "running")
        started.assertForOverFulfill = false // Running snapshots also carry progress updates.
        runner.observe = { if $0.state == .running { started.fulfill() } }
        let job = Task { try await runner.run(executable: "/bin/sleep", arguments: ["30"]) { _, _ in } }
        await fulfillment(of: [started], timeout: 5)
        do { _ = try await runner.run(executable: "/usr/bin/true", arguments: []) { _, _ in }; XCTFail("Concurrent start accepted") } catch { }
        job.cancel()
        let result = try await job.value
        XCTAssertTrue(result.cancelled)
        runner.observe = nil
        let next = try await runner.run(executable: "/usr/bin/true", arguments: []) { _, _ in }
        XCTAssertEqual(next.status, 0)
    }
    func testBoundedLogsAndSecretRedaction() async throws {
        let runner = CLIRunner()
        let result = try await runner.run(executable: "/usr/bin/printf", arguments: ["secret-value"], password: "secret-value") { a, b in
            XCTAssertFalse((a + b).contains("secret-value"))
        }
        XCTAssertEqual(result.stdout, "••••")
        let noisy = try await runner.run(executable: "/usr/bin/seq", arguments: ["1", "400000"]) { _, _ in }
        XCTAssertEqual(noisy.status, 0); XCTAssertLessThanOrEqual(noisy.stdout.utf8.count, 524_288)
    }
    func testIncrementalLargeListingAndBudget() throws {
        let decoder = ListingDecoder(backend: .sevenZip, limit: 300_000)
        for i in 0..<220_000 {
            try decoder.feed(Data("Path = 日本語-é-😀-\(i).txt\nSize = 5000000000\nModified = 2026-10-03 10:00:00\n\n".utf8))
        }
        try decoder.finish()
        XCTAssertEqual(decoder.entries.count, 220_000)
        let capped = ListingDecoder(backend: .sevenZip, limit: 1)
        try capped.feed(Data("Path = a\nSize = 1\n\n".utf8))
        XCTAssertThrowsError(try capped.feed(Data("Path = b\nSize = 1\n\n".utf8)))
        let gib: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(RuntimeBudget.calculate(ram: 8 * gib, cores: 8, mode: .adaptive).memory, gib)
        XCTAssertEqual(RuntimeBudget.calculate(ram: 64 * gib, cores: 16, mode: .adaptive).memory, 32 * gib)
        XCTAssertEqual(RuntimeBudget.calculate(ram: 64 * gib, cores: 16, mode: .adaptive, pressure: 1).workers, 1)
    }
    func testGeneralSafetyLargeSizesAndUnicode() throws {
        func file(_ path: String, _ size: String = "0") -> ArchiveEntry { .init(path: path, size: size, modified: "", isDirectory: false, isLink: false) }
        XCTAssertEqual(try ExtractionSafety.validate([file("big", "150000000000")]), 150_000_000_000)
        XCTAssertThrowsError(try ExtractionSafety.validate([file("../escape")]))
        XCTAssertThrowsError(try ExtractionSafety.validate([file("é.txt"), file("e\u{301}.txt")]))
        XCTAssertThrowsError(try ExtractionSafety.validate([file("A"), file("a/b")]))
        XCTAssertThrowsError(try ExtractionSafety.validate([file("bomb", "700000000000")], compressedBytes: 10_000_000))
        XCTAssertNoThrow(try ExtractionSafety.validate(["简体中文", "繁體中文", "日本語", "한국어", "Русский", "العربية", "😀𐐷"].map { file($0) }))
    }
    func testAtomicCopyModeTimeAndCancelledOutput() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("run")
        try Data("executable fixture".utf8).write(to: source)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: date], ofItemAtPath: source.path)
        XCTAssertFalse(try ExtractionSafety.copyVerifiedFile(source, to: target, replacing: false))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(attrs[.modificationDate] as? Date, date)
        let output = root.appendingPathComponent("never-published")
        let result = try await CLIRunner().run(executable: "/usr/bin/yes", arguments: [], outputFile: output, outputLimit: 100) { _, _ in }
        XCTAssertNotEqual(result.status, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }
    func testGhidraFullExtractionAndPermission() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"], let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_GHIDRA"] else { throw XCTSkip("Local Ghidra fixture not configured") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage"), destination = root.appendingPathComponent("destination")
        for url in [stage, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let runner = CLIRunner(), archive = URL(fileURLWithPath: path)
        let listed = try await runner.run(executable: engine, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip)) { _, _ in }
        XCTAssertEqual(listed.status, 0)
        let entries = listed.archiveEntries(backend: .sevenZip), size = try ExtractionSafety.validate(entries)
        try DiskSpace.require(size * 2, at: root)
        let extracted = try await runner.run(executable: engine, arguments: ArchiveCommands.extract(archive, destination: stage, selected: [], password: "", using: .sevenZip), diskGuard: stage) { _, _ in }
        XCTAssertEqual(extracted.status, 0, extracted.stderr)
        let report = try await ExtractionMerger.merge(from: stage, to: destination, policy: .skip, conflict: { _ in .cancel })
        XCTAssertEqual(report.written, entries.filter { !$0.isDirectory }.count)
        for item in entries where !item.isDirectory {
            XCTAssertEqual((try destination.appendingPathComponent(item.path).resourceValues(forKeys: [.fileSizeKey])).fileSize, Int(item.size), item.path)
        }
        let launcher = try XCTUnwrap(entries.first { $0.name == "ghidraRun" })
        let file = destination.appendingPathComponent(launcher.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: file.path))
        XCTAssertEqual(try ArchiveEditor.digest(file), try ArchiveEditor.digest(stage.appendingPathComponent(launcher.path)))
        print("GHIDRA VERIFIED: \(report.written) files, \(size) bytes; ghidraRun executable preserved")
    }
    func testZIP64Over4GiBStreaming() async throws {
        guard let engine = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"], ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_LARGE"] == "1" else { throw XCTSkip("Set ARCHIVEDESK_TEST_LARGE=1 for disk-intensive test") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin"), archive = root.appendingPathComponent("zip64.zip"), output = root.appendingPathComponent("unpacked.bin")
        try DiskSpace.require(12 * 1024 * 1024 * 1024, at: root)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let size: UInt64 = 5 * 1024 * 1024 * 1024 + 1
        try handle.truncate(atOffset: size); try handle.close()
        let runner = CLIRunner()
        let made = try await runner.run(executable: engine, arguments: ["a", "-tzip", "-mx1", archive.path, file.path]) { _, _ in }
        XCTAssertEqual(made.status, 0)
        let result = try await runner.run(executable: engine, arguments: ["x", "-so", "--", archive.path, "large.bin"], outputFile: output, outputLimit: Int(size)) { _, _ in }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
        XCTAssertEqual(try ArchiveEditor.digest(file), try ArchiveEditor.digest(output))
        print("ZIP64 VERIFIED: \(size) bytes, streaming SHA-256 equal")
    }
}
