import Foundation

public struct LanguagePack: Codable, Identifiable {
    public static func readFile(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PackError.invalid("Invalid language pack metadata.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= 1_048_576 {
            let chunk = try handle.read(upToCount: min(65_536, 1_048_577 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw PackError.invalid("Language pack exceeds 1 MB.")
    }
    public let schemaVersion: Int
    public let sourceLanguage: String?
    public let id: String
    public let name: String
    public let locale: String
    public let strings: [String: String]

    public static func decode(_ data: Data, reference: LanguagePack? = nil, legacyKeys: [String: String] = [:]) throws -> LanguagePack {
        guard data.count <= 1_048_576 else { throw PackError.invalid("Language pack exceeds 1 MB.") }
        var pack = try JSONDecoder().decode(LanguagePack.self, from: data)
        if pack.schemaVersion == 1 {
            guard reference != nil, !legacyKeys.isEmpty else { throw PackError.invalid("Legacy language pack requires the bundled migration dictionary. Use the English schema v2 template.") }
            var migrated: [String: String] = [:]
            for key in pack.strings.keys.sorted() {
                guard let englishKey = legacyKeys[key] else { throw PackError.invalid("Unknown legacy translation key: \(key)") }
                // Two old labels shared one English meaning. Prefer a stable first value.
                if migrated[englishKey] == nil { migrated[englishKey] = pack.strings[key] }
            }
            pack = LanguagePack(schemaVersion: 2, sourceLanguage: "en", id: pack.id, name: pack.name, locale: pack.locale, strings: migrated)
        }
        guard pack.schemaVersion == 2, pack.sourceLanguage == "en", pack.id.range(of: "^[A-Za-z][A-Za-z0-9-]{1,39}$", options: .regularExpression) != nil,
              pack.locale.range(of: "^[A-Za-z]{2,8}([_-][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
              !pack.name.isEmpty, pack.name.count <= 80, !pack.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              pack.strings.count <= 512 else { throw PackError.invalid("Invalid language pack metadata.") }
        for (key, value) in pack.strings {
            guard !key.isEmpty, key.count <= 8000, !value.isEmpty, value.count <= 8000,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }),
                  tokens(key) == tokens(value) else { throw PackError.invalid("Invalid text or placeholders: \(key)") }
            if let reference, reference.strings[key] == nil { throw PackError.invalid("Unknown translation key: \(key)") }
        }
        return pack
    }
    private static func tokens(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }
    public func text(_ key: String, fallback: LanguagePack?, values: [String] = []) -> String {
        let format = strings[key] ?? fallback?.strings[key] ?? key
        // Replace placeholders in one pass: user filenames containing {0} stay literal.
        let regex = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        var result = format
        for match in regex.matches(in: format, range: NSRange(format.startIndex..., in: format)).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: format), let index = Int(format[numberRange]), values.indices.contains(index), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: values[index])
        }
        return result
    }
}

public enum PackError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
