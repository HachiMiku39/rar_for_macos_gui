import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(ArchiveCore)
import ArchiveCore
#endif

@MainActor final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    @Published var selected: String { didSet { UserDefaults.standard.set(selected, forKey: "languageID") } }
    @Published private(set) var packs: [LanguagePack] = []
    @Published var importError: String?
    private var builtins: Set<String> = []
    private var english: LanguagePack?
    private var packDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArchiveDesk/LanguagePacks", isDirectory: true)
    }
    var active: LanguagePack? {
        let id: String
        if selected == "system" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            id = preferred.hasPrefix("zh") ? "zh-Hans" : preferred.hasPrefix("ja") ? "ja" : "en"
        } else { id = selected }
        return packs.first { $0.id == id } ?? english
    }
    var locale: Locale { Locale(identifier: active?.locale ?? "en") }
    init() {
        selected = UserDefaults.standard.string(forKey: "languageID") ?? "system"
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Languages")
        if let directory, let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            packs = urls.filter { $0.pathExtension == "json" }.compactMap { try? LanguagePack.decode(Data(contentsOf: $0)) }.sorted { $0.id < $1.id }
        }
        english = packs.first { $0.id == "en" }
        builtins = Set(packs.map(\.id))
        if let urls = try? FileManager.default.contentsOfDirectory(at: packDirectory, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "json" {
                if let pack = try? LanguagePack.decode(Data(contentsOf: url), reference: english), !builtins.contains(pack.id), !packs.contains(where: { $0.id == pack.id }) { packs.append(pack) }
            }
        }
    }
    func text(_ key: String, _ values: String...) -> String { active?.text(key, fallback: english, values: values) ?? key }
    func message(_ error: Error) -> String {
        guard let archiveError = error as? ArchiveError else { return error.localizedDescription }
        switch archiveError {
        case .invalid(let key): return text(key)
        case .details(let key, let values): return active?.text(key, fallback: english, values: values) ?? error.localizedDescription
        }
    }
    func importPack() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw PackError.invalid("Language pack exceeds 1 MB.") }
            let data = try Data(contentsOf: url)
            let pack = try LanguagePack.decode(data, reference: english)
            guard !builtins.contains(pack.id) else { throw PackError.invalid("Built-in language IDs cannot be replaced. Use a new ID.") }
            if packs.contains(where: { $0.id == pack.id }) {
                let alert = NSAlert(); alert.messageText = text("替换已有语言包？"); alert.addButton(withTitle: text("替换")); alert.addButton(withTitle: text("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
            try data.write(to: packDirectory.appendingPathComponent(pack.id + ".json"), options: .atomic)
            packs.removeAll { $0.id == pack.id }; packs.append(pack); selected = pack.id
        } catch { importError = error.localizedDescription }
    }
    func showDemo() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("LocalizationDemo") { NSWorkspace.shared.open(url) }
    }
}
