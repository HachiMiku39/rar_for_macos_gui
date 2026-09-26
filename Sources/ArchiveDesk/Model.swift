import SwiftUI
import AppKit
#if canImport(ArchiveCore)
import ArchiveCore
#endif

@MainActor final class Model: ObservableObject {
    let language = AppLanguage.shared
    @Published var archive: URL?
    @Published var entries: [ArchiveEntry] = []
    @Published var selection: Set<String> = []
    @Published var filter = ""
    @Published var busy = false
    @Published var status = AppLanguage.shared.text("打开压缩包，或拖入文件创建 RAR")
    @Published var stdout = ""
    @Published var stderr = ""
    @Published var progress: Double?
    @Published var password = ""
    @Published var showCreate = false
    @Published var inputs: [URL] = []
    @Published var error: String?
    @Published var recent: [URL] = []
    @Published var rar = UserDefaults.standard.string(forKey: "rar") ?? "/opt/homebrew/bin/rar"
    @Published var unrar = UserDefaults.standard.string(forKey: "unrar") ?? "/opt/homebrew/bin/unrar"
    @Published var sevenZip = UserDefaults.standard.string(forKey: "sevenZipOverrideV2") ?? ""
    private var session: ArchiveSession?
    var bundledSevenZip: String { Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz").path ?? "" }
    var resolvedSevenZip: String { sevenZip.isEmpty ? bundledSevenZip : sevenZip }
    let runner = CLIRunner()
    var visible: [ArchiveEntry] { entries.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) } }
    func savePaths() { for (key, value) in [("rar", rar), ("sevenZipOverrideV2", sevenZip)] { UserDefaults.standard.set(value, forKey: key) } }
    func executable(for url: URL) -> String { resolvedSevenZip }
    func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func receive(_ urls: [URL]) {
        guard !busy else { return }
        if urls.count == 1, let url = urls.first, ArchiveCommands.extensions.contains(url.pathExtension.lowercased()), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { open(url) }
        else { inputs = urls; showCreate = true }
    }
    func chooseInputs() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        if panel.runModal() == .OK { inputs = panel.urls; showCreate = true }
    }
    func open(_ url: URL) {
        guard !busy else { return }
        session = nil; archive = url; entries = []; selection = []; password = ""; filter = ""
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(10))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        browse()
    }
    func browse() {
        guard let archive else { return }
        do {
            let args = try ArchiveCommands.list(archive, password: password, using: .sevenZip)
            entries = []; selection = []
            launch(language.text("读取目录"), executable: executable(for: archive), args: args, secret: password, preparing: archive) { result in
                let parsed = result.archiveEntries(backend: .sevenZip)
                guard Set(parsed.map(\.path)).count == parsed.count else { self.error = self.language.text("存在重复路径，无法可靠选择条目。"); return }
                self.entries = parsed
                self.status = self.language.text("{0} 个条目 · {1}", String(parsed.count), archive.lastPathComponent)
            }
        } catch { self.error = language.message(error) }
    }
    func extract(selected: Bool) {
        guard let archive, !entries.isEmpty else { return }
        guard entries.allSatisfy({ ArchiveCommands.safePath($0.path) && !$0.isLink }) else { error = language.text("压缩包包含不安全路径或链接。此原型拒绝解压，请使用受信任的独立工具检查。"); return }
        let chosen = selected ? entries.filter { item in
            selection.contains(item.path) || selection.contains { item.path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }
        }.map(\.path) : []
        guard !selected || !chosen.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = language.text("选择解压位置")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        // New destination prevents existing symlink traversal and accidental overwrites.
        let destination = parent.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let args = try ArchiveCommands.extract(session?.workingURL ?? archive, destination: destination, selected: chosen, password: password, using: .sevenZip)
            launch(language.text("解压至 {0}", destination.lastPathComponent), executable: executable(for: archive), args: args, secret: password) { _ in NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch { self.error = language.message(error) }
    }
    func test() {
        guard let archive else { return }
        do { launch(language.text("测试压缩包"), executable: executable(for: archive), args: try ArchiveCommands.test(session?.workingURL ?? archive, password: password, using: .sevenZip), secret: password) } catch { self.error = language.message(error) }
    }
    func recovery(_ command: String) {
        guard requireRAR() else { return }
        guard let archive, ArchiveCommands.backend(archive) == .rar else { return }
        let alert = NSAlert(); alert.messageText = command.hasPrefix("rr") ? language.text("为原压缩包添加 3% 恢复记录？") : language.text("在压缩包旁创建 10% 恢复卷？")
        alert.informativeText = language.text("恢复记录会修改原 RAR；恢复卷需要分卷 RAR。请保留备份。"); alert.addButton(withTitle: language.text("继续")); alert.addButton(withTitle: language.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { launch(language.text("恢复数据"), executable: rar, args: [command, "-cfg-", try ArchiveCommands.passwordSwitch(password), "--", archive.path], secret: password) } catch { self.error = language.message(error) }
    }
    func create(password secret: String, headers: Bool, volume: Int, recovery: Int) {
        guard requireRAR() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Archive.rar"; panel.title = language.text("创建新 RAR5 压缩包")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        do {
            let args = try ArchiveCommands.create(output: output, inputs: inputs, password: secret, headers: headers, volumeMB: volume, recovery: recovery)
            // Reserve a fresh folder for multi-volume output to avoid colliding with existing parts.
            if volume > 0 {
                let stem = output.deletingPathExtension().lastPathComponent
                let siblings = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
                guard !siblings.contains(where: { $0.hasPrefix(stem + ".part") }) else { throw ArchiveError.invalid(language.text("目标目录中已有同名前缀的分卷，请换一个文件名。")) }
            }
            showCreate = false
            launch(language.text("创建 RAR5"), executable: rar, args: args, directory: inputs.first?.deletingLastPathComponent(), secret: secret) { _ in NSWorkspace.shared.activateFileViewerSelecting([output.deletingLastPathComponent()]) }
        } catch { self.error = language.message(error) }
    }
    func check(_ path: String) { savePaths(); launch(language.text("检测 CLI"), executable: path, args: ["-?"]) }
    private func requireRAR() -> Bool {
        guard !FileManager.default.isExecutableFile(atPath: rar) else { return true }
        let alert = NSAlert()
        alert.messageText = language.text("需要 RAR 创建工具")
        alert.informativeText = language.text("RAR 创建与恢复数据需要单独安装 RARLAB 工具。可打开官网下载，解包后在设置中选择 rar。")
        alert.addButton(withTitle: language.text("打开下载网页")); alert.addButton(withTitle: language.text("取消"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.rarlab.com/download.htm")!) }
        return false
    }
    func launch(_ title: String, executable: String, args: [String], directory: URL? = nil, secret: String = "", preparing: URL? = nil, success: @escaping (CLIResult) -> Void = { _ in }) {
        guard !busy else { return }
        busy = true; progress = nil; stdout = ""; stderr = ""; status = title
        Task {
            defer { busy = false; progress = nil }
            do {
                var actualArgs = args
                if let preparing {
                    session = nil
                    session = try await ArchiveSession.prepare(preparing, sevenZip: executable, runner: runner) { a, b in
                        Task { @MainActor in self.stdout = String(a.suffix(200_000)); self.stderr = String(b.suffix(100_000)) }
                    }
                    actualArgs = try ArchiveCommands.list(session!.workingURL, password: secret, using: .sevenZip)
                }
                let result = try await runner.run(executable: executable, arguments: actualArgs, directory: directory, password: secret) { a, b in
                    Task { @MainActor in
                        self.stdout = String(a.suffix(200_000)); self.stderr = String(b.suffix(100_000))
                        if let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})%"), let match = regex.matches(in: a, range: NSRange(a.startIndex..., in: a)).last, let range = Range(match.range(at: 1), in: a), let value = Double(a[range]) { self.progress = min(value / 100, 1) }
                    }
                }
                stdout = String(result.stdout.suffix(200_000)); stderr = String(result.stderr.suffix(100_000))
                if result.cancelled { status = language.text("已取消；可能留下不完整输出，请检查目标目录。") }
                else if result.status == 0 { status = language.text("{0} · 完成", title); success(result) }
                else { status = language.text("{0} · 退出码 {1}", title, String(result.status)); error = language.text("CLI 退出码 {0}。请查看 stderr/stdout。密码错误时可输入密码后重新读取。", String(result.status)) }
            } catch { self.error = language.message(error); status = language.text("无法执行") }
        }
    }
}
