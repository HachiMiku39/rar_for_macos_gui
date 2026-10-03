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

public enum CreationFormat: String, Codable, CaseIterable {
    case rar, zip, sevenZip = "7z"
    public var title: String { self == .rar ? "RAR5" : rawValue.uppercased() }
}

public struct CreationOptions: Codable, Equatable {
    public var format: CreationFormat = .rar
    public var level = 3
    public var dictionaryMB = 32
    public var solid = false
    public var testAfter = true
    public var threads = 0
    public var blake2 = false
    public var quickOpen = 0 // 0 automatic, 1 none, 2 all
    public var storeCompressed = false
    public var modifiedTime = true
    public var accessTime = false
    public var highPrecision = true
    public var exclusions = ""
    public init() {}
    public func validatedPatterns() throws -> [String] {
        let patterns = exclusions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (0...5).contains(level), [4,8,16,32,64,128,256].contains(dictionaryMB),
              (0...64).contains(threads), (0...2).contains(quickOpen), patterns.count <= 50,
              patterns.allSatisfy({ $0.count <= 256 && ArchiveCommands.safePath($0) && !$0.hasPrefix("@") && !$0.hasPrefix("-") && !$0.contains("\t") }) else {
            throw ArchiveError.invalid("Invalid options. Use one exclude pattern per line, without absolute paths, .. or @ list files.")
        }
        return patterns
    }
    public func rarSwitches() throws -> [String] {
        let patterns = try validatedPatterns()
        var result = ["-m\(level)", "-md\(dictionaryMB)m", solid ? "-s" : "-s-",
                      blake2 ? "-htb" : "-htc", quickOpen == 1 ? "-qo-" : quickOpen == 2 ? "-qo+" : "-qo",
                      modifiedTime ? (highPrecision ? "-tsm+" : "-tsm1") : "-tsm-",
                      accessTime ? (highPrecision ? "-tsa+" : "-tsa1") : "-tsa-", "-tsc-"]
        if threads > 0 { result.append("-mt\(threads)") }
        if testAfter { result.append("-t") }
        if storeCompressed { result.append("-ms") }
        result += patterns.map { "-x" + $0 }
        return result
    }
}

/// A virtual directory tree; some archives omit explicit directory entries.
public enum ArchiveBrowser {
    public static func children(_ entries: [ArchiveEntry], directory: String, filter: String = "") -> [ArchiveEntry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var rows: [String: ArchiveEntry] = [:]
        for entry in entries where entry.path.hasPrefix(prefix) {
            if Task.isCancelled { return [] }
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
        if isDirectory { return "Folder" }
        if ArchiveCommands.extensions.contains(suffix) || ["ace", "lz", "lzip", "sit", "sitx", "tbz"].contains(suffix) { return "Archive" }
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "svg", "ico"].contains(suffix) { return "Image" }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpeg", "mpg", "wmv"].contains(suffix) { return "Video" }
        if ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus"].contains(suffix) { return "Audio" }
        if suffix == "pdf" { return "PDF document" }
        if ["txt", "md", "log", "csv", "json", "xml", "yaml", "yml", "rtf"].contains(suffix) { return "Text" }
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp"].contains(suffix) { return "Office document" }
        return "File"
    }
    var symbol: String {
        if suffix == "ipa" { return "iphone" }
        if suffix == "apk" { return "apps.iphone" }
        switch category {
        case "Folder": return "folder.fill"
        case "Archive": return "archivebox.fill"
        case "Image": return "photo.fill"
        case "Video": return "film.fill"
        case "Audio": return "music.note"
        case "PDF document": return "doc.richtext"
        case "Text": return "doc.text"
        case "Office document": return "doc.on.doc"
        default: return "doc"
        }
    }
    // Never launch scripts, executable files, app bundles, links or unknown types.
    var canOpenCopy: Bool {
        !isDirectory && !isLink && ["Image", "Video", "Audio", "PDF document", "Text", "Office document"].contains(category)
            && ArchiveCommands.safePath(path)
            && !path.split(separator: "/").contains { ["app", "bundle", "framework"].contains(($0.description as NSString).pathExtension.lowercased()) }
    }
}

public enum PreviewSafety {
    public static let maximumBytes = 512 * 1024 * 1024
    public static func validate(_ file: URL, inside root: URL) throws {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = Array(try handle.read(upToCount: 512) ?? Data())
        let signatures: [[UInt8]] = [[0x52,0x61,0x72,0x21], [0x37,0x7a,0xbc,0xaf,0x27,0x1c], [0x1f,0x8b], [0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xce,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0x7f,0x45,0x4c,0x46], [0x4d,0x5a], [0x23,0x21]]
        guard !signatures.contains(where: { header.starts(with: $0) }) else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        // Office Open XML documents are ZIP containers, but are not nested archive navigation.
        let office = ["docx", "xlsx", "pptx", "odt", "ods", "odp", "pages", "numbers", "key"].contains(file.pathExtension.lowercased())
        if !office && (header.starts(with: [0x50,0x4b,0x03,0x04]) || (header.count > 262 && String(bytes: header[257..<262], encoding: .ascii) == "ustar")) {
            throw ArchiveError.invalid("Opening nested archives is not supported yet.")
        }
    }
}

public enum ArchiveCommands {
    public static func resourceSwitches(_ archive: URL) -> [String] {
        let budget = ArchiveResources.shared.budget
        return ["-mmt=\(budget.workers)"] + (archive.pathExtension.lowercased() == "7z" ? ["-mmemuse=\(budget.memory / (1024 * 1024))m"] : [])
    }
    public static let extensions = ["rar", "r00", "zip", "zipx", "z01", "7z", "001", "tar", "iso", "udf", "cab", "arj", "lzh", "lha", "gz", "gzip", "tgz", "tpz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "z", "taz", "zst", "tzst", "jar", "uue", "uu", "dmg", "img", "wim", "swm", "esd", "xar", "pkg", "cpio", "rpm", "deb", "lzma", "epub", "apk", "ipa", "ova"]
    public static func isCompressedTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.z", ".tar.zst", ".tar.lzma"].contains(where: name.hasSuffix) || ["tgz", "tpz", "tbz", "tbz2", "txz", "taz", "tzst"].contains(url.pathExtension.lowercased())
    }
    public static func backend(_ url: URL) -> Backend { url.pathExtension.lowercased() == "rar" ? .rar : .sevenZip }
    public static func passwordSwitch(_ password: String, headers: Bool = false) throws -> String {
        guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0"), password.unicodeScalars.count <= 127 else { throw ArchiveError.invalid("Passwords cannot contain newlines or NUL and must not exceed 127 Unicode code points.") }
        return password.isEmpty ? "-p-" : (headers ? "-hp" : "-p")
    }
    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\") && !path.contains(":") && !path.contains("\0") && !path.contains("\n") && !path.contains("\r") && !path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..")
    }
    public static func literalSelection(_ paths: [String]) throws {
        guard paths.allSatisfy({ safePath($0) && !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("@") }) else { throw ArchiveError.invalid("This item contains wildcard characters or an unsafe path and cannot be safely extracted by selection.") }
    }
    public static func list(_ archive: URL, password: String, using engine: Backend? = nil) throws -> [String] {
        let p = try passwordSwitch(password)
        return (engine ?? backend(archive)) == .rar ? ["lt", "-cfg-", "-idc", p, "--", archive.path] : ["l", "-slt", "-sccUTF-8", "--", archive.path]
    }
    public static func extract(_ archive: URL, destination: URL, selected: [String], password: String, using engine: Backend? = nil) throws -> [String] {
        try literalSelection(selected)
        let p = try passwordSwitch(password)
        if (engine ?? backend(archive)) == .rar { return ["x", "-cfg-", "-o-", "-ol-", "-idc", p, "--", archive.path] + selected + [destination.path + "/"] }
        return ["x", "-aos", "-sccUTF-8", "-o" + destination.path] + resourceSwitches(archive) + ["--", archive.path] + selected
    }
    public static func test(_ archive: URL, password: String, using engine: Backend? = nil) throws -> [String] {
        let p = try passwordSwitch(password)
        return (engine ?? backend(archive)) == .rar ? ["t", "-cfg-", "-idc", p, "--", archive.path] : ["t", "-sccUTF-8"] + resourceSwitches(archive) + ["--", archive.path]
    }
    public static func create(output: URL, inputs: [URL], password: String, headers: Bool, volumeMB: Int, recovery: Int, options: CreationOptions = CreationOptions()) throws -> [String] {
        guard !inputs.isEmpty, (0...1_000_000).contains(volumeMB), (0...100).contains(recovery) else { throw ArchiveError.invalid("Select files; volume size must be 0–1000000 MB and recovery record 0–100%.") }
        guard !FileManager.default.fileExists(atPath: output.path), output.pathExtension.lowercased() == options.format.rawValue else { throw ArchiveError.invalid("Choose a new filename with the correct extension for the selected format.") }
        guard inputs.allSatisfy({ !$0.path.contains("\n") && !$0.path.contains("\r") && !$0.lastPathComponent.contains("*") && !$0.lastPathComponent.contains("?") }) else { throw ArchiveError.invalid("Source names contain unsupported newlines or wildcards.") }
        let parents = Set(inputs.map { $0.deletingLastPathComponent().path })
        guard parents.count == 1 else { throw ArchiveError.invalid("Source items must share one parent folder. You may select their common parent folder instead.") }
        let outputPath = output.resolvingSymlinksInPath().path
        for source in inputs {
            let path = source.resolvingSymlinksInPath().path
            guard !outputPath.hasPrefix(path + "/") else { throw ArchiveError.invalid("The output archive cannot be inside a selected source folder.") }
        }
        let patterns = try options.validatedPatterns()
        _ = try passwordSwitch(password)
        if options.format != .rar {
            var args = ["a", "-t" + options.format.rawValue, "-mx=\([0,1,3,5,7,9][options.level])", "-sccUTF-8"]
            if !password.isEmpty {
                args.append("-p")
                if options.format == .zip { args.append("-mem=AES256") }
                else if headers { args.append("-mhe=on") }
            }
            if options.format == .sevenZip { args.append(options.solid ? "-ms=on" : "-ms=off") }
            if options.threads > 0 { args.append("-mmt=\(options.threads)") }
            if volumeMB > 0 { args.append("-v\(volumeMB)m") }
            args += patterns.map { "-xr!" + $0 }
            return args + ["--", output.path] + inputs.map { "./" + $0.lastPathComponent }
        }
        // During creation RAR interprets -p- as the literal password "-".
        // An unencrypted archive must omit the password switch entirely.
        var args = ["a", "-cfg-", "-ma5", "-r", "-idc"] + (password.isEmpty ? [] : [try passwordSwitch(password, headers: headers)]) + (try options.rarSwitches())
        if volumeMB > 0 { args.append("-v\(volumeMB)m") }
        if recovery > 0 { args.append("-rr\(recovery)p") }
        return args + ["--", output.path] + inputs.map { "./" + $0.lastPathComponent }
    }
    public static func parse(_ text: String, backend: Backend) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = [], fields: [String: String] = [:]
        func flush() {
            let key = backend == .rar ? "Name" : "Path"
            if let path = fields[key], !path.isEmpty, fields["Type"] != "RAR 5", fields["Type"] != "RAR 4", !(backend == .sevenZip && fields["Type"] != nil) {
                entries.append(ArchiveEntry(path: path, size: fields["Size"] ?? "", modified: fields["mtime"] ?? fields["Modified"] ?? "", isDirectory: fields["Type"] == "Directory" || fields["Folder"] == "+" || (fields["Attributes"] ?? "").hasPrefix("D"), isLink: fields.contains(where: { $0.key.lowercased().contains("link") && !$0.value.isEmpty }) || (fields["Type"] ?? "").lowercased().contains("link") || (fields["Mode"] ?? "").hasPrefix("l") || (fields["Attributes"] ?? "").split(separator: " ").contains(where: { $0.count == 10 && $0.hasPrefix("l") })))
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
    let listingOutput: String
    var parsedEntries: [ArchiveEntry]? = nil
    public func archiveEntries(backend: Backend) -> [ArchiveEntry] { parsedEntries ?? ArchiveCommands.parse(listingOutput, backend: backend) }
}
