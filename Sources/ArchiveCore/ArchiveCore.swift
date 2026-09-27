import Foundation
import Darwin

public struct ArchiveEntry: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let size: String
    public let modified: String
    public let isDirectory: Bool
    public let isLink: Bool
}

public enum ArchiveError: LocalizedError {
    case invalid(String)
    case details(String, [String])
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .details(let key, let values): return values.enumerated().reduce(key) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element) }
        }
    }
}

public enum Backend { case rar, sevenZip }

/// A virtual directory tree; some archives omit explicit directory entries.
public enum ArchiveBrowser {
    public static func children(_ entries: [ArchiveEntry], directory: String, filter: String = "") -> [ArchiveEntry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var rows: [String: ArchiveEntry] = [:]
        for entry in entries where entry.path.hasPrefix(prefix) {
            let tail = String(entry.path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !tail.isEmpty else { continue }
            if !filter.isEmpty {
                if tail.localizedCaseInsensitiveContains(filter) { rows[entry.path] = entry }
            } else if let first = tail.split(separator: "/").first {
                let path = prefix + first
                if tail.contains("/") {
                    if rows[path] == nil { rows[path] = ArchiveEntry(path: path, size: "", modified: "", isDirectory: true, isLink: false) }
                } else { rows[path] = entry }
            }
        }
        return rows.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

public extension ArchiveEntry {
    var name: String { (path as NSString).lastPathComponent }
    var suffix: String { (name as NSString).pathExtension.lowercased() }
    var category: String {
        if isDirectory { return "文件夹" }
        if ArchiveCommands.extensions.contains(suffix) || ["ace", "lz", "lzip", "sit", "sitx", "tbz"].contains(suffix) { return "压缩包" }
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "svg", "ico"].contains(suffix) { return "图片" }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpeg", "mpg", "wmv"].contains(suffix) { return "视频" }
        if ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus"].contains(suffix) { return "音频" }
        if suffix == "pdf" { return "PDF 文档" }
        if ["txt", "md", "log", "csv", "json", "xml", "yaml", "yml", "rtf"].contains(suffix) { return "文本" }
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp"].contains(suffix) { return "办公文档" }
        return "文件"
    }
    var symbol: String {
        switch category {
        case "文件夹": return "folder.fill"
        case "压缩包": return "archivebox.fill"
        case "图片": return "photo.fill"
        case "视频": return "film.fill"
        case "音频": return "music.note"
        case "PDF 文档": return "doc.richtext"
        case "文本": return "doc.text"
        case "办公文档": return "doc.on.doc"
        default: return "doc"
        }
    }
    // Never launch scripts, executable files, app bundles, links or unknown types.
    var canOpenCopy: Bool {
        !isDirectory && !isLink && ["图片", "视频", "音频", "PDF 文档", "文本", "办公文档"].contains(category)
            && ArchiveCommands.safePath(path)
            && !path.split(separator: "/").contains { ["app", "bundle", "framework"].contains(($0.description as NSString).pathExtension.lowercased()) }
    }
}

public enum PreviewSafety {
    public static let maximumBytes = 512 * 1024 * 1024
    public static func validate(_ file: URL, inside root: URL) throws {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw ArchiveError.invalid("无法安全打开此文件。") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes else { throw ArchiveError.invalid("无法安全打开此文件。") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = Array(try handle.read(upToCount: 512) ?? Data())
        let signatures: [[UInt8]] = [[0x52,0x61,0x72,0x21], [0x37,0x7a,0xbc,0xaf,0x27,0x1c], [0x1f,0x8b], [0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xce,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0x7f,0x45,0x4c,0x46], [0x4d,0x5a], [0x23,0x21]]
        guard !signatures.contains(where: { header.starts(with: $0) }) else { throw ArchiveError.invalid("无法安全打开此文件。") }
        // Office Open XML documents are ZIP containers, but are not nested archive navigation.
        let office = ["docx", "xlsx", "pptx", "odt", "ods", "odp", "pages", "numbers", "key"].contains(file.pathExtension.lowercased())
        if !office && (header.starts(with: [0x50,0x4b,0x03,0x04]) || (header.count > 262 && String(bytes: header[257..<262], encoding: .ascii) == "ustar")) {
            throw ArchiveError.invalid("暂不支持打开压缩包内的压缩包。")
        }
    }
}

public enum ArchiveCommands {
    public static let extensions = ["rar", "r00", "zip", "zipx", "z01", "7z", "001", "tar", "iso", "udf", "cab", "arj", "lzh", "lha", "gz", "gzip", "tgz", "tpz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "z", "taz", "zst", "tzst", "jar", "uue", "uu", "dmg", "img", "wim", "swm", "esd", "xar", "pkg", "cpio", "rpm", "deb", "lzma", "epub", "apk", "ova"]
    public static func isCompressedTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.z", ".tar.zst", ".tar.lzma"].contains(where: name.hasSuffix) || ["tgz", "tpz", "tbz", "tbz2", "txz", "taz", "tzst"].contains(url.pathExtension.lowercased())
    }
    public static func backend(_ url: URL) -> Backend { url.pathExtension.lowercased() == "rar" ? .rar : .sevenZip }
    public static func passwordSwitch(_ password: String, headers: Bool = false) throws -> String {
        guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0"), password.unicodeScalars.count <= 127 else { throw ArchiveError.invalid("密码不能含换行、NUL，且不能超过 127 个 Unicode 码点。") }
        return password.isEmpty ? "-p-" : (headers ? "-hp" : "-p")
    }
    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\") && !path.contains(":") && !path.contains("\0") && !path.contains("\n") && !path.contains("\r") && !path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..")
    }
    public static func literalSelection(_ paths: [String]) throws {
        guard paths.allSatisfy({ safePath($0) && !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("@") }) else { throw ArchiveError.invalid("此条目名称含 CLI 模式字符或不安全路径，无法可靠地按选中项解压。") }
    }
    public static func list(_ archive: URL, password: String, using engine: Backend? = nil) throws -> [String] {
        let p = try passwordSwitch(password)
        return (engine ?? backend(archive)) == .rar ? ["lt", "-cfg-", "-idc", p, "--", archive.path] : ["l", "-slt", "-sccUTF-8", "--", archive.path]
    }
    public static func extract(_ archive: URL, destination: URL, selected: [String], password: String, using engine: Backend? = nil) throws -> [String] {
        try literalSelection(selected)
        let p = try passwordSwitch(password)
        if (engine ?? backend(archive)) == .rar { return ["x", "-cfg-", "-o-", "-ol-", "-idc", p, "--", archive.path] + selected + [destination.path + "/"] }
        return ["x", "-aos", "-sccUTF-8", "-o" + destination.path, "--", archive.path] + selected
    }
    public static func test(_ archive: URL, password: String, using engine: Backend? = nil) throws -> [String] {
        let p = try passwordSwitch(password)
        return (engine ?? backend(archive)) == .rar ? ["t", "-cfg-", "-idc", p, "--", archive.path] : ["t", "-sccUTF-8", "--", archive.path]
    }
    public static func create(output: URL, inputs: [URL], password: String, headers: Bool, volumeMB: Int, recovery: Int) throws -> [String] {
        guard !inputs.isEmpty, (0...1_000_000).contains(volumeMB), (0...100).contains(recovery) else { throw ArchiveError.invalid("请选择文件；分卷范围 0–1000000 MB，恢复记录范围 0–100%。") }
        guard !FileManager.default.fileExists(atPath: output.path), output.pathExtension.lowercased() == "rar" else { throw ArchiveError.invalid("请选择尚不存在的 .rar 文件名。") }
        guard inputs.allSatisfy({ !$0.path.contains("\n") && !$0.path.contains("\r") && !$0.lastPathComponent.contains("*") && !$0.lastPathComponent.contains("?") }) else { throw ArchiveError.invalid("源名称含不支持的换行或通配符。") }
        let parents = Set(inputs.map { $0.deletingLastPathComponent().path })
        guard parents.count == 1 else { throw ArchiveError.invalid("此原型要求源文件位于同一文件夹；可直接选择它们的共同父文件夹。") }
        let outputPath = output.resolvingSymlinksInPath().path
        for source in inputs {
            let path = source.resolvingSymlinksInPath().path
            guard !outputPath.hasPrefix(path + "/") else { throw ArchiveError.invalid("输出压缩包不能保存在选中的源文件夹内。") }
        }
        var args = ["a", "-cfg-", "-ma5", "-r", "-idc", try passwordSwitch(password, headers: headers)]
        if volumeMB > 0 { args.append("-v\(volumeMB)m") }
        if recovery > 0 { args.append("-rr\(recovery)p") }
        return args + ["--", output.path] + inputs.map { "./" + $0.lastPathComponent }
    }
    public static func parse(_ text: String, backend: Backend) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = [], fields: [String: String] = [:]
        func flush() {
            let key = backend == .rar ? "Name" : "Path"
            if let path = fields[key], !path.isEmpty, fields["Type"] != "RAR 5", fields["Type"] != "RAR 4", !(backend == .sevenZip && fields["Type"] != nil) {
                entries.append(ArchiveEntry(path: path, size: fields["Size"] ?? "", modified: fields["mtime"] ?? fields["Modified"] ?? "", isDirectory: fields["Type"] == "Directory" || fields["Folder"] == "+" || (fields["Attributes"] ?? "").hasPrefix("D"), isLink: fields.contains(where: { $0.key.lowercased().contains("link") && !$0.value.isEmpty }) || (fields["Type"] ?? "").lowercased().contains("link") || (fields["Mode"] ?? "").hasPrefix("l")))
            }
            fields = [:]
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            let separator = backend == .rar ? ": " : " = "
            if let range = line.range(of: separator) {
                let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if (key == "Name" || key == "Path"), fields[key] != nil { flush() }
                fields[key] = String(line[range.upperBound...])
            }
        }
        flush()
        return entries
    }
}

public struct CLIResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let cancelled: Bool
    fileprivate let listingOutput: String
    public func archiveEntries(backend: Backend) -> [ArchiveEntry] { ArchiveCommands.parse(listingOutput, backend: backend) }
}

/// One job at a time. Pipes are drained concurrently so verbose children cannot deadlock.
public final class CLIRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
    }
    public func run(executable: String, arguments: [String], directory: URL? = nil, password: String = "", outputFile: URL? = nil, update: @escaping (String, String) -> Void) async throws -> CLIResult {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw ArchiveError.details("CLI 路径必须是可执行文件的绝对路径：{0}", [executable]) }
        _ = try ArchiveCommands.passwordSwitch(password)
        lock.withLock { cancelled = false }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let child = Process(), out = Pipe(), err = Pipe(), input = Pipe()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = arguments
                child.currentDirectoryURL = directory
                child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "HOME": NSHomeDirectory()]
                child.standardOutput = out; child.standardError = err; child.standardInput = input
                var binaryOutput: FileHandle?
                if let outputFile {
                    guard FileManager.default.createFile(atPath: outputFile.path, contents: nil, attributes: [.posixPermissions: 0o600]), let handle = try? FileHandle(forWritingTo: outputFile) else { continuation.resume(throwing: ArchiveError.invalid("无法创建临时输出")); return }
                    binaryOutput = handle; child.standardOutput = handle
                }
                defer { try? binaryOutput?.close() }
                self.lock.lock(); self.process = child; self.lock.unlock()
                do { try child.run() } catch {
                    self.lock.lock(); self.process = nil; self.lock.unlock()
                    continuation.resume(throwing: error); return
                }
                self.lock.lock(); let cancelledBeforeLaunch = self.cancelled; self.lock.unlock()
                if cancelledBeforeLaunch { self.cancel() }
                // Password never enters argv, environment, defaults, temporary files or command logs.
                // RAR reads redirected stdin; creation asks for confirmation, so send two lines.
                if !password.isEmpty { try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
                try? input.fileHandleForWriting.close()
                let group = DispatchGroup(), outputLock = NSLock()
                var stdout = Data(), stderr = Data()
                let streams = outputFile == nil ? [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] : [(err.fileHandleForReading, true)]
                for (handle, isError) in streams {
                    group.enter()
                    DispatchQueue.global().async {
                        while true {
                            let data = handle.availableData
                            if data.isEmpty { break }
                            outputLock.lock()
                            if isError { stderr.append(data) } else { stdout.append(data) }
                            // Bound retained output. Truncated listings are refused by the model.
                            if stdout.count > 16_000_000 { self.cancel() }
                            if stderr.count > 2_000_000 { self.cancel() }
                            let a = String(decoding: stdout, as: UTF8.self), b = String(decoding: stderr, as: UTF8.self)
                            // With a secret, withhold live text to avoid split-chunk disclosure.
                            if password.isEmpty { update(a, b) }
                            outputLock.unlock()
                        }
                        group.leave()
                    }
                }
                child.waitUntilExit(); group.wait()
                self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                func redact(_ data: Data) -> String { let s = String(decoding: data, as: UTF8.self); return password.isEmpty ? s : s.replacingOccurrences(of: password, with: "••••") }
                let a = redact(stdout), b = redact(stderr)
                update(a, b)
                continuation.resume(returning: CLIResult(status: child.terminationStatus, stdout: a, stderr: b, cancelled: wasCancelled, listingOutput: String(decoding: stdout, as: UTF8.self)))
            }
        }
    }
}
