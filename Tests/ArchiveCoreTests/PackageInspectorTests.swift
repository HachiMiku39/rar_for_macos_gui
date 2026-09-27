import XCTest
@testable import ArchiveCore

final class PackageInspectorTests: XCTestCase {
    func word(_ n: UInt64, _ width: Int = 4, little: Bool = true) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: n >> ((little ? $0 : width - 1 - $0) * 8)) })
    }
    func thin(_ id: UInt32?, wide: Bool = true, little: Bool = true) -> Data {
        var data = word(wide ? 0xfeedfacf : 0xfeedface, little: little)
        data += word(wide ? 0x100000c : 12, little: little) + word(0, little: little) + word(2, little: little)
        data += word(id == nil ? 0 : 1, little: little) + word(id == nil ? 0 : wide ? 24 : 20, little: little) + word(0, little: little)
        if wide { data += word(0) }
        if let id {
            data += word(wide ? 0x2c : 0x21, little: little) + word(wide ? 24 : 20, little: little)
            data += word(0) + word(0) + word(UInt64(id), little: little)
            if wide { data += word(0) }
        }
        return data
    }
    func testThinMachOStatesAndEndianness() {
        for wide in [false, true] { for little in [false, true] {
            for id: UInt32? in [nil, 0, 1] {
                let result = MachOInspector.inspect(thin(id, wide: wide, little: little), path: "Payload/A.app/A")
                XCTAssertEqual(result.count, 1)
                XCTAssertEqual(result[0].cryptid, id)
                XCTAssertEqual(result[0].state, id == nil ? "No encryption command" : id == 0 ? "No active encryption flag" : "Encrypted")
            }
        } }
    }
    func testBoundedBinaryOutputAndLinkListing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await CLIRunner().run(executable: "/usr/bin/yes", arguments: [], outputFile: file, outputLimit: 32) { _, _ in }
        XCTAssertTrue(result.cancelled)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 32)
        let entries = ArchiveCommands.parse("Path = link\nSize = 1\nAttributes = A lrwxrwxrwx\n", backend: .sevenZip)
        XCTAssertEqual(entries.first?.isLink, true)
        XCTAssertThrowsError(try PackageExporter.plan(entries))
    }
    func testFatMachOMixedAndMalformedSlices() {
        for fat64 in [false, true] { for little in [false, true] {
            let a = thin(1), b = thin(0), record = fat64 ? 32 : 20, header = 8 + 2 * record
            var data = word(fat64 ? 0xcafebabf : 0xcafebabe, little: little) + word(2, little: little)
            for (offset, size) in [(header, a.count), (header + a.count, b.count)] {
                data += word(0x100000c, little: little) + word(0)
                data += word(UInt64(offset), fat64 ? 8 : 4, little: little) + word(UInt64(size), fat64 ? 8 : 4, little: little) + word(0)
                if fat64 { data += word(0) }
            }
            data += a + b
            let result = MachOInspector.inspect(data, path: "Universal")
            XCTAssertEqual(result.map(\.cryptid), [1, 0])
            XCTAssertEqual(MachOInspector.aggregate(result, complete: true), "Mixed")
            data.removeLast(4)
            XCTAssertEqual(MachOInspector.inspect(data, path: "Truncated").last?.state, "Unknown")
        } }
        XCTAssertEqual(MachOInspector.aggregate([], complete: true), "Unknown")
        XCTAssertEqual(MachOInspector.aggregate(MachOInspector.inspect(thin(0), path: "A"), complete: false), "Unknown")
    }
    func testMalformedMachODoesNotCrash() {
        let valid = thin(1)
        for count in 0..<valid.count { XCTAssertEqual(MachOInspector.inspect(valid.prefix(count), path: "bad").first?.state, "Unknown") }
        var data = valid
        data.replaceSubrange(36..<40, with: word(0xffffffff))
        XCTAssertEqual(MachOInspector.inspect(data, path: "bad command").first?.state, "Unknown")
        data = valid; data.replaceSubrange(44..<48, with: word(0xffffffff))
        XCTAssertEqual(MachOInspector.inspect(data, path: "bad range").first?.state, "Unknown")
    }
    func entry(_ path: String, size: String = "0", directory: Bool = false, link: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, size: size, modified: "", isDirectory: directory, isLink: link)
    }
    func testPackageIdentificationUsesMagicAndStructure() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0x50,0x4b,3,4]).write(to: file)
        XCTAssertEqual(PackageInspector.kind(archive: file, entries: [entry("hello.txt")]), .zip)
        XCTAssertEqual(PackageInspector.kind(archive: file, entries: [entry("Payload/A.app/Info.plist")]), .ipa)
        // Resource-only split APKs need not contain DEX.
        XCTAssertEqual(PackageInspector.kind(archive: file, entries: [entry("AndroidManifest.xml")]), .apk)
        XCTAssertEqual(PackageInspector.kind(archive: file, entries: [entry("AndroidManifest.xml"), entry("Payload/A.app/Info.plist")]), .zip)
        try Data("not ZIP".utf8).write(to: file)
        XCTAssertEqual(PackageInspector.kind(archive: file, entries: [entry("Payload/A.app/Info.plist")]), .other)
    }
    func testPackagePathAndSizeGuards() throws {
        for path in ["../../Desktop/foo", "/absolute", "C:/foo", "foo\\bar", "a/./b", "a//b"] { XCTAssertThrowsError(try PackageInspector.validate([entry(path)])) }
        XCTAssertThrowsError(try PackageInspector.validate([entry("link", link: true)]))
        XCTAssertThrowsError(try PackageInspector.validate([entry("a"), entry("A")]))
        XCTAssertThrowsError(try PackageInspector.validate([entry("é"), entry("e\u{301}")]))
        XCTAssertThrowsError(try PackageInspector.validate([entry("huge", size: "536870913")]))
        try PackageInspector.validate([entry("中文/日本語/📦.txt"), entry("Empty/", directory: true)])
        XCTAssertThrowsError(try PackageInspector.validate([entry("a"), entry("a/b")], allowCaseCollisions: true))
        let planned = try PackageExporter.plan([entry("res/-O.xml"), entry("res/-o.xml"), entry("empty/", directory: true)])
        XCTAssertEqual(Set(planned.map { $0.exported.lowercased() }).count, 3)
        XCTAssertEqual(planned.filter { $0.original.contains(".xml") && $0.original != $0.exported }.count, 1)
    }
    func manifest(utf8: Bool) -> Data {
        let strings = ["manifest", "package", "org.example.demo", "http://schemas.android.com/apk/res/android", "versionCode", "uses-sdk", "minSdkVersion"]
        var offsets = Data(), bytes = Data()
        for value in strings {
            offsets += word(UInt64(bytes.count))
            if utf8 { bytes += Data([UInt8(value.utf16.count), UInt8(value.utf8.count)]) + Data(value.utf8) + Data([0]) }
            else { bytes += word(UInt64(value.utf16.count), 2) + value.data(using: .utf16LittleEndian)! + word(0, 2) }
        }
        while bytes.count % 4 != 0 { bytes.append(0) }
        var pool = word(1, 2) + word(28, 2) + word(UInt64(28 + offsets.count + bytes.count))
        pool += word(UInt64(strings.count)) + word(0) + word(utf8 ? 0x100 : 0) + word(UInt64(28 + offsets.count)) + word(0) + offsets + bytes
        func attribute(_ ns: UInt64, _ name: UInt64, _ type: UInt64, _ value: UInt64) -> Data {
            word(ns) + word(name) + word(0xffffffff) + word(8, 2) + word(0, 1) + word(type, 1) + word(value)
        }
        func element(_ name: UInt64, _ attributes: [Data]) -> Data {
            var d = word(0x102, 2) + word(16, 2) + word(UInt64(36 + attributes.count * 20)) + word(1) + word(0xffffffff)
            d += word(0xffffffff) + word(name) + word(20, 2) + word(20, 2) + word(UInt64(attributes.count), 2) + word(0, 2) + word(0, 2) + word(0, 2)
            for a in attributes { d += a }; return d
        }
        let nodes = element(0, [attribute(0xffffffff, 1, 3, 2), attribute(3, 4, 0x10, 42)]) + element(5, [attribute(3, 6, 0x10, 26)])
        return word(3, 2) + word(8, 2) + word(UInt64(8 + pool.count + nodes.count)) + pool + nodes
    }
    func testManifestUTF8UTF16AndBounds() throws {
        for utf8 in [true, false] {
            let data = manifest(utf8: utf8)
            let values = try AndroidManifestInspector.parse(data)
            XCTAssertEqual(values["package"], "org.example.demo")
            XCTAssertEqual(values["versionCode"], "42")
            XCTAssertEqual(values["minSdkVersion"], "26")
            for count in stride(from: 0, to: data.count, by: 7) { XCTAssertThrowsError(try AndroidManifestInspector.parse(data.prefix(count))) }
        }
        XCTAssertThrowsError(try AndroidManifestInspector.parse(Data("<manifest/>".utf8)))
    }
    func testMissingMetadataAndPackerUncertainty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ipa = try PackageInspector.inspectExtracted(kind: .ipa, root: root, entries: [entry("Payload/A.app/A")], rules: [])
        XCTAssertEqual(ipa.protection, "Unknown"); XCTAssertFalse(ipa.complete)
        try manifest(utf8: true).write(to: root.appendingPathComponent("AndroidManifest.xml"))
        let rule = try JSONDecoder().decode([PackerRule].self, from: Data("[{\"name\":\"Demo\",\"fileNames\":[\"libjiagu.so\"],\"applications\":[]}]".utf8))
        let apk = try PackageInspector.inspectExtracted(kind: .apk, root: root, entries: [entry("AndroidManifest.xml"), entry("lib/arm64-v8a/libjiagu.so")], rules: rule)
        XCTAssertEqual(apk.protection, "Packer suspected")
        XCTAssertFalse(apk.evidence.isEmpty)
    }
    func testRealMobilePackages() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let paths = env["ARCHIVEDESK_TEST_PACKAGES"], let engine = env["ARCHIVEDESK_TEST_7ZZ"] else { throw XCTSkip("Local mobile package fixtures not configured") }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let rules = try JSONDecoder().decode([PackerRule].self, from: Data(contentsOf: resources.appendingPathComponent("PackageRules/apk-packers.json")))
        for path in paths.components(separatedBy: "\n") {
            let url = URL(fileURLWithPath: path), runner = CLIRunner()
            let tested = try await runner.run(executable: engine, arguments: ArchiveCommands.test(url, password: "", using: .sevenZip)) { _, _ in }
            XCTAssertEqual(tested.status, 0, tested.stderr)
            let report = try await PackageInspector.inspect(archive: url, sevenZip: engine, password: "", runner: runner, rules: rules) { _, _ in }
            XCTAssertTrue(report.complete, report.evidence.joined(separator: "\n"))
            XCTAssertNotEqual(report.protection, "Unknown")
            print("MOBILE PACKAGE \(url.lastPathComponent): \(report.kind.rawValue) | \(report.protection) | slices=\(report.slices.count)")
            for field in report.fields { print("  \(field.label): \(field.value)") }
            for slice in report.slices { print("  \(slice.path) | \(slice.architecture) | \(slice.state)") }
            let listing = try await runner.run(executable: engine, arguments: ArchiveCommands.list(url, password: "", using: .sevenZip)) { _, _ in }
            let entries = listing.archiveEntries(backend: .sevenZip)
            let export = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-test-export-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: export) }
            let renamed = try await PackageExporter.extract(archive: url, destination: export, selected: [], sevenZip: engine, password: "", runner: runner) { _, _ in }
            for item in try PackageExporter.plan(entries) where !item.directory {
                XCTAssertEqual(try export.appendingPathComponent(item.exported).resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(item.size), item.original)
            }
            print("EXPORT \(url.lastPathComponent): \(entries.filter { !$0.isDirectory }.count) files verified; \(renamed) renamed paths")
            let selectedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-test-selected-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: selectedRoot) }
            let selected = report.kind == .apk ? ["AndroidManifest.xml"] : [PackageInspector.appRoots(entries)[0] + "/Info.plist"]
            _ = try await PackageExporter.extract(archive: url, destination: selectedRoot, selected: selected, sevenZip: engine, password: "", runner: runner) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: selectedRoot.appendingPathComponent(selected[0])), try Data(contentsOf: export.appendingPathComponent(selected[0])))
        }
    }
}
