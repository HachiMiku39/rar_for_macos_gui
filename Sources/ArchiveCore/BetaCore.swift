import Foundation
import CryptoKit
import Darwin

public enum ZIPNameEncoding: String, CaseIterable {
    case auto = "Auto", utf8 = "UTF-8", cp437 = "CP437", gbk = "GBK", gb18030 = "GB18030", cp932 = "Shift-JIS / CP932", big5 = "Big5", korean = "EUC-KR / CP949"
    case cp850 = "CP850", windows1252 = "Windows-1252", cp866 = "CP866", windows1251 = "Windows-1251"
    public var codePage: Int? {
        switch self { case .auto: return nil; case .utf8: return 65001; case .cp437: return 437; case .gbk: return 936; case .gb18030: return 54936; case .cp932: return 932; case .big5: return 950; case .korean: return 949; case .cp850: return 850; case .windows1252: return 1252; case .cp866: return 866; case .windows1251: return 1251 }
    }
    public func switches(for url: URL) -> [String] {
        guard ["zip", "zipx", "z01", "jar", "epub", "ipa", "apk"].contains(url.pathExtension.lowercased()),
              let codePage = resolved(for: url).codePage else { return [] }
        return ["-mcp=\(codePage)"]
    }
    public func resolved(for url: URL) -> Self {
        guard self == .auto else { return self }
        return ZIPFilenameProbe.detect(url) ?? .auto
    }
}

/// Metadata-only probe. Complex, split, ZIP64 or oversized indexes stay on the original
/// backend and can use an explicit override. Never read the payload or scan an entire ISO.
enum ZIPFilenameProbe {
    static func detect(_ url: URL) -> ZIPNameEncoding? {
        guard url.isFileURL, ["zip", "zipx", "jar", "epub", "ipa", "apk"].contains(url.pathExtension.lowercased()) else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 22 else { return nil }
        do {
            let length = UInt64(info.st_size), tailSize = min(Int(length), 65_557)
            try file.seek(toOffset: length - UInt64(tailSize))
            let tail = Array(try file.read(upToCount: tailSize) ?? Data())
            guard tail.count == tailSize else { return nil }
            func u16(_ bytes: [UInt8], _ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
            func u32(_ bytes: [UInt8], _ i: Int) -> Int { u16(bytes, i) | u16(bytes, i+2) << 16 }
            guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                tail[$0..<$0+4].elementsEqual([0x50,0x4b,5,6]) && $0 + 22 + u16(tail, $0+20) == tail.count
            }), u16(tail, end+4) == 0, u16(tail, end+6) == 0,
                  u16(tail, end+8) == u16(tail, end+10) else { return nil }
            let count = u16(tail, end+10), size = u32(tail, end+12), offset = u32(tail, end+16)
            guard count > 0, count <= 16_384, size <= 1_048_576, offset != 0xffff_ffff,
                  UInt64(offset) + UInt64(size) <= length - UInt64(tail.count - end) else { return nil }
            try file.seek(toOffset: UInt64(offset))
            let central = Array(try file.read(upToCount: size) ?? Data())
            guard central.count == size else { return nil }
            var cursor = 0, sample = Data(), hasUnicodeExtra = false
            for _ in 0..<count {
                guard cursor + 46 <= central.count, central[cursor..<cursor+4].elementsEqual([0x50,0x4b,1,2]),
                      u16(central, cursor+34) == 0 else { return nil }
                let flags = u16(central, cursor+8), n = u16(central, cursor+28)
                let x = u16(central, cursor+30), comment = u16(central, cursor+32)
                let next = cursor + 46 + n + x + comment
                guard n > 0, next <= central.count else { return nil }
                let name = Data(central[cursor+46..<cursor+46+n])
                var field = cursor + 46 + n
                let fieldEnd = field + x
                while field + 4 <= fieldEnd {
                    let tag = u16(central, field), fieldSize = u16(central, field+2)
                    guard field + 4 + fieldSize <= fieldEnd else { return nil }
                    if tag == 0x7075 { hasUnicodeExtra = true }
                    field += 4 + fieldSize
                }
                guard field == fieldEnd else { return nil }
                if flags & 0x800 == 0, name.contains(where: { $0 >= 0x80 }) {
                    guard sample.count + n + 1 <= 65_536 else { return nil }
                    sample.append(name); sample.append(10)
                }
                cursor = next
            }
            // Keep Unicode-extra archives on 7-Zip: the system libarchive can expose
            // different names during header-only listing and payload extraction.
            guard cursor == central.count, !sample.isEmpty, !hasUnicodeExtra else { return nil }
            if String(data: sample, encoding: .utf8) != nil { return .utf8 }
            if let guessed = PreviewTextEncoding.detectLegacy(sample), let page = guessed.codePage,
               let match = ZIPNameEncoding.allCases.first(where: { $0.codePage == Int(page) }) { return match }
            return .cp437
        } catch { return nil }
    }
}

public enum VolumeSize {
    public static func mebibytes(_ text: String, gibibytes: Bool) throws -> Int {
        guard text.count <= 20, text.range(of: "\\A[0-9]+(?:\\.[0-9]+)?\\z", options: .regularExpression) != nil,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), number > 0 else { throw ArchiveError.invalid("Volume size must be positive and at most 4 GiB.") }
        let value = number * (gibibytes ? 1024 : 1)
        let integer = NSDecimalNumber(decimal: value).intValue
        guard value == Decimal(integer), (1...4096).contains(integer) else { throw ArchiveError.invalid("Volume size must be positive and at most 4 GiB.") }
        return integer
    }
}

public enum ChecksumAlgorithm: String, CaseIterable { case sha256 = "SHA-256", md5 = "MD5" }
public struct ChecksumRecord {
    public let path: String
    public let expected: String
    public let algorithm: ChecksumAlgorithm
}
public enum FileChecksums {
    public static func digest(_ url: URL, algorithm: ChecksumAlgorithm, progress: (UInt64, UInt64) -> Void = { _, _ in }) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw ArchiveError.invalid("Choose a regular file, not a link or device.") }
        var sha = SHA256(), md5 = Insecure.MD5(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var done: UInt64 = 0, last = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.EIO) }
            if count == 0 { break }
            let data = Data(buffer.prefix(count))
            if algorithm == .sha256 { sha.update(data: data) } else { md5.update(data: data) }
            done += UInt64(count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - last >= 0.2 { progress(done, UInt64(before.st_size)); last = now }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, done == UInt64(before.st_size), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ArchiveError.invalid("File changed during checksum calculation. Try again.") }
        try Task.checkCancellation(); progress(done, UInt64(before.st_size))
        return (algorithm == .sha256 ? Array(sha.finalize()) : Array(md5.finalize())).map { String(format: "%02x", $0) }.joined()
    }
    public static func normalized(_ text: String, algorithm: ChecksumAlgorithm) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == (algorithm == .sha256 ? 64 : 32), value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    /// GNU shasum/md5sum format only. No shell expansion, escaped filenames or absolute paths.
    public static func manifest(_ data: Data) throws -> [ChecksumRecord] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw ArchiveError.invalid("Checksum list must be UTF-8 and at most 1 MiB.") }
        var records: [ChecksumRecord] = [], names = Set<String>()
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            guard let space = line.firstIndex(of: " ") else { throw ArchiveError.invalid("Expected GNU checksum format: hash, two spaces, relative filename.") }
            let hash = String(line[..<space]), tail = line[line.index(after: space)...]
            guard tail.first == " " || tail.first == "*" else { throw ArchiveError.invalid("Expected GNU checksum format: hash, two spaces, relative filename.") }
            let path = String(tail.dropFirst()), algorithm: ChecksumAlgorithm = hash.count == 32 ? .md5 : .sha256
            guard let normalized = normalized(hash, algorithm: algorithm), ArchiveCommands.safePath(path), !path.contains("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." }),
                  path.utf8.count < 4096, names.insert(path.decomposedStringWithCanonicalMapping.lowercased()).inserted, records.count < 10_000 else {
                throw ArchiveError.invalid("Invalid, duplicate or unsafe checksum-list entry.")
            }
            records.append(.init(path: path, expected: normalized, algorithm: algorithm))
        }
        guard !records.isEmpty else { throw ArchiveError.invalid("Checksum list is empty.") }; return records
    }
    public static func target(_ record: ChecksumRecord, root: URL) throws -> URL {
        try ExtractionMerger.checkDirectory(root)
        let result = root.appendingPathComponent(record.path).standardizedFileURL
        guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ArchiveError.invalid("Unsafe checksum path.") }
        try ExtractionMerger.checkDirectory(result.deletingLastPathComponent())
        return result
    }
}

public struct BatchArchive: Identifiable {
    public let id = UUID()
    public let source: URL
    public var state = "queued"
    public var detail = ""
    public var destination: URL?
    public init(source: URL) { self.source = source }
}
public enum BatchArchives {
    public static func folderName(_ source: URL) -> String {
        let name = source.lastPathComponent
        var base = source.deletingPathExtension().lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where name.lowercased().hasSuffix(suffix) { base = String(name.dropLast(suffix.count)); break }
        return base.isEmpty || base == "." || base == ".." ? "Archive" : base
    }
    public static func execute(_ jobs: [BatchArchive], process: (BatchArchive) async throws -> URL,
                               update: (BatchArchive) async -> Void) async -> [BatchArchive] {
        var results: [BatchArchive] = []
        for var job in jobs {
            if Task.isCancelled { job.state = "cancelled"; results.append(job); await update(job); continue }
            job.state = "running"; await update(job)
            do { job.destination = try await process(job); job.state = "completed" }
            catch is CancellationError { job.state = "cancelled" }
            catch { job.state = "failed"; job.detail = error.localizedDescription }
            results.append(job); await update(job)
        }
        return results
    }
}

/// Shared safe extraction path for the batch queue. Encoding is identical for listing and extraction.
public enum BatchExtractor {
    public static func extract(_ source: URL, parent: URL, engine: String, runner: CLIRunner, password: String,
                               encoding: ZIPNameEncoding, policy: ExtractionPolicy,
                               conflict: @escaping (String) async -> ConflictChoice,
                               update: @escaping (String, String) -> Void,
                               progress: @escaping (ExtractionReport) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try ExtractionMerger.checkDirectory(parent)
        let destination = parent.appendingPathComponent(BatchArchives.folderName(source), isDirectory: true)
        // An archive already inside its own output folder must not overwrite its input.
        guard !source.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else { throw ArchiveError.invalid("Source archive is inside the extraction destination.") }
        if !fm.fileExists(atPath: destination.path) { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
        try ExtractionMerger.checkDirectory(destination)
        let stage = fm.temporaryDirectory.appendingPathComponent("ArchiveDesk-batch-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let session = try await ArchiveSession.prepare(source, sevenZip: engine, runner: runner, update: update)
        let archive = session.workingURL
        let listed = try await runner.run(executable: engine, arguments: ArchiveCommands.list(archive, password: password, using: .sevenZip, encoding: encoding), password: password, update: update)
        if listed.cancelled { throw CancellationError() }
        guard listed.status == 0 else { throw ArchiveError.invalid("Reading the archive failed. Check the task log.") }
        let rows = listed.archiveEntries(backend: .sevenZip)
        if [.ipa, .apk].contains(PackageInspector.kind(archive: source, entries: rows)) {
            _ = try await PackageExporter.extract(archive: source, destination: stage, selected: [], sevenZip: engine, password: password, runner: runner, update: update)
        } else {
            let size = UInt64(max(0, (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            let bytes = try ExtractionSafety.validate(rows, compressedBytes: size)
            try DiskSpace.requireStaging(bytes, stage: stage, destination: destination)
            let result = try await runner.run(executable: engine, arguments: ArchiveCommands.extract(archive, destination: stage, selected: [], password: password, using: .sevenZip, encoding: encoding), password: password, diskGuard: stage, update: update)
            if result.cancelled { throw CancellationError() }
            guard result.status == 0 else { throw ArchiveError.invalid("Extraction failed. The destination was not changed.") }
        }
        try Task.checkCancellation()
        _ = try await ExtractionMerger.merge(from: stage, to: destination, policy: policy, conflict: conflict, update: progress)
        return destination
    }
}

public enum FileExportPasswordError: LocalizedError, Equatable {
    case required, incorrect
    public var errorDescription: String? {
        switch self {
        case .required: return "Password required"
        case .incorrect: return "Incorrect password. Try again."
        }
    }
    static func isPasswordFailure(_ result: CLIResult) -> Bool {
        guard result.status != 0, !result.cancelled else { return false }
        // 7zz writes progress/backspaces immediately before ERROR without a newline.
        let diagnostic = result.stderr.lowercased()
        return diagnostic.contains("error: wrong password") ||
            diagnostic.contains("error: data error in encrypted file. wrong password") ||
            diagnostic.contains("error: password is incorrect")
    }
}

public enum SingleFileExporter {
    public static func export(_ item: ArchiveEntry, entries: [ArchiveEntry], source: URL, root: URL, engine: String,
                              password: String, encoding: ZIPNameEncoding, runner: CLIRunner,
                              update: @escaping (String, String) -> Void) async throws -> URL {
        _ = try ExtractionSafety.validate(entries)
        try ArchiveCommands.literalSelection([item.path])
        guard !item.isDirectory, !item.isLink, let size = UInt64(item.size), size <= PreviewSafety.maximumBytes else { throw ArchiveError.invalid("Drag export and Quick Look support regular files up to 512 MiB.") }
        guard !item.isEncrypted || !password.isEmpty else { throw FileExportPasswordError.required }
        try DiskSpace.require(size, at: root)
        let target = root.appendingPathComponent(item.name)
        let args = ["x", "-so", "-spd", "-bsp2"] + encoding.switches(for: source) + ArchiveCommands.resourceSwitches(source) + ["--", source.path, item.path]
        let result = try await runner.run(executable: engine, arguments: args, password: password, outputFile: target, outputLimit: Int(size), diskGuard: root, update: update)
        if result.cancelled { throw CancellationError() }
        if FileExportPasswordError.isPasswordFailure(result) { throw FileExportPasswordError.incorrect }
        guard result.status == 0, (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(size) else { throw ArchiveError.invalid("File export failed. Check the task log.") }
        return target
    }
}
