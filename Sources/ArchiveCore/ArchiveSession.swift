import Foundation
import CryptoKit
import Darwin

public enum ArchiveEdit {
    case add([URL]), delete([String]), rename(String, String)
}

/// Editing is deliberately limited to plain, single-volume archives. Work never
/// reaches the original until the modified copy has passed an integrity test.
public enum ArchiveEditor {
    public static func refusal(_ url: URL, listing: String) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ["rar", "zip", "7z"].contains(ext) else { return "Editing requires a single-volume RAR, ZIP or 7z archive." }
        let lines = listing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = ext == "rar" ? ["Type = Rar", "Type = Rar5"] : ["Type = " + ext]
        guard lines.contains(where: expected.contains) else { return "The detected archive format does not match its extension." }
        if lines.contains("Encrypted = +") || listing.contains("7zAES") || listing.contains("AES-") {
            return "Encrypted archives are read-only in this version."
        }
        if lines.contains(where: { $0.hasPrefix("Volumes = ") && $0 != "Volumes = 1" }) || lines.contains("Multivolume = +") || url.lastPathComponent.range(of: "(?i)\\.part[0-9]+\\.rar$", options: .regularExpression) != nil {
            return "Split archives are read-only in this version."
        }
        if lines.contains("Locked = +") { return "Locked archives are read-only." }
        return nil
    }
    public static func digest(_ url: URL) throws -> Data {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var hash = SHA256()
        while let bytes = try f.read(upToCount: 1024 * 1024), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return Data(hash.finalize())
    }
    public static func renameDestination(_ old: String, name: String, entries: [ArchiveEntry]) throws -> String {
        try ArchiveCommands.literalSelection([old, name])
        guard name != ".", !name.contains("/"), !name.contains("\\"), !name.hasPrefix("-"), name.utf8.count <= 240,
              entries.contains(where: { $0.path == old && !$0.isDirectory }) else { throw ArchiveError.invalid("Choose one regular file and a simple new filename.") }
        let parent = (old as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        let key = target.decomposedStringWithCanonicalMapping.lowercased()
        guard !entries.contains(where: { $0.path.decomposedStringWithCanonicalMapping.lowercased() == key || $0.path.decomposedStringWithCanonicalMapping.lowercased().hasPrefix(key + "/") }) else { throw ArchiveError.invalid("That name already exists in the archive.") }
        return target
    }
    public static func apply(_ edit: ArchiveEdit, archive: URL, sevenZip: String, rar: String, runner: CLIRunner, update: @escaping (String, String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalid("Editing requires a regular local archive file.") }
        let before = try digest(archive)
        let root = archive.deletingLastPathComponent().appendingPathComponent(".ArchiveDesk-edit-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let copy = root.appendingPathComponent(archive.lastPathComponent)
        try fm.copyItem(at: archive, to: copy)
        guard try digest(copy) == before else { throw ArchiveError.invalid("The archive changed during editing. Nothing was replaced.") }
        func run(_ engine: String, _ args: [String], at directory: URL? = nil) async throws -> CLIResult {
            try Task.checkCancellation()
            let r = try await runner.run(executable: engine, arguments: args, directory: directory, update: update)
            if r.cancelled { throw CancellationError() }
            guard r.status == 0 else { throw ArchiveError.details("Engine exit code {0}. The original archive was not changed. {1}", [String(r.status), r.stderr + "\n" + r.stdout]) }
            return r
        }
        let listing = try await run(sevenZip, ArchiveCommands.list(copy, password: "", using: .sevenZip))
        if let reason = refusal(copy, listing: listing.stdout) { throw ArchiveError.invalid(reason) }
        let entries = listing.archiveEntries(backend: .sevenZip)
        let package = PackageInspector.kind(archive: copy, entries: entries)
        guard package != .ipa && package != .apk else { throw ArchiveError.invalid("Application packages are read-only.") }
        try PackageInspector.validate(entries)
        let isRAR = archive.pathExtension.lowercased() == "rar"
        let engine = isRAR ? rar : sevenZip
        let switches = isRAR ? ["-cfg-", "-idc"] : ["-spd", "-sccUTF-8"]
        var expected = Set(entries.map(\.path)), addedPaths = Set<String>()
        switch edit {
        case .delete(let paths):
            try ArchiveCommands.literalSelection(paths)
            guard !paths.isEmpty, paths.allSatisfy({ path in expected.contains(path) || expected.contains(where: { $0.hasPrefix(path + "/") }) }) else { throw ArchiveError.invalid("Select files to edit.") }
            let targets = entries.filter { item in paths.contains(item.path) || paths.contains(where: { item.path.hasPrefix($0 + "/") }) }.map(\.path)
            guard !targets.isEmpty, targets.count < entries.count else { throw ArchiveError.invalid("Keep at least one item in the archive.") }
            try ArchiveCommands.literalSelection(targets)
            _ = try await run(engine, ["d"] + switches + ["--", copy.path] + targets)
            expected.subtract(targets)
        case .rename(let old, let name):
            let target = try renameDestination(old, name: name, entries: entries)
            _ = try await run(engine, ["rn"] + switches + ["--", copy.path, old, target])
            expected.remove(old); expected.insert(target)
        case .add(let inputs):
            guard !inputs.isEmpty, Set(inputs.map { $0.lastPathComponent.decomposedStringWithCanonicalMapping.lowercased() }).count == inputs.count else { throw ArchiveError.invalid("Select source items with distinct names.") }
            let payload = root.appendingPathComponent("inputs")
            try fm.createDirectory(at: payload, withIntermediateDirectories: false)
            for input in inputs {
                try ArchiveCommands.literalSelection([input.lastPathComponent])
                guard !input.lastPathComponent.hasPrefix("-"), input.lastPathComponent != ".", input.resolvingSymlinksInPath() != archive.resolvingSymlinksInPath(), !root.path.hasPrefix(input.resolvingSymlinksInPath().path + "/") else { throw ArchiveError.invalid("The archive or its parent cannot be added to itself.") }
                var sources = [input]
                if let walk = fm.enumerator(at: input, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) { for case let file as URL in walk { sources.append(file) } }
                var bytes = 0
                guard sources.count <= 50_000 else { throw PackageFailure.limit }
                for file in sources {
                    try Task.checkCancellation()
                    let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    guard value.isSymbolicLink != true, value.isRegularFile == true || value.isDirectory == true else { throw ArchiveError.invalid("Links and special files cannot be added.") }
                    let size = value.isRegularFile == true ? (value.fileSize ?? Int.max) : 0
                    guard size >= 0, size <= 512 * 1024 * 1024, bytes <= 2 * 1024 * 1024 * 1024 - size else { throw PackageFailure.limit }; bytes += size
                }
                let target = payload.appendingPathComponent(input.lastPathComponent)
                try fm.copyItem(at: input, to: target)
            }
            guard let walk = fm.enumerator(at: payload, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw ArchiveError.invalid("Cannot read source files.") }
            var files: [ArchiveEntry] = []
            for case let file as URL in walk {
                try Task.checkCancellation()
                let v = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true else { throw ArchiveError.invalid("Links and special files cannot be added.") }
                let base = payload.resolvingSymlinksInPath().path
                let full = file.resolvingSymlinksInPath().path
                guard full.hasPrefix(base + "/") else { throw PackageFailure.unsafe }
                let path = String(full.dropFirst(base.count + 1))
                files.append(ArchiveEntry(path: path, size: String(v.fileSize ?? 0), modified: "", isDirectory: v.isDirectory == true, isLink: false))
                if v.isRegularFile == true { addedPaths.insert(path) }
            }
            try PackageInspector.validate(files)
            let merged = entries.filter { original in !files.contains(where: { $0.path == original.path }) } + files
            try PackageInspector.validate(merged)
            expected.formUnion(addedPaths)
            _ = try await run(engine, ["a"] + switches + (isRAR ? ["-r"] : ["-sse"]) + ["--", copy.path] + inputs.map { "./" + $0.lastPathComponent }, at: payload)
        }
        _ = try await run(sevenZip, ArchiveCommands.test(copy, password: "", using: .sevenZip))
        let result = try await run(sevenZip, ArchiveCommands.list(copy, password: "", using: .sevenZip))
        let after = result.archiveEntries(backend: .sevenZip)
        try PackageInspector.validate(after)
        let paths = Set(after.map(\.path))
        // Engines may add/remove explicit directory records; regular files must agree.
        let expectedFiles = expected.subtracting(entries.filter(\.isDirectory).map(\.path))
        guard expectedFiles.isSubset(of: paths), Set(after.filter { !$0.isDirectory }.map(\.path)) == expectedFiles else { throw ArchiveError.invalid("The edited contents did not match the request. Nothing was replaced.") }
        try Task.checkCancellation()
        guard try digest(archive) == before else { throw ArchiveError.invalid("The archive changed during editing. Nothing was replaced.") }
        let backup = archive.deletingLastPathComponent().appendingPathComponent(archive.lastPathComponent + ".ArchiveDesk-backup-" + UUID().uuidString)
        try fm.copyItem(at: archive, to: backup)
        guard try digest(backup) == before, try digest(archive) == before else { throw ArchiveError.invalid("The archive changed during editing. Nothing was replaced.") }
        try Task.checkCancellation()
        guard Darwin.rename(copy.path, archive.path) == 0 else { throw ArchiveError.invalid("Cannot replace the archive. The original and backup were kept.") }
        return backup
    }
}

public enum ExtractionPolicy: String, CaseIterable { case ask = "Ask before replacing", skip = "Skip existing files", rename = "Rename incoming files", replace = "Replace existing files", update = "Update older files" }
public enum ConflictChoice { case replace, skip, rename, cancel }
public struct ExtractionReport {
    public var written = 0; public var skipped = 0; public var renamed = 0; public var backups = 0
    public var processedBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var currentFile = ""
    public var fraction: Double? { totalBytes > 0 ? min(1, Double(processedBytes) / Double(totalBytes)) : nil }
}

public enum ExtractionMerger {
    /// Refuse symlink ancestors rather than trusting string-prefix checks.
    public static func checkDirectory(_ url: URL) throws {
        var path = ""
        for part in url.path.split(separator: "/") {
            guard part != ".", part != ".." else { throw ArchiveError.invalid("Unsafe extraction path.") }
            path += "/" + part
            // macOS exposes these two OS-owned aliases in file-panel URLs.
            if path == "/var" || path == "/tmp" { path = "/private" + path }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw ArchiveError.details("Unsafe destination component: {0}", [path]) }
        }
    }
    public static func merge(from stage: URL, to destination: URL, policy: ExtractionPolicy, conflict: (String) async -> ConflictChoice, update: (ExtractionReport) -> Void = { _ in }) async throws -> ExtractionReport {
        let fm = FileManager.default
        try checkDirectory(destination)
        guard let walk = fm.enumerator(at: stage, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { throw ArchiveError.invalid("Cannot read extracted files.") }
        var files: [URL] = []
        for case let file as URL in walk { try Task.checkCancellation(); files.append(file) }
        files.sort { $0.path < $1.path }
        var report = ExtractionReport()
        for file in files {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                let sum = report.totalBytes.addingReportingOverflow(UInt64(max(0, values.fileSize ?? 0)))
                guard !sum.overflow else { throw ArchiveError.invalid("Invalid uncompressed size.") }
                report.totalBytes = sum.partialValue
            }
        }
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        func notify(_ force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            if force || now - lastUpdate >= 0.2 { update(report); lastUpdate = now }
        }
        notify(true)
        var directories: [(URL, URL)] = []
        for file in files {
            try Task.checkCancellation()
            let base = stage.resolvingSymlinksInPath().path, full = file.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { throw ArchiveError.invalid("Unsafe extraction path.") }
            let relative = String(full.dropFirst(base.count + 1))
            guard ArchiveCommands.safePath(relative) else { throw ArchiveError.invalid("Unsafe extraction path.") }
            report.currentFile = relative
            let fileBytes = UInt64(max(0, (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            let v = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true else { throw ArchiveError.invalid("Links and special files cannot be exported.") }
            var target = destination.appendingPathComponent(relative)
            try checkDirectory(target.deletingLastPathComponent())
            var exists = fm.fileExists(atPath: target.path)
            // resourceValues also catches dangling symlinks (fileExists follows them).
            if let old = try? target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]), old.isSymbolicLink == true { throw ArchiveError.invalid("The destination contains a link or is not a directory.") }
            if v.isDirectory == true {
                if exists { try checkDirectory(target) } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    directories.append((file, target))
                }
                continue
            }
            if exists {
                let old = try target.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard old.isRegularFile == true else { throw ArchiveError.invalid("A file conflicts with an existing directory or special file.") }
                let choice: ConflictChoice
                switch policy {
                case .ask: choice = await conflict(relative)
                case .skip: choice = .skip
                case .rename: choice = .rename
                case .replace: choice = .replace
                case .update: choice = (v.contentModificationDate ?? .distantPast) > (old.contentModificationDate ?? .distantFuture) ? .replace : .skip
                }
                try Task.checkCancellation()
                switch choice {
                case .cancel: throw CancellationError()
                case .skip: report.skipped += 1; report.processedBytes += fileBytes; notify(); continue
                case .rename:
                    var n = 2
                    repeat { target = target.deletingLastPathComponent().appendingPathComponent((file.lastPathComponent as NSString).deletingPathExtension + " (\(n))" + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)); n += 1 } while fm.fileExists(atPath: target.path) || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                    exists = false; report.renamed += 1
                case .replace: break
                }
            }
            try checkDirectory(target.deletingLastPathComponent())
            let before = report.processedBytes
            if try ExtractionSafety.copyVerifiedFile(file, to: target, replacing: exists, progress: { copied, _ in
                report.processedBytes = before + copied; notify()
            }) { report.backups += 1 }
            report.written += 1; notify()
        }
        // Finalize new directory modes/times only after their children have been written.
        for (source, target) in directories.reversed() {
            let attrs = try fm.attributesOfItem(atPath: source.path)
            var kept: [FileAttributeKey: Any] = [:]
            if let mode = attrs[.posixPermissions] as? NSNumber { kept[.posixPermissions] = mode.intValue & 0o777 }
            kept[.modificationDate] = attrs[.modificationDate]
            try checkDirectory(target)
            try fm.setAttributes(kept, ofItemAtPath: target.path)
        }
        notify(true); return report
    }
}

/// Build privately beside the destination; no final filename is visible on failure/cancel.
public enum ArchiveCreator {
    public static func create(output: URL, inputs: [URL], password: String, headers: Bool, volumeMB: Int, recovery: Int,
                              options: CreationOptions, executable: String, runner: CLIRunner,
                              phase: @escaping (String, Double?) -> Void = { _, _ in },
                              update: @escaping (String, String) -> Void) async throws -> URL {
        _ = try ArchiveCommands.create(output: output, inputs: inputs, password: password, headers: headers,
                                       volumeMB: volumeMB, recovery: recovery, options: options)
        let fm = FileManager.default, parent = output.deletingLastPathComponent()
        try ExtractionMerger.checkDirectory(parent)
        try DiskSpace.require(0, at: parent)
        let stage = parent.appendingPathComponent(".ArchiveDesk-create-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(output.lastPathComponent)
        if options.format.isTar {
            let tar = options.format == .tar ? staged : stage.appendingPathComponent(output.deletingPathExtension().lastPathComponent)
            var tarOptions = options; tarOptions.format = .tar
            let tarArgs = try ArchiveCommands.create(output: tar, inputs: inputs, password: "", headers: false, volumeMB: 0, recovery: 0, options: tarOptions)
            func require(_ result: CLIResult) throws {
                if result.cancelled || Task.isCancelled { throw CancellationError() }
                guard result.status == 0 else { throw ArchiveError.invalid("TAR creation or verification failed. Check the task log.") }
            }
            phase("Creating TAR", nil)
            try require(try await runner.run(executable: "/usr/bin/tar", arguments: tarArgs, directory: inputs.first?.deletingLastPathComponent(), diskGuard: stage, update: update))
            if options.format != .tar {
                phase("Compressing", nil)
                let type = options.format == .tarGzip ? "gzip" : "xz"
                try require(try await runner.run(executable: executable, arguments: ["a", "-t" + type, "-mx=\([0,1,3,5,7,9][options.level])", "-bsp2", "--", staged.path, tar.lastPathComponent], directory: stage, diskGuard: stage, update: update))
            }
            if options.testAfter {
                phase("Verifying", nil)
                try require(try await runner.run(executable: executable, arguments: ArchiveCommands.test(tar, password: "", using: .sevenZip), diskGuard: stage, update: update))
                if options.format != .tar { try require(try await runner.run(executable: executable, arguments: ArchiveCommands.test(staged, password: "", using: .sevenZip), diskGuard: stage, update: update)) }
            }
            try Task.checkCancellation(); phase("Publishing files", nil)
            _ = try ExtractionSafety.copyVerifiedFile(staged, to: output, replacing: false) { done, total in phase("Publishing files", total > 0 ? Double(done) / Double(total) : nil) }
            return output
        }
        var creationOptions = options
        creationOptions.testAfter = false // Verification is a separate visible phase, not a duplicate RAR -t pass.
        let args = try ArchiveCommands.create(output: staged, inputs: inputs, password: password, headers: headers,
                                              volumeMB: volumeMB, recovery: recovery, options: creationOptions)
        func checked(_ result: CLIResult) throws {
            if result.cancelled || Task.isCancelled { throw CancellationError() }
            guard result.status == 0 else { throw ArchiveError.details("Engine exit code {0}. Check stderr/stdout. If the password is wrong, enter it and reload.", [String(result.status)]) }
        }
        phase("Compressing", nil)
        try checked(try await runner.run(executable: executable, arguments: args, directory: inputs.first?.deletingLastPathComponent(), password: password, diskGuard: stage, update: update))
        let generated = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !generated.isEmpty else { throw ArchiveError.invalid("No archive output was produced.") }
        for file in generated {
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true else { throw ArchiveError.invalid("Links and special files cannot be exported.") }
        }
        let first = volumeMB > 0 ? generated.first(where: { options.format == .rar ? $0.pathExtension == "rar" : $0.pathExtension == "001" }) : staged
        guard let first else { throw ArchiveError.invalid("No archive output was produced.") }
        if options.testAfter {
            phase("Verifying", nil)
            try checked(try await runner.run(executable: executable, arguments: ArchiveCommands.test(first, password: password, using: options.format == .rar ? .rar : .sevenZip), password: password, diskGuard: stage, update: update))
        }
        try Task.checkCancellation()
        phase("Publishing files", nil)
        if volumeMB > 0 {
            let folder = parent.appendingPathComponent(output.deletingPathExtension().lastPathComponent + "-parts-" + UUID().uuidString)
            try ExtractionMerger.checkDirectory(parent)
            guard renamex_np(stage.path, folder.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            phase("Publishing files", 1); return folder
        }
        _ = try ExtractionSafety.copyVerifiedFile(staged, to: output, replacing: false) { bytes, total in
            phase("Publishing files", total > 0 ? Double(bytes) / Double(total) : nil)
        }
        return output
    }
}

/// Owns only a freshly allocated temporary directory. Source archives are never changed.
public final class ArchiveSession {
    public let workingURL: URL
    private let temporaryDirectory: URL?
    private init(_ url: URL, temporary: URL? = nil) { workingURL = url; temporaryDirectory = temporary }
    deinit { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }

    public static func prepare(_ source: URL, sevenZip: String, runner: CLIRunner, update: @escaping (String, String) -> Void) async throws -> ArchiveSession {
        let isUUE = ["uue", "uu"].contains(source.pathExtension.lowercased())
        guard isUUE || ArchiveCommands.isCompressedTar(source) else { return ArchiveSession(source) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let tar = root.appendingPathComponent("contents.tar")
            if isUUE {
                let handle = try FileHandle(forReadingFrom: source)
                let header = String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                try handle.close()
                guard let line = header.components(separatedBy: .newlines).first(where: { $0.hasPrefix("begin ") || $0.hasPrefix("begin-base64 ") }) else { throw ArchiveError.invalid("UUE header not found.") }
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3, ArchiveCommands.safePath(String(parts[2])), !parts[2].contains("/"), !parts[2].contains("\\") else { throw ArchiveError.invalid("Unsafe filename in UUE header.") }
                let payload = root.appendingPathComponent("payload", isDirectory: true)
                try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
                let file = payload.appendingPathComponent(String(parts[2]))
                try requireSuccess(try await runner.run(executable: "/usr/bin/uudecode", arguments: ["-o", file.path, source.path], update: update))
                try requireSuccess(try await runner.run(executable: "/usr/bin/tar", arguments: ["-cf", tar.path, "-C", payload.path, "--", String(parts[2])], update: update))
            } else {
                // Decode only the outer stream into a fixed filename, never an archive-supplied path.
                try requireSuccess(try await runner.run(executable: sevenZip, arguments: ["x", "-so", "--", source.path], outputFile: tar, update: update))
            }
            return ArchiveSession(tar, temporary: root)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private static func requireSuccess(_ result: CLIResult) throws {
        if result.cancelled { throw ArchiveError.invalid("Preprocessing cancelled.") }
        guard result.status == 0 else { throw ArchiveError.details("Outer stream decoding failed ({0}): {1}", [String(result.status), result.stderr]) }
    }
}
