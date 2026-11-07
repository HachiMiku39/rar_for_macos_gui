import Foundation
import Darwin

/// Stage on the user-selected destination volume, never on the startup disk by default.
/// A private sibling keeps decoded files invisible until validation and merge finish.
public enum ExtractionStaging {
    public static func create(in parent: URL) throws -> URL {
        try ExtractionMerger.checkDirectory(parent)
        let stage = parent.appendingPathComponent(".ArchiveDesk-extract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
}

/// Explicit opt-out of staging. Conflicts are decided before any output changes.
/// Replaced originals are renamed to backups on the destination volume.
/// Failed decodes deliberately retain their outputs and report that they may be incomplete.
public enum DirectExtractor {
    public static func extract(_ archive: URL, entries: [ArchiveEntry], destination: URL, selected: [String], engine: String, password: String, encoding: ZIPNameEncoding, runner: CLIRunner, update: @escaping (String, String) -> Void, conflict: (String) async -> ConflictChoice = { _ in .skip }) async throws -> ExtractionReport {
        _ = try ExtractionSafety.validate(entries)
        try ExtractionMerger.checkDirectory(destination)
        let rows = selected.isEmpty ? entries : entries.filter { row in selected.contains { row.path == $0 || row.path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") } }
        guard !rows.isEmpty else { throw ArchiveError.invalid("No matching archive entries.") }
        let bytes = try ExtractionSafety.validate(rows)
        try DiskSpace.require(bytes, at: destination)
        let fm = FileManager.default
        var skipped = Set<String>()
        var replacements: [(URL, stat)] = []
        var replaceAll = false
        for row in rows {
            let target = destination.appendingPathComponent(row.path)
            guard target.standardizedFileURL != archive.standardizedFileURL else { throw ArchiveError.invalid("The source archive cannot be replaced during direct extraction.") }
            var parent = target.deletingLastPathComponent()
            while parent.path.count >= destination.path.count {
                var info = stat()
                if lstat(parent.path, &info) == 0 { try ExtractionMerger.checkDirectory(parent); break }
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                parent.deleteLastPathComponent()
            }
            if let attrs = try? fm.attributesOfItem(atPath: target.path) {
                let type = attrs[.type] as? FileAttributeType
                guard type == (row.isDirectory ? .typeDirectory : .typeRegular), row.isDirectory || (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw ArchiveError.invalid("Links and special files cannot be exported.") }
                if !row.isDirectory {
                    let choice = replaceAll ? ConflictChoice.replace : await conflict(row.path)
                    try Task.checkCancellation()
                    switch choice {
                    case .skip: skipped.insert(row.path)
                    case .cancel: throw CancellationError()
                    case .rename: throw ArchiveError.invalid("Rename incoming files requires extraction staging.")
                    case .replace, .replaceAll:
                        if case .replaceAll = choice { replaceAll = true }
                        var original = stat()
                        guard lstat(target.path, &original) == 0, (original.st_mode & S_IFMT) == S_IFREG, original.st_nlink == 1 else { throw ArchiveError.invalid("Links and special files cannot be exported.") }
                        replacements.append((target, original))
                    }
                }
            }
        }
        try Task.checkCancellation()
        // Do not unlink originals: same-volume backups cost no second data copy.
        // If decoding fails they remain available beside any incomplete output.
        for (target, original) in replacements {
            try Task.checkCancellation()
            try ExtractionMerger.checkDirectory(target.deletingLastPathComponent())
            var current = stat()
            guard lstat(target.path, &current) == 0, current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  current.st_nlink == 1, (current.st_mode & S_IFMT) == S_IFREG,
                  current.st_size == original.st_size, current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw ArchiveError.invalid("The destination changed while awaiting a conflict decision.") }
            let backup = target.deletingLastPathComponent().appendingPathComponent("ArchiveDesk-backup-" + UUID().uuidString)
            guard renamex_np(target.path, backup.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let result = try await runner.run(executable: engine, arguments: ArchiveCommands.extract(archive, destination: destination, selected: selected, password: password, using: .sevenZip, encoding: encoding), password: password, diskGuard: destination, update: update)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard result.status == 0 else { throw ArchiveError.invalid("Direct extraction failed. Incomplete files may remain in the destination. Check the task log.") }
        var report = ExtractionReport(); report.totalBytes = bytes; report.backups = replacements.count
        for row in rows where !row.isDirectory {
            if skipped.contains(row.path) { report.skipped += 1; report.processedBytes += UInt64(row.size) ?? 0; continue }
            let attrs = try fm.attributesOfItem(atPath: destination.appendingPathComponent(row.path).path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.referenceCount] as? NSNumber)?.intValue == 1, (attrs[.size] as? NSNumber)?.uint64Value == UInt64(row.size) else { throw ArchiveError.invalid("Direct extraction failed. Incomplete files may remain in the destination. Check the task log.") }
            if let mode = attrs[.posixPermissions] as? NSNumber {
                try fm.setAttributes([.posixPermissions: mode.intValue & 0o777], ofItemAtPath: destination.appendingPathComponent(row.path).path)
            }
            report.written += 1; report.processedBytes += UInt64(row.size) ?? 0
        }
        return report
    }
}

/// General archives are not subject to mobile-inspector byte limits.
public enum ExtractionSafety {
    public static func validate(_ entries: [ArchiveEntry], compressedBytes: UInt64 = 0) throws -> UInt64 {
        guard entries.count <= ArchiveResources.shared.budget.entryLimit else { throw ArchiveError.invalid("Archive entry index exceeds the current memory budget.") }
        var names = Set<String>(), files = Set<String>(), total: UInt64 = 0
        var components: [String: Data] = [:]
        for item in entries {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard ArchiveCommands.safePath(item.path), !item.path.contains("\\"), !item.isLink,
                  !parts.contains("."), !parts.dropLast().contains(""), parts.count <= 128,
                  item.path.utf8.count < 4096, parts.allSatisfy({ $0.utf8.count <= 255 }) else {
                throw ArchiveError.details("Unsafe archive path: {0}", [item.path])
            }
            let key = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).decomposedStringWithCanonicalMapping.lowercased()
            var prefix = ""
            for part in parts where !part.isEmpty {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                let normalized = prefix.decomposedStringWithCanonicalMapping.lowercased(), raw = Data(prefix.utf8)
                if let previous = components[normalized], previous != raw {
                    throw ArchiveError.invalid("Case or Unicode filename collision. Extraction was refused to avoid overwriting files.")
                }
                components[normalized] = raw
            }
            guard names.insert(key).inserted else { throw ArchiveError.invalid("Case or Unicode filename collision. Extraction was refused to avoid overwriting files.") }
            if !item.isDirectory {
                guard let size = UInt64(item.size), size <= UInt64(Int64.max), total <= UInt64(Int64.max) - size else { throw ArchiveError.invalid("Invalid uncompressed size.") }
                total += size; files.insert(key)
            }
        }
        for name in names {
            var path = (name as NSString).deletingLastPathComponent
            while !path.isEmpty {
                guard !files.contains(path) else { throw ArchiveError.invalid("A file conflicts with an archive directory.") }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        if compressedBytes > 0 && total > 10 * 1024 * 1024 * 1024 && total / compressedBytes > 10_000 {
            throw ArchiveError.invalid("Compression ratio is unusually high. This archive may be a decompression bomb.")
        }
        return total
    }

    /// Copy into a private sibling and publish only after the whole file is durable.
    /// The source was already verified by the decoder before merging starts.
    public static func copyVerifiedFile(_ source: URL, to target: URL, replacing: Bool, progress: (UInt64, UInt64) -> Void = { _, _ in }) throws -> Bool {
        let fm = FileManager.default
        try ExtractionMerger.checkDirectory(target.deletingLastPathComponent())
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw ArchiveError.invalid("Links and special files cannot be exported.") }
        try DiskSpace.require(UInt64(info.st_size), at: target.deletingLastPathComponent())
        let partial = target.deletingLastPathComponent().appendingPathComponent(".ArchiveDesk-" + UUID().uuidString + ".partial")
        let output = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output); try? fm.removeItem(at: partial) }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024), copied: Int64 = 0, untilCheck = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
            copied += Int64(count); untilCheck += count
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.2 { progress(UInt64(copied), UInt64(info.st_size)); lastProgress = now }
            if untilCheck >= 16 * 1024 * 1024 {
                try DiskSpace.require(0, at: target.deletingLastPathComponent()); untilCheck = 0
            }
        }
        guard copied == info.st_size else { throw ArchiveError.invalid("Extracted file size changed before publishing.") }
        // Strip setuid/setgid/sticky; retain ordinary Unix rwx, including executable bits.
        guard fchmod(output, info.st_mode & 0o777) == 0 else { throw POSIXError(.EIO) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(output, &times) == 0, fsync(output) == 0 else { throw POSIXError(.EIO) }
        try Task.checkCancellation()
        try ExtractionMerger.checkDirectory(target.deletingLastPathComponent())
        var backup: URL?
        if replacing {
            let saved = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".ArchiveDesk-backup-" + UUID().uuidString)
            try fm.moveItem(at: target, to: saved); backup = saved
        }
        // Exclusive publication never follows an existing symlink or overwrites a race winner.
        if Darwin.link(partial.path, target.path) != 0 {
            if let backup, !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: backup, to: target) }
            throw ArchiveError.invalid("Cannot publish output; destination exists or is unavailable.")
        }
        progress(UInt64(copied), UInt64(info.st_size))
        return backup != nil
    }
}
