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
    func testPathAttackFixturesNeverPublishOutsideDestination() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let outside = base.appendingPathComponent("outside.txt")
        let sentinel = Data("must remain unchanged".utf8)
        try sentinel.write(to: outside)
        for encoding in [ZIPNameEncoding.auto, .gb18030] {
            for (index, name) in [outside.path, "../outside.txt", "a/../../outside.txt", "..\\outside.txt", "a\\..\\outside.txt"].enumerated() {
                let archive = base.appendingPathComponent("attack-\(encoding.rawValue)-\(index).zip")
                try storedZIP(Array(name.utf8)).write(to: archive)
                let before = try FileChecksums.digest(archive, algorithm: .sha256)
                do {
                    _ = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: CLIRunner(), password: "", encoding: encoding, policy: .replace, conflict: { _ in .replace }, update: { _, _ in })
                    XCTFail("Accepted attack \(name)")
                } catch {
                    print("PATH MATRIX: encoding=\(encoding.rawValue) path=\(name) sha256=\(before) refusal=\(error.localizedDescription)")
                }
                XCTAssertEqual(try Data(contentsOf: outside), sentinel)
                let dest = base.appendingPathComponent(BatchArchives.folderName(archive))
                XCTAssertTrue(try fm.contentsOfDirectory(atPath: dest.path).isEmpty)
                XCTAssertEqual(try FileChecksums.digest(archive, algorithm: .sha256), before)
            }
        }
    }
    func testRealTARSymbolicAndHardLinksAreRejected() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("safe".utf8).write(to: source.appendingPathComponent("payload"))
        for kind in ["symbolic", "hard"] {
            let link = source.appendingPathComponent(kind)
            if kind == "symbolic" { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside") }
            else { try fm.linkItem(at: source.appendingPathComponent("payload"), to: link) }
            let archive = base.appendingPathComponent(kind + ".tar"), runner = CLIRunner()
            let made = try await runner.run(executable: "/usr/bin/tar", arguments: ["-cf", archive.path, "--format", "pax", "--no-mac-metadata", "--", "payload", kind], directory: source) { _, _ in }
            XCTAssertEqual(made.status, 0, made.stderr)
            let listing = try await runner.run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(listing.status, 0, listing.stderr)
            XCTAssertTrue(listing.archiveEntries(backend: .sevenZip).contains { $0.isLink }, listing.stdout)
            do {
                _ = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: runner, password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
                XCTFail("Accepted \(kind) link")
            } catch { print("LINK MATRIX: \(kind) sha256=\(try FileChecksums.digest(archive, algorithm: .sha256)) refusal=\(error.localizedDescription)") }
            XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("outside").path))
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: base.appendingPathComponent(kind).path).isEmpty)
        }
    }
    func testIsolatedDiskFailureDoesNotPublishArchive() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_SMALL_VOLUME"] else { throw XCTSkip("Requires a dedicated small disposable mounted volume") }
        let parent = URL(fileURLWithPath: path), fm = FileManager.default, seven = try engine()
        // Refuse arbitrary user disks: the runner must create this exact marker on its isolated image.
        guard try String(contentsOf: parent.appendingPathComponent(".archivedesk-disposable-test-volume")).trimmingCharacters(in: .whitespacesAndNewlines) == "ArchiveDesk QA 2026-11-07" else { throw ArchiveError.invalid("Missing disposable-volume marker") }
        let free = try XCTUnwrap(DiskSpace.available(at: parent))
        guard free < 256 * 1024 * 1024 else { throw ArchiveError.invalid("Test volume is not bounded below 256 MiB") }
        let base = try root(), input = base.appendingPathComponent("large.bin"), output = parent.appendingPathComponent("never-publish.7z")
        fm.createFile(atPath: input.path, contents: nil)
        let handle = try FileHandle(forWritingTo: input); try handle.truncate(atOffset: 256 * 1024 * 1024); try handle.close()
        XCTAssertThrowsError(try DiskSpace.require(256 * 1024 * 1024, at: parent))
        var options = CreationOptions(); options.format = .sevenZip; options.level = 0
        var diagnostics = ""
        do {
            _ = try await ArchiveCreator.create(output: output, inputs: [input], password: "", headers: false, volumeMB: 0, recovery: 0, options: options, executable: seven, runner: CLIRunner()) { a, b in diagnostics = a + b }
            XCTFail("Published an oversized archive")
        } catch { print("DISK MATRIX: initialFree=\(free) refusal=\(error.localizedDescription) engine=\(diagnostics)") }
        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".ArchiveDesk-create-") || $0.hasSuffix(".partial") })
        XCTAssertEqual(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize, 256 * 1024 * 1024)
    }
    func testExtractionStagingUsesChosenVolumeAndRejectsSymlinkParent() throws {
        let base = try root(), fm = FileManager.default
        let stage = try ExtractionStaging.create(in: base)
        XCTAssertEqual(stage.deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL)
        XCTAssertTrue(stage.lastPathComponent.hasPrefix(".ArchiveDesk-extract-"))
        let a = try fm.attributesOfFileSystem(forPath: base.path), b = try fm.attributesOfFileSystem(forPath: stage.path)
        XCTAssertEqual(a[.systemNumber] as? NSNumber, b[.systemNumber] as? NSNumber)
        XCTAssertEqual((try fm.attributesOfItem(atPath: stage.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: base)
        XCTAssertThrowsError(try ExtractionStaging.create(in: alias))
    }
    func testBatchExtractionUsesDestinationStageAndCleansIt() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let archive = base.appendingPathComponent("valid.zip"), runner = CLIRunner()
        try storedZIP(Array("inside.txt".utf8)).write(to: archive)
        var sawDestinationStage = false
        runner.observe = { _ in
            if let names = try? fm.contentsOfDirectory(atPath: base.path), names.contains(where: { $0.hasPrefix(".ArchiveDesk-extract-") }) { sawDestinationStage = true }
        }
        let result = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: runner, password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in })
        XCTAssertTrue(sawDestinationStage)
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("inside.txt")), Data("test".utf8))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".ArchiveDesk-extract-") })
        let bad = base.appendingPathComponent("bad.zip"); try Data("bad".utf8).write(to: bad)
        do { _ = try await BatchExtractor.extract(bad, parent: base, engine: seven, runner: runner, password: "", encoding: .auto, policy: .skip, conflict: { _ in .skip }, update: { _, _ in }); XCTFail("Accepted corrupt archive") } catch { }
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".ArchiveDesk-extract-") })
    }
    func testDirectExtractionSkipsExistingFilesWithoutStaging() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let source = base.appendingPathComponent("source"), nested = source.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: nested.appendingPathComponent("inside.txt"))
        try Data("new".utf8).write(to: nested.appendingPathComponent("new.txt"))
        for encoding in [ZIPNameEncoding.auto, .gb18030] {
        let archive = base.appendingPathComponent("direct-\(encoding.rawValue).zip")
        let made = try await CLIRunner().run(executable: seven, arguments: ["a", "-tzip", "-mx=0", "--", archive.path, "nested"], directory: source) { _, _ in }
        XCTAssertEqual(made.status, 0, made.stderr)
        var sawStage = false
        let runner = CLIRunner()
        runner.observe = { _ in if let names = try? fm.contentsOfDirectory(atPath: base.path), names.contains(where: { $0.hasPrefix(".ArchiveDesk-extract-") }) { sawStage = true } }
        let destination = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: runner, password: "", encoding: encoding, policy: .replace, conflict: { _ in XCTFail("Direct mode must skip conflicts"); return .replace }, update: { _, _ in }, useStaging: false)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("nested/inside.txt")), Data("test".utf8))
        let sentinel = Data("user content".utf8)
        try sentinel.write(to: destination.appendingPathComponent("nested/inside.txt"))
        try fm.removeItem(at: destination.appendingPathComponent("nested/new.txt"))
        _ = try await BatchExtractor.extract(archive, parent: base, engine: seven, runner: runner, password: "", encoding: encoding, policy: .ask, conflict: { _ in .skip }, update: { _, _ in }, useStaging: false)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("nested/inside.txt")), sentinel)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("nested/new.txt")), Data("new".utf8))
        XCTAssertFalse(sawStage)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".ArchiveDesk-extract-") })
        }
    }
    func testDirectConflictChoicesAndCancelPreserveOriginals() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        for name in ["a.txt", "b.txt"] { try Data(("new-" + name).utf8).write(to: source.appendingPathComponent(name)) }
        let archive = base.appendingPathComponent("conflicts.zip")
        let made = try await CLIRunner().run(executable: seven, arguments: ["a", "-tzip", "--", archive.path, "a.txt", "b.txt"], directory: source) { _, _ in }
        XCTAssertEqual(made.status, 0, made.stderr)
        let listing = try await CLIRunner().run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip)) { _, _ in }
        let rows = listing.archiveEntries(backend: .sevenZip)
        for encoding in [ZIPNameEncoding.auto, .gb18030] {
            for mode in ["mixed", "all", "cancel"] {
                let destination = base.appendingPathComponent(encoding.rawValue + mode)
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                for name in ["a.txt", "b.txt"] { try Data(("old-" + name).utf8).write(to: destination.appendingPathComponent(name)) }
                var prompts = 0
                do {
                    let report = try await DirectExtractor.extract(archive, entries: rows, destination: destination, selected: [], engine: seven, password: "", encoding: encoding, runner: CLIRunner(), update: { _, _ in }, conflict: { path in
                        prompts += 1
                        if mode == "cancel" { return .cancel }
                        if mode == "all" { return .replaceAll }
                        return path == "a.txt" ? .replace : .skip
                    })
                    XCTAssertNotEqual(mode, "cancel")
                    XCTAssertEqual(prompts, mode == "all" ? 1 : 2)
                    XCTAssertEqual(report.backups, mode == "all" ? 2 : 1)
                } catch is CancellationError { XCTAssertEqual(mode, "cancel") }
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")), Data(((mode == "cancel" ? "old-" : "new-") + "a.txt").utf8))
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.txt")), Data(((mode == "all" ? "new-" : "old-") + "b.txt").utf8))
                let backups = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ArchiveDesk-backup-") }
                XCTAssertEqual(backups.count, mode == "cancel" ? 0 : mode == "all" ? 2 : 1)
                for backup in backups { XCTAssertTrue(String(data: try Data(contentsOf: backup), encoding: .utf8)?.hasPrefix("old-") == true) }
            }
        }
    }
    func testDirectConflictKeepsFileSavedDuringPromptAndReversesPreparation() async throws {
        let destination = try root()
        let names = ["a.txt", "b.txt"]
        let rows = names.map { ArchiveEntry(path: $0, size: "3", modified: "", isDirectory: false, isLink: false) }
        for name in names { try Data("old".utf8).write(to: destination.appendingPathComponent(name)) }
        let edited = destination.appendingPathComponent("b.txt")
        do {
            _ = try await DirectExtractor.extract(destination.appendingPathComponent("unused.zip"), entries: rows,
                destination: destination, selected: [], engine: "/usr/bin/false", password: "", encoding: .auto,
                runner: CLIRunner(), update: { _, _ in }, conflict: { name in
                    if name == "b.txt" {
                        do { try Data("new".utf8).write(to: edited, options: .atomic) }
                        catch { XCTFail("Could not save the edited file: \(error)") }
                    }
                    return .replace
                })
            XCTFail("Stale replacement accepted")
        } catch ArchiveError.invalid(let message) {
            XCTAssertEqual(message, "The destination changed while awaiting a conflict decision.")
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: edited), Data("new".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), Set(names))
    }

    func testDirectSkipSurvivesRemovalAndCountsLaterConflicts() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let source = base.appendingPathComponent("src"), selected = source.appendingPathComponent("folder")
        try fm.createDirectory(at: selected, withIntermediateDirectories: true)
        let omitted = " @\"?*.txt\"  ", names = [omitted, "late-same", "late-other", "new"]
        for name in names { try Data("four".utf8).write(to: selected.appendingPathComponent(name)) }
        try Data().write(to: source.appendingPathComponent("outside"))
        let archive = base.appendingPathComponent("fixture.zip")
        let created = try await CLIRunner().run(executable: seven, arguments: ["a", "-tzip", "--", archive.path, "folder", "outside"], directory: source) { _, _ in }
        XCTAssertEqual(created.status, 0)
        for encoding in [ZIPNameEncoding.auto, .gb18030] {
            let destination = base.appendingPathComponent(encoding.rawValue), folder = destination.appendingPathComponent("folder")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let skipped = folder.appendingPathComponent(omitted)
            try Data("old".utf8).write(to: skipped)
            let runner = CLIRunner()
            let list = try await runner.run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip, encoding: encoding)) { _, _ in }
            runner.observe = { event in
                guard event.state == .queued else { return }
                do {
                    try fm.removeItem(at: skipped)
                    try Data("kept".utf8).write(to: folder.appendingPathComponent("late-same"))
                    try Data("kept original length".utf8).write(to: folder.appendingPathComponent("late-other"))
                } catch { XCTFail("Failed to synchronize fixture: \(error)") }
            }
            let rows = list.archiveEntries(backend: .sevenZip)
            let report = try await DirectExtractor.extract(archive, entries: rows, destination: destination, selected: ["folder"], engine: seven,
                password: "", encoding: encoding, runner: runner, update: { _, _ in }, conflict: { path in
                    XCTAssertEqual(path, "folder/" + omitted); return .skip
                })
            XCTAssertEqual(report.written, 1); XCTAssertEqual(report.skipped, 3)
            XCTAssertFalse(fm.fileExists(atPath: skipped.path))
            XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("outside").path))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("late-same")), Data("kept".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("late-other")), Data("kept original length".utf8))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("new")), Data("four".utf8))
        }
    }

    func testDirectEncryptedFileWithRedactedSummaryAndDirectoryOnly() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let dir = base.appendingPathComponent("empty"), archive = base.appendingPathComponent("encrypted.7z")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data("one".utf8).write(to: base.appendingPathComponent("note"))
        let runner = CLIRunner(), secret = "Size"
        let created = try await runner.run(executable: seven, arguments: ["a", "-t7z", "-pSize", "--", archive.path, "empty", "note"], directory: base) { _, _ in }
        XCTAssertEqual(created.status, 0)
        let listing = try await runner.run(executable: seven, arguments: ArchiveCommands.list(archive, password: secret, using: .sevenZip), password: secret) { _, _ in }
        let rows = listing.archiveEntries(backend: .sevenZip), destination = base.appendingPathComponent("result")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        for (name, expectedFiles) in [("note", 1), ("empty", 0)] {
            let result = try await DirectExtractor.extract(archive, entries: rows, destination: destination, selected: [name],
                engine: seven, password: secret, encoding: .auto, runner: runner, update: { _, _ in })
            XCTAssertEqual(result.written, expectedFiles)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("note")), Data("one".utf8))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("empty").path))
        let skip = try await DirectExtractor.extract(archive, entries: rows, destination: destination, selected: [],
            engine: seven, password: secret, encoding: .auto, runner: runner, update: { _, _ in }, conflict: { _ in .skip })
        XCTAssertEqual(skip.written, 0); XCTAssertEqual(skip.skipped, 1)
    }

    func testDirectPackageExtractionDoesNotForceStaging() async throws {
        let base = try root(), archive = base.appendingPathComponent("direct.ipa")
        try storedZIP(Array("Payload/Test.app/Info.plist".utf8)).write(to: archive)
        let destination = try await BatchExtractor.extract(archive, parent: base, engine: try engine(), runner: CLIRunner(), password: "", encoding: .auto, policy: .ask, conflict: { _ in .skip }, update: { _, _ in }, useStaging: false)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Payload/Test.app/Info.plist")), Data("test".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".ArchiveDesk-extract-") })
    }
    func testDirectExtractionRejectsSymlinkAncestorAndHardLinkTarget() async throws {
        let base = try root(), seven = try engine(), fm = FileManager.default
        let destination = base.appendingPathComponent("destination"), outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let archive = base.appendingPathComponent("link.zip")
        try storedZIP(Array("alias/new.txt".utf8)).write(to: archive)
        try fm.createSymbolicLink(at: destination.appendingPathComponent("alias"), withDestinationURL: outside)
        let entry = ArchiveEntry(path: "alias/new.txt", size: "4", modified: "", isDirectory: false, isLink: false)
        do { _ = try await DirectExtractor.extract(archive, entries: [entry], destination: destination, selected: [], engine: seven, password: "", encoding: .auto, runner: CLIRunner(), update: { _, _ in }); XCTFail("Followed symlink") } catch { }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try fm.linkItem(at: sentinel, to: destination.appendingPathComponent("file.txt"))
        let linked = ArchiveEntry(path: "file.txt", size: "4", modified: "", isDirectory: false, isLink: false)
        do { _ = try await DirectExtractor.extract(archive, entries: [linked], destination: destination, selected: [], engine: seven, password: "", encoding: .auto, runner: CLIRunner(), update: { _, _ in }); XCTFail("Accepted hard link") } catch { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testDirectFailureNeverRemovesDestination() async throws {
        let base = try root(), fm = FileManager.default, sentinel = base.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let archive = base.appendingPathComponent("bad.zip")
        // A valid central directory with corrupt payload passes listing, then fails CRC during extraction.
        var bytes = storedZIP(Array("partial.txt".utf8)); bytes[30 + "partial.txt".utf8.count] ^= 1
        try bytes.write(to: archive)
        let entry = ArchiveEntry(path: "partial.txt", size: "4", modified: "", isDirectory: false, isLink: false)
        do { _ = try await DirectExtractor.extract(archive, entries: [entry], destination: base, selected: [], engine: try engine(), password: "", encoding: .auto, runner: CLIRunner(), update: { _, _ in }); XCTFail("Accepted corrupt CRC") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Incomplete files may remain"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertTrue(fm.fileExists(atPath: archive.path))
        let original = Data("original".utf8)
        try original.write(to: base.appendingPathComponent("partial.txt"))
        do { _ = try await DirectExtractor.extract(archive, entries: [entry], destination: base, selected: [], engine: try engine(), password: "", encoding: .auto, runner: CLIRunner(), update: { _, _ in }, conflict: { _ in .replace }); XCTFail("Accepted corrupt replacement") } catch { }
        let backups = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ArchiveDesk-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
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
