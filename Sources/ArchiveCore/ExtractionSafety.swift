import Foundation
import Darwin

/// General archives are not subject to mobile-inspector byte limits.
public enum ExtractionSafety {
    public static func validate(_ entries: [ArchiveEntry], compressedBytes: UInt64 = 0) throws -> UInt64 {
        guard entries.count <= ArchiveResources.shared.budget.entryLimit else { throw ArchiveError.invalid("Archive entry index exceeds the current memory budget.") }
        var names = Set<String>(), files = Set<String>(), total: UInt64 = 0
        for item in entries {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard ArchiveCommands.safePath(item.path), !item.path.contains("\\"), !item.isLink,
                  !parts.contains("."), !parts.dropLast().contains(""), parts.count <= 128,
                  item.path.utf8.count < 4096, parts.allSatisfy({ $0.utf8.count <= 255 }) else {
                throw ArchiveError.details("Unsafe archive path: {0}", [item.path])
            }
            let key = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).decomposedStringWithCanonicalMapping.lowercased()
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
    public static func copyVerifiedFile(_ source: URL, to target: URL, replacing: Bool) throws -> Bool {
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
        return backup != nil
    }
}
