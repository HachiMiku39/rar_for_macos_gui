import XCTest
@testable import ArchiveCore

final class CoreTests: XCTestCase {
    func testBroadFormatsWithBundledEngine() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("sample.txt")
        let bytes = Data("format test\n".utf8)
        try bytes.write(to: source)
        let runner = CLIRunner()
        let tar = dir.appendingPathComponent("sample.tar")
        var result = try await runner.run(executable: path, arguments: ["a", "-ttar", "--", tar.path, source.path]) { _, _ in }
        XCTAssertEqual(result.status, 0)
        var archives = [tar]
        for (suffix, type) in [("gz", "gzip"), ("bz2", "bzip2"), ("xz", "xz")] {
            let archive = dir.appendingPathComponent("sample.tar." + suffix)
            result = try await runner.run(executable: path, arguments: ["a", "-t" + type, "--", archive.path, tar.path]) { _, _ in }
            XCTAssertEqual(result.status, 0)
            archives.append(archive)
        }
        let uue = dir.appendingPathComponent("sample.uue")
        result = try await runner.run(executable: "/usr/bin/uuencode", arguments: [source.path, source.lastPathComponent], outputFile: uue) { _, _ in }
        XCTAssertEqual(result.status, 0); archives.append(uue)
        for archive in archives {
            let session = try await ArchiveSession.prepare(archive, sevenZip: path, runner: runner) { _, _ in }
            let list = try await runner.run(executable: path, arguments: ArchiveCommands.list(session.workingURL, password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(list.status, 0)
            let entries = list.archiveEntries(backend: .sevenZip)
            XCTAssertTrue(entries.contains { $0.path == "sample.txt" }, "\(archive): \(list.stdout)")
            XCTAssertFalse(entries.contains { $0.path == archive.path })
            let destination = dir.appendingPathComponent(UUID().uuidString)
            let extract = try await runner.run(executable: path, arguments: ArchiveCommands.extract(session.workingURL, destination: destination, selected: ["sample.txt"], password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(extract.status, 0, extract.stderr)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sample.txt")), bytes)
        }
    }
    func testAdvertisedFormats() {
        for ext in ["rar", "zip", "7z", "cab", "arj", "lzh", "tar", "gz", "uue", "iso", "bz2", "z", "xz", "zst"] { XCTAssertTrue(ArchiveCommands.extensions.contains(ext)) }
        XCTAssertTrue(ArchiveCommands.isCompressedTar(URL(fileURLWithPath: "/tmp/A.TAR.GZ")))
        let listing = "Path = archive.gz\nType = gzip\nHeaders Size = 10\n\n----------\nPath = archive\nSize = 10\n"
        XCTAssertEqual(ArchiveCommands.parse(listing, backend: .sevenZip).map(\.path), ["archive"])
        XCTAssertFalse(ArchiveCommands.parse("Path = sample.txt\nSymbolic Link = \n", backend: .sevenZip)[0].isLink)
    }
    func testISOAndRARWithBundledEngine() async throws {
        guard let seven = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"], let rar = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_RAR"] else { throw XCTSkip("Set both CLI paths") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("sample.txt"), bytes = Data("ISO and RAR fixture".utf8)
        try bytes.write(to: file)
        let runner = CLIRunner(), iso = root.appendingPathComponent("sample.iso"), archive = root.appendingPathComponent("sample.rar")
        let image = try await runner.run(executable: "/usr/bin/hdiutil", arguments: ["makehybrid", "-iso", "-joliet", "-o", iso.path, source.path]) { _, _ in }
        XCTAssertEqual(image.status, 0, image.stderr)
        let created = try await runner.run(executable: rar, arguments: ArchiveCommands.create(output: archive, inputs: [file], password: "secret", headers: true, volumeMB: 0, recovery: 0), directory: source, password: "secret") { _, _ in }
        XCTAssertEqual(created.status, 0)
        for url in [iso, archive] {
            let password = url == archive ? "secret" : ""
            let list = try await runner.run(executable: seven, arguments: ArchiveCommands.list(url, password: password, using: .sevenZip), password: password) { _, _ in }
            XCTAssertEqual(list.status, 0, list.stderr)
            let entries = list.archiveEntries(backend: .sevenZip)
            XCTAssertEqual(entries.map(\.path), ["sample.txt"])
            XCTAssertTrue(entries.allSatisfy { !$0.isLink && ArchiveCommands.safePath($0.path) })
            let dest = root.appendingPathComponent(UUID().uuidString)
            let extract = try await runner.run(executable: seven, arguments: ArchiveCommands.extract(url, destination: dest, selected: ["sample.txt"], password: password, using: .sevenZip), password: password) { _, _ in }
            XCTAssertEqual(extract.status, 0, extract.stderr)
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("sample.txt")), bytes)
        }
    }
    func testTraversalAndPatterns() throws {
        for path in ["../escape", "/tmp/file", "a/../../b", "a\\..\\b", "C:\\file", "x\nName: bad"] { XCTAssertFalse(ArchiveCommands.safePath(path)) }
        XCTAssertTrue(ArchiveCommands.safePath("文件夹/a b.txt"))
        XCTAssertThrowsError(try ArchiveCommands.literalSelection(["*.txt"]))
        XCTAssertThrowsError(try ArchiveCommands.literalSelection(["@list"]))
    }
    func testPasswordNeverInArguments() throws {
        let url = URL(fileURLWithPath: "/tmp/archive with spaces.rar")
        let args = try ArchiveCommands.list(url, password: "test secret")
        XCTAssertTrue(args.contains("-p")); XCTAssertFalse(args.joined().contains("test secret"))
        XCTAssertEqual(args.last, url.path)
        XCTAssertThrowsError(try ArchiveCommands.passwordSwitch("bad\npassword"))
    }
    func testParsers() {
        let rar = "Archive: a.rar\n\n        Name: 文件夹/a b.txt\n        Type: File\n        Size: 42\n       mtime: 2026-09-26 12:00:00\n\n        Name: folder\n        Type: Directory\n"
        let r = ArchiveCommands.parse(rar, backend: .rar)
        XCTAssertEqual(r.count, 2); XCTAssertEqual(r[0].path, "文件夹/a b.txt"); XCTAssertTrue(r[1].isDirectory)
        let seven = "Path = /tmp/a.zip\nType = zip\nPhysical Size = 50\n\n----------\nPath = a.txt\nSize = 10\n\nPath = link\nSymbolic Link = /tmp/file\n"
        let s = ArchiveCommands.parse(seven, backend: .sevenZip)
        XCTAssertEqual(s.count, 2); XCTAssertTrue(s[1].isLink)
    }
    func testRealRAR() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_RAR"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_RAR to a licensed/test RAR binary") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("测试 space $name.txt")
        try Data("archive round trip".utf8).write(to: source)
        let archive = dir.appendingPathComponent("test.rar"), runner = CLIRunner()
        let secret = "temporary-test-password"
        let create = try ArchiveCommands.create(output: archive, inputs: [source], password: secret, headers: true, volumeMB: 0, recovery: 3)
        let c = try await runner.run(executable: path, arguments: create, directory: dir, password: secret) { _, _ in }
        XCTAssertEqual(c.status, 0, c.stdout + c.stderr)
        let l = try await runner.run(executable: path, arguments: ArchiveCommands.list(archive, password: secret), password: secret) { _, _ in }
        XCTAssertEqual(l.status, 0, l.stdout + l.stderr)
        let entries = ArchiveCommands.parse(l.stdout, backend: .rar)
        XCTAssertEqual(entries.map(\.path), [source.lastPathComponent])
        let dest = dir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let x = try await runner.run(executable: path, arguments: ArchiveCommands.extract(archive, destination: dest, selected: entries.map(\.path), password: secret), password: secret) { _, _ in }
        XCTAssertEqual(x.status, 0, x.stdout + x.stderr)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(source.lastPathComponent)), Data("archive round trip".utf8))
        let t = try await runner.run(executable: path, arguments: ArchiveCommands.test(archive, password: secret), password: secret) { _, _ in }
        XCTAssertEqual(t.status, 0, t.stdout + t.stderr)
        let wrong = try await runner.run(executable: path, arguments: ArchiveCommands.list(archive, password: "incorrect"), password: "incorrect") { _, _ in }
        XCTAssertNotEqual(wrong.status, 0)
        XCTAssertFalse((c.stdout + c.stderr + l.stdout + l.stderr).contains(secret))
    }
    func testSevenZipAndZipRoundTrips() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_7ZZ") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("中文 with spaces.txt")
        try Data("seven zip round trip".utf8).write(to: source)
        let runner = CLIRunner()
        for ext in ["zip", "7z"] {
            let archive = dir.appendingPathComponent("test." + ext)
            let secret = ext == "7z" ? "test-secret" : ""
            let args = ["a"] + (secret.isEmpty ? [] : ["-p", "-mhe=on"]) + ["--", archive.path, source.path]
            let c = try await runner.run(executable: path, arguments: args, password: secret) { _, _ in }
            XCTAssertEqual(c.status, 0, c.stdout + c.stderr)
            let l = try await runner.run(executable: path, arguments: ArchiveCommands.list(archive, password: secret), password: secret) { _, _ in }
            XCTAssertEqual(l.status, 0, l.stdout + l.stderr)
            let entries = ArchiveCommands.parse(l.stdout, backend: .sevenZip)
            XCTAssertEqual(entries.map(\.path), [source.lastPathComponent])
            let dest = dir.appendingPathComponent(ext)
            let x = try await runner.run(executable: path, arguments: ArchiveCommands.extract(archive, destination: dest, selected: [source.lastPathComponent], password: secret), password: secret) { _, _ in }
            XCTAssertEqual(x.status, 0, x.stdout + x.stderr)
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent(source.lastPathComponent)), Data("seven zip round trip".utf8))
            let t = try await runner.run(executable: path, arguments: ArchiveCommands.test(archive, password: secret), password: secret) { _, _ in }
            XCTAssertEqual(t.status, 0)
        }
    }
    func testCancellation() async throws {
        let runner = CLIRunner()
        let job = Task { try await runner.run(executable: "/bin/sleep", arguments: ["30"]) { _, _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        runner.cancel()
        let result = try await job.value
        XCTAssertTrue(result.cancelled)
        XCTAssertNotEqual(result.status, 0)
    }
    func testVolumeRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_RAR"] else { throw XCTSkip("Set ARCHIVEDESK_TEST_RAR") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        try Data((0..<2_200_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)
        let archive = dir.appendingPathComponent("volumes.rar"), runner = CLIRunner()
        let c = try await runner.run(executable: path, arguments: ArchiveCommands.create(output: archive, inputs: [source], password: "", headers: false, volumeMB: 1, recovery: 3), directory: dir) { _, _ in }
        XCTAssertEqual(c.status, 0, c.stdout + c.stderr)
        let parts = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "rar" }.sorted { $0.path < $1.path }
        XCTAssertGreaterThan(parts.count, 1)
        guard let first = parts.first else { return XCTFail("No volumes") }
        let r = try await runner.run(executable: path, arguments: ["rv10p", "-cfg-", "-p-", "--", first.path]) { _, _ in }
        XCTAssertEqual(r.status, 0, r.stdout + r.stderr)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".rev") })
        let rr = try await runner.run(executable: path, arguments: ["rr3p", "-cfg-", "-p-", "--", first.path]) { _, _ in }
        XCTAssertEqual(rr.status, 0, rr.stdout + rr.stderr)
    }
}
