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
    @Published var recent: [URL] = (UserDefaults.standard.stringArray(forKey: "recentArchives") ?? []).map { URL(fileURLWithPath: $0) }
    @Published var directory = ""
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    private var openedCopies: [URL] = []
    @Published var rar = UserDefaults.standard.string(forKey: "rar") ?? "/opt/homebrew/bin/rar"
    @Published var unrar = UserDefaults.standard.string(forKey: "unrar") ?? "/opt/homebrew/bin/unrar"
    @Published var sevenZip = UserDefaults.standard.string(forKey: "sevenZipOverrideV2") ?? ""
    private var session: ArchiveSession?
    var bundledSevenZip: String { Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz").path ?? "" }
    var resolvedSevenZip: String { sevenZip.isEmpty ? bundledSevenZip : sevenZip }
    let runner = CLIRunner()
    var visible: [ArchiveEntry] { ArchiveBrowser.children(entries, directory: directory, filter: filter) }
    var selectedEntry: ArchiveEntry? { selection.count == 1 ? visible.first { selection.contains($0.id) } : nil }
    func navigate(_ path: String) { directory = path; selection = []; filter = "" }
    func goUp() { navigate((directory as NSString).deletingLastPathComponent) }
    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: "recentArchives")
        NSDocumentController.shared.clearRecentDocuments(nil)
        status = language.text("已清除历史记录，原文件未删除。")
    }
    func cleanOpenedCopies() {
        for url in openedCopies { try? FileManager.default.removeItem(at: url) }
        openedCopies = []
    }
    func activate(_ item: ArchiveEntry) {
        guard !busy else { return }
        if item.isDirectory { navigate(item.path); return }
        guard item.category != "压缩包" else { error = language.text("暂不支持打开压缩包内的压缩包。"); return }
        guard item.canOpenCopy else { error = language.text("此类型不能直接打开，请先解压后自行检查。"); return }
        guard let archive, entries.allSatisfy({ ArchiveCommands.safePath($0.path) && !$0.isLink }),
              let size = UInt64(item.size), size <= PreviewSafety.maximumBytes else {
            error = language.text("仅支持打开不含链接的安全归档中的普通文件，单文件上限 512 MB。"); return
        }
        let notice = NSAlert()
        notice.messageText = language.text("打开临时副本？")
        notice.informativeText = language.text("将交给系统默认应用打开。只打开可信文件；编辑不会写回压缩包，退出本软件时临时副本会被清理。")
        notice.addButton(withTitle: language.text("打开")); notice.addButton(withTitle: language.text("取消"))
        guard notice.runModal() == .alertFirstButtonReturn else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-open-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let args = try ArchiveCommands.extract(session?.workingURL ?? archive, destination: root, selected: [item.path], password: password, using: .sevenZip)
            openedCopies.append(root)
            var retained = false
            launch(language.text("准备打开文件"), executable: resolvedSevenZip, args: args, secret: password, completion: {
                if !retained { try? FileManager.default.removeItem(at: root); self.openedCopies.removeAll { $0 == root } }
            }) { _ in
                do {
                    let file = root.appendingPathComponent(item.path)
                    try PreviewSafety.validate(file, inside: root)
                    guard NSWorkspace.shared.open(file) else { throw ArchiveError.invalid("没有可打开此文件的默认应用。") }
                    retained = true
                    self.status = self.language.text("已打开临时副本，不会写回压缩包。")
                } catch { self.error = self.language.message(error) }
            }
        } catch { try? FileManager.default.removeItem(at: root); self.error = language.message(error) }
    }
    func savePaths() { for (key, value) in [("rar", rar), ("sevenZipOverrideV2", sevenZip)] { UserDefaults.standard.set(value, forKey: key) } }
    func executable(for url: URL) -> String { resolvedSevenZip }
    func chooseArchive() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func receive(_ urls: [URL]) {
        guard !busy else { return }
        if urls.count == 1, let url = urls.first, ArchiveCommands.extensions.contains(url.pathExtension.lowercased()), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { open(url) }
        else { inputs = urls; showCreate = true }
    }
    func chooseInputs() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        if panel.runModal() == .OK { inputs = panel.urls; showCreate = true }
    }
    func open(_ url: URL) {
        guard !busy else { return }
        session = nil; archive = url; entries = []; selection = []; password = ""; filter = ""; directory = ""
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(10))
        UserDefaults.standard.set(recent.map(\.path), forKey: "recentArchives")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        browse()
    }
    func browse() {
        guard !busy else { return }
        guard let archive else { return }
        do {
            let args = try ArchiveCommands.list(archive, password: password, using: .sevenZip)
            entries = []; selection = []; directory = ""
            launch(language.text("读取目录"), executable: executable(for: archive), args: args, secret: password, preparing: archive) { result in
                let parsed = result.archiveEntries(backend: .sevenZip)
                guard Set(parsed.map(\.path)).count == parsed.count else { self.error = self.language.text("存在重复路径，无法可靠选择条目。"); return }
                self.entries = parsed
                self.status = self.language.text("{0} 个条目 · {1}", String(parsed.count), archive.lastPathComponent)
            }
        } catch { self.error = language.message(error) }
    }
    func extract(selected: Bool) {
        guard !busy else { return }
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
        guard !busy else { return }
        guard let archive else { return }
        do { launch(language.text("测试压缩包"), executable: executable(for: archive), args: try ArchiveCommands.test(session?.workingURL ?? archive, password: password, using: .sevenZip), secret: password) } catch { self.error = language.message(error) }
    }
    func recovery(_ command: String) {
        guard !busy else { return }
        guard requireRAR() else { return }
        guard let archive, ArchiveCommands.backend(archive) == .rar else { return }
        let alert = NSAlert(); alert.messageText = command.hasPrefix("rr") ? language.text("为原压缩包添加 3% 恢复记录？") : language.text("在压缩包旁创建 10% 恢复卷？")
        alert.informativeText = language.text("恢复记录会修改原 RAR；恢复卷需要分卷 RAR。请保留备份。"); alert.addButton(withTitle: language.text("继续")); alert.addButton(withTitle: language.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { launch(language.text("恢复数据"), executable: rar, args: [command, "-cfg-", try ArchiveCommands.passwordSwitch(password), "--", archive.path], secret: password) } catch { self.error = language.message(error) }
    }
    func create(password secret: String, headers: Bool, volume: Int, recovery: Int, options: CreationOptions) {
        guard !busy else { return }
        if options.format == .rar && !requireRAR() { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Archive." + options.format.rawValue; panel.title = language.text("创建压缩包")
        guard panel.runModal() == .OK, let selectedOutput = panel.url else { return }
        var createdFolder: URL?
        do {
            // Validate before creating any directory. Volumes always use a fresh folder.
            _ = try ArchiveCommands.create(output: selectedOutput, inputs: inputs, password: secret, headers: headers, volumeMB: volume, recovery: recovery, options: options)
            var output = selectedOutput
            if volume > 0 {
                let folder = selectedOutput.deletingLastPathComponent().appendingPathComponent(selectedOutput.deletingPathExtension().lastPathComponent + "-parts-" + String(UUID().uuidString.prefix(8)))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                createdFolder = folder
                output = folder.appendingPathComponent(selectedOutput.lastPathComponent)
            }
            let args = try ArchiveCommands.create(output: output, inputs: inputs, password: secret, headers: headers, volumeMB: volume, recovery: recovery, options: options)
            let engine = options.format == .rar ? rar : resolvedSevenZip
            let firstVolume = volume > 0 ? URL(fileURLWithPath: output.path + ".001") : output
            let verification = options.testAfter && options.format != .rar
                ? try ArchiveCommands.test(firstVolume, password: secret, using: .sevenZip) : nil
            showCreate = false
            launch(language.text("创建压缩包"), executable: engine, args: args, directory: inputs.first?.deletingLastPathComponent(), secret: secret, verification: verification) { _ in
                NSWorkspace.shared.activateFileViewerSelecting([output.deletingLastPathComponent()])
            }
        } catch {
            if let createdFolder { try? FileManager.default.removeItem(at: createdFolder) }
            self.error = language.message(error)
        }
    }
    func archiveInfo() {
        guard let archive else { return }
        let files = entries.filter { !$0.isDirectory }
        let bytes = files.reduce(UInt64(0)) { total, item in
            let sum = total.addingReportingOverflow(UInt64(item.size) ?? 0)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        let alert = NSAlert()
        alert.messageText = language.text("压缩包信息")
        alert.informativeText = archive.lastPathComponent + "\n" +
            language.text("文件：{0} · 文件夹：{1}", String(files.count), String(entries.filter(\.isDirectory).count)) + "\n" +
            language.text("原始大小：{0} 字节", String(bytes)) + "\n" +
            language.text("信息来自当前目录列表；并非完整的格式属性检测。")
        alert.addButton(withTitle: language.text("好")); alert.runModal()
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
    func launch(_ title: String, executable: String, args: [String], directory: URL? = nil, secret: String = "", preparing: URL? = nil, verification: [String]? = nil, completion: @escaping () -> Void = {}, success: @escaping (CLIResult) -> Void = { _ in }) {
        guard !busy else { return }
        busy = true; progress = nil; stdout = ""; stderr = ""; status = title
        Task {
            defer { busy = false; progress = nil; completion() }
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
                else if result.status == 0 {
                    if let verification {
                        status = language.text("压缩后测试")
                        let checked = try await runner.run(executable: executable, arguments: verification, password: secret) { _, _ in }
                        stdout += "\n--- Post-create test ---\n" + String(checked.stdout.suffix(100_000))
                        stderr += "\n" + String(checked.stderr.suffix(100_000))
                        guard !checked.cancelled, checked.status == 0 else {
                            error = language.text("压缩包已生成，但后续测试未完成或失败，请检查日志。")
                            status = language.text("压缩后测试失败"); return
                        }
                    }
                    status = language.text("{0} · 完成", title); success(result)
                }
                else { status = language.text("{0} · 退出码 {1}", title, String(result.status)); error = language.text("CLI 退出码 {0}。请查看 stderr/stdout。密码错误时可输入密码后重新读取。", String(result.status)) }
            } catch { self.error = language.message(error); status = language.text("无法执行") }
        }
    }
}
