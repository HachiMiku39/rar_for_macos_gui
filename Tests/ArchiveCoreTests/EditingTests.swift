import XCTest
@testable import ArchiveCore

final class EditingTests: XCTestCase {
    let fm = FileManager.default
    func root() throws -> URL {
        let url = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ArchiveDesk-v7-test-" + UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    func testCapabilityAndNames() throws {
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        XCTAssertNil(ArchiveEditor.refusal(url, listing: "Type = zip\nEncrypted = -"))
        for line in ["Encrypted = +", "Volumes = 2", "Multivolume = +", "Locked = +"] { XCTAssertNotNil(ArchiveEditor.refusal(url, listing: "Type = zip\n" + line)) }
        XCTAssertNotNil(ArchiveEditor.refusal(URL(fileURLWithPath: "/tmp/a.ipa"), listing: "Type = zip"))
        XCTAssertNotNil(ArchiveEditor.refusal(url, listing: "Type = 7z"))
        let a = ArchiveEntry(path: "dir/a.txt", size: "1", modified: "", isDirectory: false, isLink: false)
        let b = ArchiveEntry(path: "dir/b.txt", size: "1", modified: "", isDirectory: false, isLink: false)
        for name in ["../x", "x/y", "@list", "*.txt", "B.TXT", ".", "-bad"] { XCTAssertThrowsError(try ArchiveEditor.renameDestination(a.path, name: name, entries: [a, b])) }
        XCTAssertEqual(try ArchiveEditor.renameDestination(a.path, name: "新しい.txt", entries: [a, b]), "dir/新しい.txt")
    }
    func testMergePoliciesAndBackups() async throws {
        let r = try root(); defer { try? fm.removeItem(at: r) }
        for policy in ExtractionPolicy.allCases {
            let stage = r.appendingPathComponent("stage-" + policy.rawValue), dest = r.appendingPathComponent("dest-" + policy.rawValue)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false); try fm.createDirectory(at: dest, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: stage.appendingPathComponent("a.txt")); try Data("old".utf8).write(to: dest.appendingPathComponent("a.txt"))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: dest.appendingPathComponent("a.txt").path)
            let report = try await ExtractionMerger.merge(from: stage, to: dest, policy: policy, conflict: { _ in .replace })
            switch policy {
            case .skip: XCTAssertEqual(report.skipped, 1); XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.txt")), "old")
            case .rename: XCTAssertEqual(report.renamed, 1); XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a (2).txt")), "new")
            default:
                XCTAssertEqual(report.backups, 1); XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.txt")), "new")
                let backup = try XCTUnwrap(fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("ArchiveDesk-backup") })
                XCTAssertEqual(try String(contentsOf: backup), "old")
            }
        }
    }
    func testUpdateSkipsNewerAndCancel() async throws {
        let r = try root(); defer { try? fm.removeItem(at: r) }
        let stage = r.appendingPathComponent("stage"), dest = r.appendingPathComponent("dest")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false); try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("incoming".utf8).write(to: stage.appendingPathComponent("a")); try Data("keep".utf8).write(to: dest.appendingPathComponent("a"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: stage.appendingPathComponent("a").path)
        let report = try await ExtractionMerger.merge(from: stage, to: dest, policy: .update, conflict: { _ in .cancel })
        XCTAssertEqual(report.skipped, 1)
        do { _ = try await ExtractionMerger.merge(from: stage, to: dest, policy: .ask, conflict: { _ in .cancel }); XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a")), "keep")
    }
    func testMergeRefusesLinksAndDirectoryConflicts() async throws {
        let r = try root(); defer { try? fm.removeItem(at: r) }
        let stage = r.appendingPathComponent("stage"), dest = r.appendingPathComponent("dest")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false); try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("incoming".utf8).write(to: stage.appendingPathComponent("a"))
        try fm.createSymbolicLink(atPath: dest.appendingPathComponent("a").path, withDestinationPath: r.appendingPathComponent("nonexistent").path)
        do { _ = try await ExtractionMerger.merge(from: stage, to: dest, policy: .replace, conflict: { _ in .replace }); XCTFail() } catch {}
        XCTAssertFalse(fm.fileExists(atPath: r.appendingPathComponent("nonexistent").path))
        try fm.removeItem(at: dest.appendingPathComponent("a")); try fm.createDirectory(at: dest.appendingPathComponent("a"), withIntermediateDirectories: false)
        do { _ = try await ExtractionMerger.merge(from: stage, to: dest, policy: .replace, conflict: { _ in .replace }); XCTFail() } catch {}
    }
    func testRealArchiveEditsAndRollback() async throws {
        guard let seven = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_7ZZ"], let rar = ProcessInfo.processInfo.environment["ARCHIVEDESK_TEST_RAR"] else { throw XCTSkip("Engines not configured") }
        let r = try root(); defer { try? fm.removeItem(at: r) }
        let input = r.appendingPathComponent("source"), added = r.appendingPathComponent("added.txt")
        try fm.createDirectory(at: input, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: input.appendingPathComponent("one.txt")); try Data("retain".utf8).write(to: input.appendingPathComponent("keep.txt")); try Data("new".utf8).write(to: added)
        try Data("package".utf8).write(to: input.appendingPathComponent("AndroidManifest.xml"))
        let disguised = r.appendingPathComponent("package.zip")
        _ = try await CLIRunner().run(executable: seven, arguments: ["a", "-tzip", disguised.path, "AndroidManifest.xml"], directory: input) { _, _ in }
        let untouched = try ArchiveEditor.digest(disguised)
        do { _ = try await ArchiveEditor.apply(.add([added]), archive: disguised, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }; XCTFail() } catch {}
        XCTAssertEqual(try ArchiveEditor.digest(disguised), untouched)
        for ext in ["zip", "7z", "rar"] {
            let archive = r.appendingPathComponent("test." + ext)
            var options = CreationOptions(); options.format = ext == "rar" ? .rar : ext == "zip" ? .zip : .sevenZip
            let args = try ArchiveCommands.create(output: archive, inputs: [input.appendingPathComponent("one.txt"), input.appendingPathComponent("keep.txt")], password: "", headers: false, volumeMB: 0, recovery: 0, options: options)
            XCTAssertFalse(args.contains("-p-"))
            let created = try await CLIRunner().run(executable: ext == "rar" ? rar : seven, arguments: args, directory: input) { _, _ in }
            XCTAssertEqual(created.status, 0)
            let original = try ArchiveEditor.digest(archive)
            let backup = try await ArchiveEditor.apply(.add([added]), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }
            XCTAssertEqual(try ArchiveEditor.digest(backup), original)
            _ = try await ArchiveEditor.apply(.rename("one.txt", "renamed.txt"), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }
            _ = try await ArchiveEditor.apply(.delete(["added.txt"]), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }
            let listing = try await CLIRunner().run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(Set(listing.archiveEntries(backend: .sevenZip).map(\.path)), ["renamed.txt", "keep.txt"])
            let before = try ArchiveEditor.digest(archive)
            do { _ = try await ArchiveEditor.apply(.rename("renamed.txt", "keep.txt"), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }; XCTFail() } catch {}
            XCTAssertEqual(try ArchiveEditor.digest(archive), before)
            do { _ = try await ArchiveEditor.apply(.delete(["renamed.txt", "keep.txt"]), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }; XCTFail() } catch {}
            XCTAssertEqual(try ArchiveEditor.digest(archive), before)
            if ext == "rar" {
                do { _ = try await ArchiveEditor.apply(.rename("renamed.txt", "failed.txt"), archive: archive, sevenZip: seven, rar: "/usr/bin/false", runner: CLIRunner()) { _, _ in }; XCTFail() } catch {}
                XCTAssertEqual(try ArchiveEditor.digest(archive), before)
            }
            let folder = r.appendingPathComponent("nested-" + ext)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
            _ = try await ArchiveEditor.apply(.add([folder]), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }
            _ = try await ArchiveEditor.apply(.delete([folder.lastPathComponent]), archive: archive, sevenZip: seven, rar: rar, runner: CLIRunner()) { _, _ in }
            let final = try await CLIRunner().run(executable: seven, arguments: ArchiveCommands.list(archive, password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(Set(final.archiveEntries(backend: .sevenZip).filter { !$0.isDirectory }.map(\.path)), ["renamed.txt", "keep.txt"])
        }
    }
    func testCancelledEditKeepsOriginal() async throws {
        let r = try root(); defer { try? fm.removeItem(at: r) }
        let archive = r.appendingPathComponent("a.zip"); try Data("unchanged".utf8).write(to: archive)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArchiveEditor.apply(.delete(["a"]), archive: archive, sevenZip: "/usr/bin/false", rar: "/usr/bin/false", runner: CLIRunner()) { _, _ in }
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try String(contentsOf: archive), "unchanged")
    }
}
