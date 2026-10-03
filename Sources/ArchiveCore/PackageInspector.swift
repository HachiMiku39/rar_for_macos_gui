import Foundation

public enum PackageKind: String, Codable { case ipa = "iOS Application", apk = "Android Application", zip = "ZIP Archive", other = "Other Archive" }
public struct InspectionField: Identifiable, Codable {
    public var id: String { label }
    public let label: String
    public let value: String
}
public struct MachOSlice: Identifiable, Codable {
    public var id: String { "\(path):\(index)" }
    public let path: String
    public let index: Int
    public let architecture: String
    public let state: String
    public let cryptid: UInt32?
    public let cryptoff: UInt32?
    public let cryptsize: UInt32?
}
public struct PackageReport: Codable {
    public var kind: PackageKind
    public var fields: [InspectionField] = []
    public var slices: [MachOSlice] = []
    public var warnings: [String] = []
    public var evidence: [String] = []
    public var protection = "Unknown"
    public var complete = false
    public init(kind: PackageKind, warnings: [String] = []) { self.kind = kind; self.warnings = warnings }
}

/// Bounds-checked reads: never bind untrusted bytes to aligned C structures.
struct PackageBytes {
    let data: Data
    func uint(_ offset: Int, _ width: Int, little: Bool = true) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= data.count, width <= data.count - offset else { throw PackageFailure.malformed }
        var value: UInt64 = 0
        for i in 0..<width { let index = little ? offset + width - 1 - i : offset + i; value = (value << 8) | UInt64(data[index]) }
        return value
    }
    func int(_ offset: Int, _ width: Int = 4, little: Bool = true) throws -> Int {
        let value = try uint(offset, width, little: little)
        guard value <= UInt64(Int.max) else { throw PackageFailure.malformed }; return Int(value)
    }
}
public enum PackageFailure: LocalizedError {
    case malformed, unsafe, limit, cancelled, engine(String)
    public var errorDescription: String? {
        switch self {
        case .malformed: return "Malformed package metadata."
        case .unsafe: return "Unsafe paths, links or filename collisions prevent package inspection."
        case .limit: return "Package inspection limit exceeded (2 GB total, 512 MB per file, 50000 entries)."
        case .cancelled: return "Package inspection cancelled."
        case .engine(let text): return text
        }
    }
}

public enum MachOInspector {
    public static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = (try? PackageBytes(data: data).uint(0, 4, little: false)) ?? 0
        return [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)
    }
    public static func inspect(_ data: Data, path: String) -> [MachOSlice] {
        let b = PackageBytes(data: data)
        func unknown(_ index: Int = 0) -> MachOSlice { MachOSlice(path: path, index: index, architecture: "Unknown", state: "Unknown", cryptid: nil, cryptoff: nil, cryptsize: nil) }
        func thin(_ offset: Int, _ size: Int, _ index: Int, expectedCPU: UInt64? = nil) throws -> MachOSlice {
            guard offset >= 0, size >= 28, offset <= data.count, size <= data.count - offset else { throw PackageFailure.malformed }
            let magic = try b.uint(offset, 4, little: false)
            guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { throw PackageFailure.malformed }
            let little = magic == 0xcefaedfe || magic == 0xcffaedfe
            let header = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
            guard size >= header else { throw PackageFailure.malformed }
            let cpu = try b.uint(offset + 4, 4, little: little), sub = try b.uint(offset + 8, 4, little: little)
            if let expectedCPU, expectedCPU != cpu { throw PackageFailure.malformed }
            let names: [UInt64: String] = [12: "arm", 0x100000c: "arm64", 0x200000c: "arm64_32", 7: "x86", 0x1000007: "x86_64"]
            let arch = (names[cpu] ?? "CPU \(cpu)") + " (subtype \(sub & 0xffffff))"
            let count = try b.int(offset + 16, little: little), length = try b.int(offset + 20, little: little)
            guard length <= size - header, count <= length / 8, count <= 100_000 else { throw PackageFailure.malformed }
            var cursor = offset + header
            let end = cursor + length
            var encryption: (UInt32, UInt32, UInt32)?
            for _ in 0..<count {
                guard cursor <= end - 8 else { throw PackageFailure.malformed }
                let command = try b.uint(cursor, 4, little: little), commandSize = try b.int(cursor + 4, little: little)
                guard commandSize >= 8, commandSize % 4 == 0, commandSize <= end - cursor else { throw PackageFailure.malformed }
                if command == 0x21 || command == 0x2c {
                    guard encryption == nil, commandSize >= (command == 0x2c ? 24 : 20) else { throw PackageFailure.malformed }
                    let start = try b.uint(cursor + 8, 4, little: little), length = try b.uint(cursor + 12, 4, little: little), id = try b.uint(cursor + 16, 4, little: little)
                    guard start <= UInt64(size), length <= UInt64(size) - start else { throw PackageFailure.malformed }
                    encryption = (UInt32(id), UInt32(start), UInt32(length))
                }
                cursor += commandSize
            }
            guard cursor == end else { throw PackageFailure.malformed }
            return MachOSlice(path: path, index: index, architecture: arch, state: encryption.map { $0.0 == 0 ? "No active encryption flag" : "Encrypted" } ?? "No encryption command", cryptid: encryption?.0, cryptoff: encryption?.1, cryptsize: encryption?.2)
        }
        do {
            let magic = try b.uint(0, 4, little: false)
            guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { return [try thin(0, data.count, 0)] }
            let little = magic == 0xbebafeca || magic == 0xbfbafeca, wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = try b.int(4, little: little), record = wide ? 32 : 20
            guard count > 0, count <= 64, data.count >= 8 + count * record else { throw PackageFailure.malformed }
            let tableEnd = 8 + count * record
            var ranges: [Range<Int>] = [], results: [MachOSlice] = []
            for index in 0..<count {
                do {
                    let cursor = 8 + index * record
                    let start = try b.int(cursor + 8, wide ? 8 : 4, little: little)
                    let length = try b.int(cursor + (wide ? 16 : 12), wide ? 8 : 4, little: little)
                    guard start >= tableEnd, start <= data.count, length > 0, length <= data.count - start else { throw PackageFailure.malformed }
                    let range = start..<(start + length)
                    guard !ranges.contains(where: { $0.overlaps(range) }) else { throw PackageFailure.malformed }
                    ranges.append(range)
                    results.append(try thin(start, length, index, expectedCPU: b.uint(cursor, 4, little: little)))
                } catch { results.append(unknown(index)) }
            }
            return results
        } catch { return [unknown()] }
    }
    public static func aggregate(_ slices: [MachOSlice], complete: Bool) -> String {
        let encrypted = slices.contains { $0.state == "Encrypted" }
        let clear = slices.contains { $0.state == "No active encryption flag" || $0.state == "No encryption command" }
        if encrypted && clear { return "Mixed" }
        if encrypted { return "Encrypted" }
        if !complete || slices.isEmpty || slices.contains(where: { $0.state == "Unknown" }) { return "Unknown" }
        return "No active FairPlay encryption detected"
    }
}

/// Read-only AXML subset for manifest metadata; not a decompiler or resource resolver.
public enum AndroidManifestInspector {
    public static func parse(_ data: Data) throws -> [String: String] {
        guard data.count <= 16 * 1024 * 1024 else { throw PackageFailure.limit }
        let b = PackageBytes(data: data)
        guard try b.int(0, 2) == 3, try b.int(2, 2) == 8, try b.int(4) == data.count else { throw PackageFailure.malformed }
        var pool: [String] = [], values: [String: String] = [:], cursor = 8
        func string(_ index: Int) throws -> String { guard pool.indices.contains(index) else { throw PackageFailure.malformed }; return pool[index] }
        while cursor < data.count {
            let type = try b.int(cursor, 2), header = try b.int(cursor + 2, 2), size = try b.int(cursor + 4)
            guard header >= 8, size >= header, size <= data.count - cursor else { throw PackageFailure.malformed }
            let end = cursor + size
            if type == 1 {
                guard pool.isEmpty, header >= 28 else { throw PackageFailure.malformed }
                let count = try b.int(cursor + 8), styles = try b.int(cursor + 12), flags = try b.int(cursor + 16), start = try b.int(cursor + 20)
                guard count <= 100_000, styles <= 100_000, header + (count + styles) * 4 <= start, start < size else { throw PackageFailure.malformed }
                let styleStart = try b.int(cursor + 24)
                let stringEnd = styleStart == 0 ? end : cursor + styleStart
                guard stringEnd <= end, stringEnd >= cursor + start else { throw PackageFailure.malformed }
                func length(_ p: inout Int, utf8: Bool) throws -> Int {
                    let width = utf8 ? 1 : 2, mask = utf8 ? 0x80 : 0x8000
                    guard p <= stringEnd - width else { throw PackageFailure.malformed }
                    let first = try b.int(p, width); p += width
                    if first & mask == 0 { return first }
                    guard p <= stringEnd - width else { throw PackageFailure.malformed }
                    let second = try b.int(p, width); p += width
                    return ((first & (mask - 1)) << (utf8 ? 8 : 16)) | second
                }
                for i in 0..<count {
                    var p = cursor + start + (try b.int(cursor + header + i * 4))
                    guard p >= cursor + start, p < stringEnd else { throw PackageFailure.malformed }
                    let utf8 = flags & 0x100 != 0
                    let firstLength = try length(&p, utf8: utf8)
                    let bytes = utf8 ? try length(&p, utf8: true) : firstLength * 2
                    let terminator = utf8 ? 1 : 2
                    guard bytes <= stringEnd - p - terminator, try b.int(p + bytes, terminator) == 0,
                          let text = String(data: data.subdata(in: p..<(p + bytes)), encoding: utf8 ? .utf8 : .utf16LittleEndian), text.utf16.count == firstLength else { throw PackageFailure.malformed }
                    pool.append(text)
                }
            } else if type == 0x102 {
                guard header >= 16, size >= header + 20 else { throw PackageFailure.malformed }
                let ext = cursor + header, element = try string(b.int(ext + 4))
                let start = try b.int(ext + 8, 2), stride = try b.int(ext + 10, 2), count = try b.int(ext + 12, 2)
                guard start >= 20, stride >= 20, count <= 10_000, ext + start <= end, count * stride <= end - ext - start else { throw PackageFailure.malformed }
                for i in 0..<count {
                    let at = ext + start + i * stride
                    let namespaceIndex = try b.int(at), name = try string(b.int(at + 4)), raw = try b.int(at + 8)
                    let namespace = namespaceIndex == 0xffffffff ? "" : try string(namespaceIndex)
                    guard try b.int(at + 12, 2) == 8 else { throw PackageFailure.malformed }
                    let valueType = try b.int(at + 15, 1), number = try b.uint(at + 16, 4)
                    let value: String
                    if raw != 0xffffffff { value = try string(raw) }
                    else if valueType == 3 { value = try string(Int(number)) }
                    else if [0x10, 0x11, 0x12].contains(valueType) { value = String(number) }
                    else { value = "@0x" + String(number, radix: 16) }
                    if element == "manifest", name == "package", namespace.isEmpty { values["package"] = value }
                    if namespace == "http://schemas.android.com/apk/res/android" {
                        if element == "manifest", ["versionName", "versionCode", "versionCodeMajor"].contains(name) { values[name] = value }
                        if element == "uses-sdk", ["minSdkVersion", "targetSdkVersion"].contains(name) { values[name] = value }
                        if element == "application", ["name", "label"].contains(name) { values["application." + name] = value }
                    }
                }
            }
            cursor = end
        }
        guard let package = values["package"], !package.isEmpty else { throw PackageFailure.malformed }
        return values
    }
}

public struct PackerRule: Codable {
    public let name: String
    public let fileNames: [String]
    public let applications: [String]
}

public enum PackageInspector {
    public static func kind(archive: URL, entries: [ArchiveEntry]) -> PackageKind {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return .other }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        guard [[0x50,0x4b,3,4], [0x50,0x4b,5,6], [0x50,0x4b,6,6]].contains(Array(magic).map(Int.init)) else { return .other }
        let roots = appRoots(entries)
        let android = entries.contains { $0.path == "AndroidManifest.xml" && !$0.isDirectory }
        if !roots.isEmpty && !android { return .ipa }
        if android && roots.isEmpty { return .apk }
        return .zip
    }
    public static func appRoots(_ entries: [ArchiveEntry]) -> [String] {
        Array(Set(entries.compactMap { item -> String? in
            let parts = item.path.split(separator: "/")
            guard parts.count >= 3, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return nil }
            return "Payload/" + parts[1]
        })).sorted()
    }
    public static func validate(_ entries: [ArchiveEntry], allowCaseCollisions: Bool = false) throws {
        guard entries.count <= 50_000 else { throw PackageFailure.limit }
        var names = Set<String>(), total: UInt64 = 0
        for item in entries {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard ArchiveCommands.safePath(item.path), !item.path.contains("\\"), !item.isLink,
                  !parts.contains("."), !parts.dropLast().contains(""), item.path.utf8.count < 4096 else { throw ArchiveError.details("Unsafe archive path: {0}", [item.path]) }
            let trimmed = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let canonical = allowCaseCollisions ? trimmed : trimmed.decomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(canonical).inserted else { throw PackageFailure.unsafe }
            if !item.isDirectory {
                guard let size = UInt64(item.size), size <= 512 * 1024 * 1024 else { throw PackageFailure.limit }
                total += size
                guard total <= 2 * 1024 * 1024 * 1024 else { throw PackageFailure.limit }
            }
        }
        let regular = Set(entries.filter { !$0.isDirectory }.map(\.path))
        for item in entries {
            var parent = (item.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !regular.contains(parent) else { throw PackageFailure.unsafe }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }
    /// Explicit, cancellable deep scan. Snapshot and private staging never modify the original package.
    public static func inspect(archive: URL, sevenZip: String, password: String, runner: CLIRunner, rules: [PackerRule], update: @escaping (String, String) -> Void) async throws -> PackageReport {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArchiveDesk-inspect-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        guard (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 * 1024 else { throw PackageFailure.limit }
        let snapshotFolder = root.appendingPathComponent("snapshot")
        try fm.createDirectory(at: snapshotFolder, withIntermediateDirectories: false)
        let snapshot = snapshotFolder.appendingPathComponent(archive.lastPathComponent), output = root.appendingPathComponent("contents")
        try fm.copyItem(at: archive, to: snapshot)
        try Task.checkCancellation()
        func checked(_ result: CLIResult) throws {
            if result.cancelled || Task.isCancelled { throw PackageFailure.cancelled }
            if result.status != 0 { throw PackageFailure.engine("Package engine error \(result.status): \(result.stderr)\n\(result.stdout)") }
        }
        let listing = try await runner.run(executable: sevenZip, arguments: ArchiveCommands.list(snapshot, password: password, using: .sevenZip), password: password, update: update)
        try checked(listing)
        let entries = listing.archiveEntries(backend: .sevenZip)
        let kind = kind(archive: snapshot, entries: entries)
        guard kind == .ipa || kind == .apk else {
            return PackageReport(kind: kind, warnings: ["Package structure does not match IPA or APK. It can still be browsed as an archive."])
        }
        try validate(entries, allowCaseCollisions: kind == .apk)
        try fm.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        let extracted: CLIResult
        if kind == .apk {
            extracted = try await runner.run(executable: sevenZip, arguments: ["x", "-so", "-spd", "-bd", "--", snapshot.path, "AndroidManifest.xml"], password: password, outputFile: output.appendingPathComponent("AndroidManifest.xml"), outputLimit: 16 * 1024 * 1024, update: update)
        } else {
            extracted = try await runner.run(executable: sevenZip, arguments: ArchiveCommands.extract(snapshot, destination: output, selected: [], password: password, using: .sevenZip), password: password, update: update)
        }
        try checked(extracted)
        var report = try inspectExtracted(kind: kind, root: output, entries: entries, rules: rules)
        if listing.stdout.contains("Minor_Extra_ERROR") { report.warnings.append("ZIP extra-field anomalies were reported by the engine. Review the task log; extraction is not signature verification.") }
        return report
    }
    public static func inspectExtracted(kind: PackageKind, root: URL, entries: [ArchiveEntry], rules: [PackerRule]) throws -> PackageReport {
        try validate(entries, allowCaseCollisions: kind == .apk)
        var report = PackageReport(kind: kind)
        let files = entries.filter { !$0.isDirectory }
        func read(_ path: String, limit: Int) throws -> Data {
            let url = root.appendingPathComponent(path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PackageFailure.unsafe }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PackageFailure.unsafe }
            guard let size = values.fileSize, size <= limit else { throw PackageFailure.limit }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        func field(_ label: String, _ value: String) { report.fields.append(InspectionField(label: label, value: String(value.prefix(4000)))) }
        if kind == .ipa {
            let roots = appRoots(entries)
            field("Applications", String(roots.count))
            if roots.count != 1 { report.warnings.append("Multiple top-level apps detected; metadata is shown separately for each app.") }
            var expected = Set<String>(), complete = true
            let plists = files.filter { $0.path.hasSuffix("/Info.plist") && ["app", "appex", "framework"].contains((($0.path as NSString).deletingLastPathComponent as NSString).pathExtension) }
            for file in plists {
                try Task.checkCancellation()
                do {
                    guard let plist = try PropertyListSerialization.propertyList(from: read(file.path, limit: 4 * 1024 * 1024), format: nil) as? [String: Any] else { throw PackageFailure.malformed }
                    let parent = (file.path as NSString).deletingLastPathComponent
                    guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"), ArchiveCommands.safePath(executable), executable != "." else { throw PackageFailure.malformed }
                    expected.insert(parent + "/" + executable)
                    if roots.contains(parent) {
                        for key in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "CFBundleExecutable"] {
                            if let value = plist[key] { field(roots.count == 1 ? key : parent + " · " + key, String(describing: value)) }
                        }
                    }
                } catch { complete = false; report.evidence.append("Info.plist: \(file.path) — \(error.localizedDescription)") }
            }
            for app in roots where !files.contains(where: { $0.path == app + "/Info.plist" }) { complete = false; report.evidence.append("Missing Info.plist: " + app) }
            var seen = Set<String>()
            for file in files {
                try Task.checkCancellation()
                do {
                    let url = root.appendingPathComponent(file.path)
                    let handle = try FileHandle(forReadingFrom: url)
                    let prefix = try handle.read(upToCount: 4) ?? Data(); try handle.close()
                    let candidate = MachOInspector.hasMagic(prefix) || expected.contains(file.path) || file.path.hasSuffix(".dylib")
                    guard candidate else { continue }
                    seen.insert(file.path)
                    let slices = MachOInspector.inspect(try read(file.path, limit: 512 * 1024 * 1024), path: file.path)
                    report.slices += slices
                    if slices.contains(where: { $0.state == "Unknown" }) { complete = false }
                } catch { complete = false; report.evidence.append("Unreadable file: " + file.path) }
            }
            for missing in expected.subtracting(seen).sorted() {
                complete = false
                report.slices.append(MachOSlice(path: missing, index: 0, architecture: "Unknown", state: "Unknown", cryptid: nil, cryptoff: nil, cryptsize: nil))
            }
            let paths = files.map(\.path)
            field("Frameworks", String(Set(paths.flatMap { $0.split(separator: "/").filter { $0.hasSuffix(".framework") }.map(String.init) }).count))
            field("Extensions", String(Set(paths.flatMap { $0.split(separator: "/").filter { $0.hasSuffix(".appex") }.map(String.init) }).count))
            field("Mach-O files", String(Set(report.slices.map(\.path)).count))
            field("Architectures", Array(Set(report.slices.map(\.architecture))).sorted().joined(separator: ", "))
            report.complete = complete && !report.slices.isEmpty
            report.protection = MachOInspector.aggregate(report.slices, complete: report.complete)
            report.warnings.append("Extraction does not decrypt executable code. Encryption flags do not prove an app is unpacked or free of other protection.")
        } else if kind == .apk {
            do {
                let values = try AndroidManifestInspector.parse(read("AndroidManifest.xml", limit: 16 * 1024 * 1024))
                for key in ["package", "versionName", "versionCode", "versionCodeMajor", "minSdkVersion", "targetSdkVersion", "application.name", "application.label"] {
                    field(key, values[key] ?? "Not declared")
                }
                let paths = files.map(\.path), names = Set(paths.map { ($0 as NSString).lastPathComponent })
                for rule in rules {
                    let matched = rule.fileNames.filter(names.contains) + rule.applications.filter { $0 == values["application.name"] }
                    if !matched.isEmpty { report.evidence.append(rule.name + ": " + matched.joined(separator: ", ")) }
                }
                report.protection = rules.isEmpty ? "Unknown" : report.evidence.isEmpty ? "No known packer signatures detected" : "Packer suspected"
                report.complete = !rules.isEmpty
            } catch { report.protection = "Unknown"; report.warnings.append("Manifest parsing failed. Files can still be extracted.") }
            let dex = files.filter { $0.path.range(of: "^classes([2-9][0-9]*|1[0-9]+)?\\.dex$", options: .regularExpression) != nil }
            let native = files.filter { $0.path.hasPrefix("lib/") && $0.path.hasSuffix(".so") }
            field("DEX files", String(dex.count)); field("Multi-Dex", dex.count > 1 ? "Yes" : "No")
            field("Native libraries", String(native.count))
            field("Supported ABI", Array(Set(native.compactMap { $0.path.split(separator: "/").dropFirst().first.map(String.init) })).sorted().joined(separator: ", "))
            field("resources.arsc", files.contains { $0.path == "resources.arsc" } ? "Present" : "Not present (may be a split APK)")
            report.warnings.append("Packer detection is heuristic and limited to bundled rules. No matches cannot exclude custom protection, obfuscation or runtime-loaded code.")
            report.warnings.append("Resource references are shown as IDs; resource tables, DEX code and signatures are not decoded or verified.")
        }
        if !report.complete { report.warnings.append("Inspection is incomplete. Review unknown components and errors before drawing conclusions.") }
        return report
    }
}

public struct PackageExportPath: Codable {
    public let original: String
    public let exported: String
    public let directory: Bool
    public let size: String
}
public enum PackageExporter {
    public static func plan(_ entries: [ArchiveEntry]) throws -> [PackageExportPath] {
        try PackageInspector.validate(entries, allowCaseCollisions: true)
        var assigned: [String: String] = [:], used = Set<String>(), result: [PackageExportPath] = []
        for item in entries.sorted(by: { $0.path < $1.path }) {
            var original = "", parent = ""
            for part in item.path.split(separator: "/") {
                original = original.isEmpty ? String(part) : original + "/" + part
                if let known = assigned[original] { parent = known; continue }
                let component = String(part)
                var leaf = component, count = 1
                var candidate = parent.isEmpty ? leaf : parent + "/" + leaf
                while leaf.utf8.count > 240 || used.contains(candidate.decomposedStringWithCanonicalMapping.lowercased()) {
                    count += 1
                    leaf = String(decoding: component.utf8.prefix(160), as: UTF8.self) + "__ArchiveDesk_\(count)"
                    candidate = parent.isEmpty ? leaf : parent + "/" + leaf
                }
                guard candidate.utf8.count < 4096 else { throw PackageFailure.unsafe }
                used.insert(candidate.decomposedStringWithCanonicalMapping.lowercased()); assigned[original] = candidate; parent = candidate
            }
            result.append(PackageExportPath(original: item.path, exported: parent, directory: item.isDirectory, size: item.size))
        }
        return result
    }
    /// Collision-safe export: ordinary packages use 7-Zip directly. Colliding paths
    /// use one bounded stdout stream per file, never an archive-controlled disk path.
    public static func extract(archive: URL, destination: URL, selected: [String], sevenZip: String, password: String, runner: CLIRunner, update: @escaping (String, String) -> Void) async throws -> Int {
        let fm = FileManager.default
        guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else { throw PackageFailure.unsafe }
        let staging = fm.temporaryDirectory.appendingPathComponent("ArchiveDesk-export-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        guard (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 * 1024 else { throw PackageFailure.limit }
        let snapshot = staging.appendingPathComponent(archive.lastPathComponent)
        try fm.copyItem(at: archive, to: snapshot)
        func checked(_ result: CLIResult) throws {
            if result.cancelled || Task.isCancelled { throw PackageFailure.cancelled }
            guard result.status == 0 else { throw PackageFailure.engine("Export engine error \(result.status): \(result.stderr)\n\(result.stdout)") }
        }
        try Task.checkCancellation()
        let listing = try await runner.run(executable: sevenZip, arguments: ArchiveCommands.list(snapshot, password: password, using: .sevenZip), password: password, update: update)
        try checked(listing)
        let all = listing.archiveEntries(backend: .sevenZip)
        let plan = try plan(all)
        let chosen = plan.filter { item in selected.isEmpty || selected.contains(item.original) || selected.contains(where: { item.original.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }) }
        guard selected.isEmpty || !chosen.isEmpty else { throw PackageFailure.unsafe }
        let renamed = chosen.filter { $0.original.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != $0.exported }.count
        if renamed == 0 {
            try Task.checkCancellation()
            let result = try await runner.run(executable: sevenZip, arguments: ArchiveCommands.extract(snapshot, destination: destination, selected: selected, password: password, using: .sevenZip), password: password, update: update)
            try checked(result)
        } else {
            let mapURL = destination.appendingPathComponent("ArchiveDesk-path-map-" + UUID().uuidString + ".json")
            struct Mapping: Encodable { let complete: Bool; let paths: [PackageExportPath] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Mapping(complete: false, paths: chosen)).write(to: mapURL, options: .atomic)
            for (index, item) in chosen.enumerated() {
                try Task.checkCancellation()
                let file = destination.appendingPathComponent(item.exported)
                try fm.createDirectory(at: item.directory ? file : file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if item.directory { continue }
                try ArchiveCommands.literalSelection([item.original])
                let args = ["x", "-so", "-spd", "-bd", "--", snapshot.path, item.original]
                let extracted = try await runner.run(executable: sevenZip, arguments: args, password: password, outputFile: file, outputLimit: Int(item.size) ?? 0) { _, _ in }
                try checked(extracted)
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(item.size) else { throw PackageFailure.malformed }
                update("\(index + 1)/\(chosen.count) · \(item.original) → \(item.exported)", "")
            }
            try encoder.encode(Mapping(complete: true, paths: chosen)).write(to: mapURL, options: .atomic)
        }
        return renamed
    }
}
