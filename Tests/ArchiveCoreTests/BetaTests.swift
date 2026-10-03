import XCTest
import Darwin
@testable import ArchiveCore

final class BetaTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-beta-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func engine() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ for real-engine tests.") }
        return path
    }
    func testVolumeSizeBoundaries() throws {
        XCTAssertEqual(try VolumeSize.mebibytes("4", gibibytes: true), 4096)
        XCTAssertEqual(try VolumeSize.mebibytes("1.5", gibibytes: true), 1536)
        XCTAssertEqual(try VolumeSize.mebibytes("4096", gibibytes: false), 4096)
        for text in ["0", "-1", "4.1", "NaN", "", "1e2", "4GiB", "９", "1..0", "1.0.2", "1\n"] { XCTAssertThrowsError(try VolumeSize.mebibytes(text, gibibytes: true), text) }
        XCTAssertThrowsError(try VolumeSize.mebibytes("1.1", gibibytes: false))
    }
    func testChecksumVectorsManifestAndLinks() throws {
        let base = try root(), file = base.appendingPathComponent("中文 😀.txt")
        try Data("abc".utf8).write(to: file)
        let sha = try FileChecksums.digest(file, algorithm: .sha256)
        XCTAssertEqual(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileChecksums.digest(file, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")
        let record = try XCTUnwrap(FileChecksums.manifest(Data((sha + "  中文 😀.txt\r\n").utf8)).first)
        XCTAssertEqual(try FileChecksums.target(record, root: base), file)
        XCTAssertEqual(FileChecksums.normalized(sha.uppercased() + "\n", algorithm: .sha256), sha)
        XCTAssertNil(FileChecksums.normalized("not a checksum", algorithm: .md5))
        for name in ["../escape", "/absolute", "a/../../b", "a//b", "./a", "a\\b"] {
            XCTAssertThrowsError(try FileChecksums.manifest(Data((sha + "  " + name).utf8)))
        }
        XCTAssertThrowsError(try FileChecksums.manifest(Data((sha + "  a\n" + sha + "  A").utf8)))
        XCTAssertThrowsError(try FileChecksums.manifest(Data(repeating: 65, count: 1_048_577)))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try FileChecksums.digest(link, algorithm: .sha256))
        try Data().write(to: file)
        XCTAssertEqual(try FileChecksums.digest(file, algorithm: .md5), "d41d8cd98f00b204e9800998ecf8427e")
    }
    func testChecksumCancellationAndStreaming() async throws {
        let file = try root().appendingPathComponent("large")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try FileHandle(forWritingTo: file); try h.truncate(atOffset: 128 * 1024 * 1024); try h.close()
        let work = Task.detached { try Task.checkCancellation(); return try FileChecksums.digest(file, algorithm: .sha256) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }
    func testBatchContinuesAfterFailureAndCancelsPending() async throws {
        let base = try root(), jobs = ["one.zip", "bad.zip", "three.zip"].map { BatchArchive(source: base.appendingPathComponent($0)) }
        let result = await BatchArchives.execute(jobs, process: { job in
            if job.source.lastPathComponent == "bad.zip" { throw ArchiveError.invalid("Test failure") }
            return base
        }, update: { _ in })
        XCTAssertEqual(result.map(\.state), ["completed", "failed", "completed"])
        XCTAssertEqual(BatchArchives.folderName(base.appendingPathComponent("名字.tar.gz")), "名字")
        for name in [".tar.gz", "..tar.gz", "...tar.gz"] { XCTAssertEqual(BatchArchives.folderName(base.appendingPathComponent(name)), "Archive") }
        let work = Task { await BatchArchives.execute(jobs, process: { _ in try await Task.sleep(nanoseconds: 3_000_000_000); return base }, update: { _ in }) }
        work.cancel(); let stopped = await work.value
        XCTAssertEqual(stopped.map(\.state), ["cancelled", "cancelled", "cancelled"])
    }
    func testTARFamilyRoundTripAndPermissions() async throws {
        let base = try root(), input = base.appendingPathComponent("source", isDirectory: true), seven = try engine()
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let script = input.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\necho safe\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data("excluded".utf8).write(to: input.appendingPathComponent("skip.tmp"))
        for format in [CreationFormat.tar, .tarGzip, .tarXZ] {
            var options = CreationOptions(); options.format = format; options.exclusions = "*.tmp"
            let archive = base.appendingPathComponent("\(format.rawValue).\(format.rawValue)"), runner = CLIRunner()
            _ = try await ArchiveCreator.create(output: archive, inputs: [input], password: "", headers: false, volumeMB: 0, recovery: 0, options: options, executable: seven, runner: runner) { _, _ in }
            let output = base.appendingPathComponent("out-\(format.rawValue)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let destination = try await BatchExtractor.extract(archive, parent: output, engine: seven, runner: runner, password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("source/run.sh")), try Data(contentsOf: script))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent("source/run.sh").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source/skip.tmp").path))
        }
    }
    func storedZIP(_ name: [UInt8], payload: Data = Data("test".utf8)) -> Data {
        var data = Data()
        func le(_ value: UInt32, _ bytes: Int) { for n in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (n * 8))) } }
        var crc: UInt32 = 0xffffffff
        for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 } }
        crc ^= 0xffffffff
        le(0x04034b50, 4); le(20, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 2); le(crc, 4)
        le(UInt32(payload.count), 4); le(UInt32(payload.count), 4); le(UInt32(name.count), 2); le(0, 2); data.append(contentsOf: name); data.append(payload)
        let start = data.count
        le(0x02014b50, 4); le(20, 2); le(20, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 2); le(crc, 4)
        le(UInt32(payload.count), 4); le(UInt32(payload.count), 4); le(UInt32(name.count), 2)
        for _ in 0..<4 { le(0, 2) }; le(0, 4); le(0, 4); data.append(contentsOf: name)
        let central = data.count - start
        le(0x06054b50, 4); le(0, 2); le(0, 2); le(1, 2); le(1, 2); le(UInt32(central), 4); le(UInt32(start), 4); le(0, 2)
        return data
    }
    func testLegacyZIPEncodingListAndExtraction() async throws {
        guard ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Build the ZIP adapter and set ARCHIVEDESK_TEST_ZIP_HELPER.") }
        let base = try root(), seven = try engine()
        let samples: [(ZIPNameEncoding, [UInt8], String)] = [
            (.gbk, [0xb2,0xe2,0xca,0xd4], "测试"), (.gb18030, [0xb2,0xe2,0xca,0xd4], "测试"),
            (.cp932, [0x83,0x65,0x83,0x58,0x83,0x67], "テスト"), (.big5, [0xb4,0xfa,0xb8,0xd5], "測試"),
            (.cp437, [0x82], "é"), (.korean, [0xc5,0xd7,0xbd,0xba,0xc6,0xae], "테스트")]
        for (encoding, name, expected) in samples {
            let archive = base.appendingPathComponent("\(encoding.codePage!).zip"), runner = CLIRunner()
            try storedZIP(name + Array(".txt".utf8)).write(to: archive)
            let list = try await runner.run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip, encoding: encoding)) { _, _ in }
            XCTAssertEqual(list.status, 0, list.stdout + list.stderr)
            let rows = list.archiveEntries(backend: .sevenZip)
            XCTAssertEqual(rows.first?.path, expected + ".txt", encoding.rawValue)
            let destination = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: runner, password: "", encoding: encoding, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(expected + ".txt")), Data("test".utf8))
        }
    }
    func testSingleFileExportIsBoundedAndExact() async throws {
        let base = try root(), archive = base.appendingPathComponent("sample.zip"), destination = base.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try storedZIP(Array("folder/test.txt".utf8)).write(to: archive)
        let row = ArchiveEntry(path: "folder/test.txt", size: "4", modified: "", isDirectory: false, isLink: false)
        let file = try await SingleFileExporter.export(row, entries: [row], source: archive, root: destination, engine: engine(), password: "", encoding: .auto, runner: CLIRunner()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: file), Data("test".utf8))
        try PreviewSafety.validate(file, inside: destination)
        let tooSmall = ArchiveEntry(path: "folder/test.txt", size: "3", modified: "", isDirectory: false, isLink: false)
        do { _ = try await SingleFileExporter.export(tooSmall, entries: [tooSmall], source: archive, root: destination, engine: engine(), password: "", encoding: .auto, runner: CLIRunner()) { _, _ in }; XCTFail("Expected refusal") } catch { }
    }
    func testRealQueueBadArchiveDoesNotStopGoodArchive() async throws {
        let base = try root(), seven = try engine(), bad = base.appendingPathComponent("bad.zip"), good = base.appendingPathComponent("good.zip")
        try Data("not a ZIP".utf8).write(to: bad)
        try storedZIP(Array("test.txt".utf8)).write(to: good)
        let result = await BatchArchives.execute([BatchArchive(source: bad), BatchArchive(source: good)], process: { job in
            try await BatchExtractor.extract(job.source, parent: base, engine: seven, runner: CLIRunner(), password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        }, update: { _ in })
        XCTAssertEqual(result.map(\.state), ["failed", "completed"])
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("good/test.txt")), Data("test".utf8))
    }
    func testManualZIPIntegrityTraversalAndUTF8Flag() async throws {
        guard ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Set ZIP helper path.") }
        let base = try root(), seven = try engine()
        // ZIP UTF-8 flag takes precedence over a manual fallback code page.
        let archive = base.appendingPathComponent("utf8.zip"), name = Array("日本語.txt".utf8)
        var utf8 = storedZIP(name); utf8[7] = 8; utf8[30 + name.count + 4 + 9] = 8
        try utf8.write(to: archive)
        let listing = try await CLIRunner().run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip, encoding: .gbk)) { _, _ in }
        XCTAssertEqual(listing.status, 0, listing.stderr)
        XCTAssertEqual(listing.archiveEntries(backend: .sevenZip).first?.path, "日本語.txt")
        for (index, name) in ["../outside", "/absolute", "a/../outside", "..\\outside", "a\nPath = forged"].enumerated() {
            let bad = base.appendingPathComponent("unsafe\(index).zip")
            try storedZIP(Array(name.utf8)).write(to: bad)
            do { _ = try await BatchExtractor.extract(bad, parent: base, engine: seven, runner: CLIRunner(), password: "", encoding: .gb18030, policy: .skip, conflict: { _ in .skip }, update: { _, _ in }); XCTFail("Unsafe path accepted: " + name) } catch { }
        }
        let crc = base.appendingPathComponent("crc.zip")
        var bytes = storedZIP(Array("test.txt".utf8)); bytes[38] ^= 0xff; try bytes.write(to: crc)
        do { _ = try await BatchExtractor.extract(crc, parent: base, engine: seven, runner: CLIRunner(), password: "", encoding: .cp437, policy: .skip, conflict: { _ in .skip }, update: { _, _ in }); XCTFail("CRC mismatch accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("crc/test.txt").path))
        let copy = base.appendingPathComponent("copy"); try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        let row = ArchiveEntry(path: "日本語.txt", size: "4", modified: "", isDirectory: false, isLink: false)
        let exported = try await SingleFileExporter.export(row, entries: [row], source: archive, root: copy, engine: seven, password: "", encoding: .gb18030, runner: CLIRunner()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: exported), Data("test".utf8))
    }
    func testChecksumsRefuseDevicesAndDirectory() throws {
        let base = try root(), fifo = base.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try FileChecksums.digest(fifo, algorithm: .md5))
        XCTAssertThrowsError(try FileChecksums.digest(base, algorithm: .sha256))
    }
    func testManualZIPPasswordAndUnixPermissions() async throws {
        guard ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_ZIP_HELPER"] != nil else { throw XCTSkip("Set ZIP helper path.") }
        let base = try root(), seven = try engine(), source = base.appendingPathComponent("run.sh"), archive = base.appendingPathComponent("encrypted.zip")
        try Data("#!/bin/sh\necho test\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        var options = CreationOptions(); options.format = .zip
        _ = try await ArchiveCreator.create(output: archive, inputs: [source], password: "example-secret", headers: false, volumeMB: 0, recovery: 0, options: options, executable: seven, runner: CLIRunner()) { _, _ in }
        do { _ = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: CLIRunner(), password: "wrong", encoding: .gb18030, policy: .skip, conflict: { _ in .skip }, update: { _, _ in }); XCTFail("Wrong password accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("encrypted/run.sh").path))
        let dest = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: CLIRunner(), password: "example-secret", encoding: .gb18030, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("run.sh")), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.appendingPathComponent("run.sh").path))
    }
}
