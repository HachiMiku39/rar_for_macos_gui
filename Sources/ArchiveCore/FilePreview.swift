import Foundation
import AVFoundation
import ImageIO
import Darwin

/// Routing is a UI hint, never a substitute for validating the extracted file.
public enum FilePreviewKind: String, Sendable {
    case text, image, audio, video
    public static func forPath(_ path: String) -> Self? {
        switch (path as NSString).pathExtension.lowercased() {
        case "txt", "md", "json", "xml", "csv", "log", "swift", "plist", "yaml", "yml", "html", "htm", "svg", "css": return .text
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "gif", "tif", "tiff", "bmp", "ico": return .image
        case "flac", "mp3", "m4a", "aac", "wav", "aif", "aiff", "ogg", "opus": return .audio
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "mpeg", "mpg", "wmv": return .video
        default: return nil
        }
    }
}

public extension ArchiveEntry {
    var previewKind: FilePreviewKind? {
        guard !isDirectory, !isLink, ArchiveCommands.safePath(path),
              !path.split(separator: "/").contains(where: { ["app", "bundle", "framework"].contains(($0.description as NSString).pathExtension.lowercased()) }) else { return nil }
        return FilePreviewKind.forPath(path)
    }
}

public struct TextPreview: Sendable {
    public let text: String
    public let truncated: Bool
    public let encoding: String
}

public enum FilePreviewContent {
    public static let textLimit = 256 * 1024
    public static let imageLimit = 32 * 1024 * 1024
    public static let artworkLimit = 8 * 1024 * 1024
    public static let maximumPixels = 32_000_000

    /// No symlink following, FIFOs, sockets or unbounded whole-file reads.
    public static func readPrefix(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit >= 0, limit <= imageLimit else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= PreviewSafety.maximumBytes else { throw ArchiveError.invalid("This file cannot be opened safely.") }
        try Task.checkCancellation()
        return try handle.read(upToCount: limit) ?? Data()
    }

    public static func text(_ url: URL) throws -> TextPreview {
        let input = try readPrefix(url, limit: textLimit + 4)
        return try decodeText(input)
    }

    public static func decodeText(_ input: Data) throws -> TextPreview {
        let truncated = input.count > textLimit
        let bytes = Data(input.prefix(textLimit))
        let little = bytes.starts(with: [0xff, 0xfe])
        let big = bytes.starts(with: [0xfe, 0xff])
        var decoded: String?
        let encoding = little ? "UTF-16 LE" : big ? "UTF-16 BE" : "UTF-8"
        if little || big {
            let payload = Array(bytes.dropFirst(2))
            if payload.count % 2 == 0 || truncated {
                var units = stride(from: 0, to: payload.count - payload.count % 2, by: 2).map { index in
                    little ? UInt16(payload[index]) | UInt16(payload[index + 1]) << 8 : UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
                }
                if truncated, let last = units.last, (0xd800...0xdbff).contains(last) { units.removeLast() }
                let string = String(decoding: units, as: UTF16.self)
                if Array(string.utf16) == units { decoded = string }
            }
        } else {
            let payload = Data(bytes.starts(with: [0xef, 0xbb, 0xbf]) ? bytes.dropFirst(3) : bytes[...])
            // A bounded prefix may split the final UTF-8 scalar, but never repair invalid bytes inside it.
            for trim in 0...(truncated ? min(3, payload.count) : 0) {
                if let text = String(data: payload.dropLast(trim), encoding: .utf8) { decoded = text; break }
            }
        }
        guard let text = decoded, !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            throw ArchiveError.invalid("Text preview requires UTF-8 or BOM-marked UTF-16. Binary data is not rendered.")
        }
        return TextPreview(text: text, truncated: truncated, encoding: encoding)
    }

    public static func image(_ url: URL, maximumEdge: Int = 2560) throws -> CGImage {
        let data = try readPrefix(url, limit: imageLimit)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= imageLimit, data.count == size else { throw ArchiveError.invalid("Image preview is limited to 32 MiB and 32 million pixels.") }
        return try thumbnail(data, maximumEdge: maximumEdge)
    }

    /// Decode only one downsampled frame. Never animate all GIF frames or load a full-resolution NSImage.
    public static func thumbnail(_ data: Data, maximumEdge: Int) throws -> CGImage {
        guard data.count <= imageLimit, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maximumPixels, height <= maximumPixels / width else {
            throw ArchiveError.invalid("Image is unsupported, damaged, or exceeds preview limits.")
        }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: max(64, min(maximumEdge, 2560)),
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ArchiveError.invalid("Image is unsupported, damaged, or exceeds preview limits.")
        }
        try Task.checkCancellation()
        return image
    }

    public static func isMediaHeader(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(16))
        func starts(_ value: String) -> Bool { bytes.starts(with: Array(value.utf8)) }
        if starts("fLaC") || starts("ID3") || starts("OggS") || bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true }
        if bytes.count >= 12 {
            let form = String(bytes: bytes[8..<12], encoding: .ascii)
            if starts("RIFF") && ["WAVE", "AVI "].contains(form) { return true }
            if starts("FORM") && ["AIFF", "AIFC"].contains(form) { return true }
            let atom = String(bytes: bytes[4..<8], encoding: .ascii)
            if ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(atom) { return true }
        }
        // MPEG audio / ADTS sync. HLS, XML playlists and URL lists are never passed to AVFoundation.
        return bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0
    }
}

public struct PreviewTag: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let value: String
}

public struct MediaPreviewDetails {
    public let asset: AVURLAsset
    public let duration: Double
    public let hasVideo: Bool
    public let tags: [PreviewTag]
    public let artwork: CGImage?
    public let artworkUnavailable: Bool
    public let tagsLimited: Bool
}

public enum NativeMediaPreview {
    public static func boundedTag(_ value: String) -> (text: String, limited: Bool) {
        let prefix = Array(value.utf8.prefix(2049))
        var bytes = Array(prefix.prefix(2048))
        // Bound bytes, not grapheme clusters (one cluster can contain arbitrarily many combining marks).
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        let safe = text.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }
        return (String(String.UnicodeScalarView(safe)), prefix.count > 2048)
    }
    public static func asset(_ url: URL) throws -> AVURLAsset {
        guard FilePreviewContent.isMediaHeader(try FilePreviewContent.readPrefix(url, limit: 16)) else {
            throw ArchiveError.invalid("This media format or codec is not supported by the macOS player. Extract it to use another player.")
        }
        return AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetShouldSupportAliasDataReferencesKey: false,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false
        ])
    }

    /// Native asynchronous loading; no eager media Data or software-decoded frame queues.
    public static func inspect(_ asset: AVURLAsset) async throws -> MediaPreviewDetails {
        let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        try Task.checkCancellation()
        guard playable, !protected else { throw ArchiveError.invalid("This media format or codec is not supported by the macOS player. Extract it to use another player.") }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count + audio.count <= 8, !video.isEmpty || !audio.isEmpty else { throw ArchiveError.invalid("Media has no playable tracks or exceeds the preview track limit.") }
        for track in video {
            let size = try await track.load(.naturalSize)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width * size.height <= Double(FilePreviewContent.maximumPixels) else {
                throw ArchiveError.invalid("Video dimensions exceed preview limits.")
            }
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let metadata = common + ((try? await asset.load(.metadata)) ?? [])
        let labels: [AVMetadataKey: String] = [.commonKeyTitle: "Title", .commonKeyArtist: "Artist", .commonKeyAlbumName: "Album",
                                              .commonKeyAuthor: "Author", .commonKeyCreationDate: "Date", .commonKeyDescription: "Description",
                                              .commonKeyCopyrights: "Copyright", .commonKeySoftware: "Encoder"]
        let identifiers: [AVMetadataIdentifier: String] = [
            .id3MetadataBand: "Album artist", .iTunesMetadataAlbumArtist: "Album artist",
            .id3MetadataTrackNumber: "Track", .id3MetadataPartOfASet: "Disc",
            .id3MetadataContentType: "Genre", .iTunesMetadataUserGenre: "Genre",
            .id3MetadataComposer: "Composer", .iTunesMetadataComposer: "Composer",
            .id3MetadataComments: "Comment", .id3MetadataYear: "Date", .id3MetadataRecordingTime: "Date",
            .iTunesMetadataReleaseDate: "Date"
        ]
        var tags: [PreviewTag] = [], seen = Set<String>(), artwork: CGImage?, coverFailed = false, limited = metadata.count > 64
        for item in metadata.prefix(64) {
            try Task.checkCancellation()
            if item.commonKey == .commonKeyArtwork && artwork == nil {
                if let data = try? await item.load(.dataValue), data.count <= FilePreviewContent.artworkLimit,
                   data.starts(with: [0xff, 0xd8]) || data.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
                    artwork = try? FilePreviewContent.thumbnail(data, maximumEdge: 1024)
                }
                coverFailed = artwork == nil
            } else if let label = item.commonKey.flatMap({ labels[$0] }) ?? item.identifier.flatMap({ identifiers[$0] }), !seen.contains(label),
                      let value = try? await item.load(.stringValue), !value.isEmpty {
                seen.insert(label)
                let bounded = boundedTag(value)
                limited = limited || bounded.limited
                tags.append(PreviewTag(label: label, value: bounded.text))
            }
        }
        let order = ["Title", "Artist", "Album", "Album artist", "Track", "Disc", "Date", "Genre", "Composer", "Comment", "Author", "Description", "Copyright", "Encoder"]
        tags.sort { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
        let seconds = CMTimeGetSeconds(duration)
        return MediaPreviewDetails(asset: asset, duration: seconds.isFinite && seconds > 0 ? seconds : 0,
                                   hasVideo: !video.isEmpty, tags: tags, artwork: artwork, artworkUnavailable: coverFailed, tagsLimited: limited)
    }
}
