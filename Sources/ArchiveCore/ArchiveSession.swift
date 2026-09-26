import Foundation

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
                guard let line = header.components(separatedBy: .newlines).first(where: { $0.hasPrefix("begin ") || $0.hasPrefix("begin-base64 ") }) else { throw ArchiveError.invalid("找不到 UUE 文件头。") }
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3, ArchiveCommands.safePath(String(parts[2])), !parts[2].contains("/"), !parts[2].contains("\\") else { throw ArchiveError.invalid("UUE 内的文件名不安全。") }
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
        if result.cancelled { throw ArchiveError.invalid("已取消预处理。") }
        guard result.status == 0 else { throw ArchiveError.details("解码外层失败（{0}）：{1}", [String(result.status), result.stderr]) }
    }
}
