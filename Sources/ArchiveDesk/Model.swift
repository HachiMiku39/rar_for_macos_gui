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
    @Published var status = AppLanguage.shared.text("Open an archive, or drop files to create one")
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
        status = language.text("History cleared. Original files were not deleted.")
    }
    func cleanOpenedCopies() {
        for url in openedCopies { try? FileManager.default.removeItem(at: url) }
        openedCopies = []
    }
    func activate(_ item: ArchiveEntry) {
        guard !busy else { return }
        if item.isDirectory { navigate(item.path); return }
        guard item.category != "Archive" else { error = language.text("Opening nested archives is not supported yet."); return }
        guard item.canOpenCopy else { error = language.text("This type cannot be opened directly. Extract it first and inspect it yourself."); return }
        guard let archive, entries.allSatisfy({ ArchiveCommands.safePath($0.path) && !$0.isLink }),
              let size = UInt64(item.size), size <= PreviewSafety.maximumBytes else {
            error = language.text("Only regular files in safe, link-free archives can be opened, up to 512 MB per file."); return
        }
        let notice = NSAlert()
        notice.messageText = language.text("Open a temporary copy?")
        notice.informativeText = language.text("The system default app will open this copy. Open only trusted files. Edits are not saved back to the archive; temporary copies are removed when ArchiveDesk quits.")
        notice.addButton(withTitle: language.text("Open")); notice.addButton(withTitle: language.text("Cancel"))
        guard notice.runModal() == .alertFirstButtonReturn else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-open-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let args = try ArchiveCommands.extract(session?.workingURL ?? archive, destination: root, selected: [item.path], password: password, using: .sevenZip)
            openedCopies.append(root)
            var retained = false
            launch(language.text("Preparing to Open File"), executable: resolvedSevenZip, args: args, secret: password, completion: {
                if !retained { try? FileManager.default.removeItem(at: root); self.openedCopies.removeAll { $0 == root } }
            }) { _ in
                do {
                    let file = root.appendingPathComponent(item.path)
                    try PreviewSafety.validate(file, inside: root)
                    guard NSWorkspace.shared.open(file) else { throw ArchiveError.invalid("No default app could open this file.") }
                    retained = true
                    self.status = self.language.text("Opened a temporary copy. Changes will not be saved to the archive.")
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
            launch(language.text("Reading archive"), executable: executable(for: archive), args: args, secret: password, preparing: archive) { result in
                let parsed = result.archiveEntries(backend: .sevenZip)
                guard Set(parsed.map(\.path)).count == parsed.count else { self.error = self.language.text("Duplicate paths prevent reliable item selection."); return }
                self.entries = parsed
                self.status = self.language.text("{0} items · {1}", String(parsed.count), archive.lastPathComponent)
            }
        } catch { self.error = language.message(error) }
    }
    func extract(selected: Bool) {
        guard !busy else { return }
        guard let archive, !entries.isEmpty else { return }
        guard entries.allSatisfy({ ArchiveCommands.safePath($0.path) && !$0.isLink }) else { error = language.text("This archive contains unsafe paths or links. Extraction was refused; inspect it with a trusted tool."); return }
        let chosen = selected ? entries.filter { item in
            selection.contains(item.path) || selection.contains { item.path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }
        }.map(\.path) : []
        guard !selected || !chosen.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = language.text("Choose Extraction Location")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        // New destination prevents existing symlink traversal and accidental overwrites.
        let destination = parent.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let args = try ArchiveCommands.extract(session?.workingURL ?? archive, destination: destination, selected: chosen, password: password, using: .sevenZip)
            launch(language.text("Extracting to {0}", destination.lastPathComponent), executable: executable(for: archive), args: args, secret: password) { _ in NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch { self.error = language.message(error) }
    }
    func test() {
        guard !busy else { return }
        guard let archive else { return }
        do { launch(language.text("Testing archive"), executable: executable(for: archive), args: try ArchiveCommands.test(session?.workingURL ?? archive, password: password, using: .sevenZip), secret: password) } catch { self.error = language.message(error) }
    }
    func recovery(_ command: String) {
        guard !busy else { return }
        guard requireRAR() else { return }
        guard let archive, ArchiveCommands.backend(archive) == .rar else { return }
        let alert = NSAlert(); alert.messageText = command.hasPrefix("rr") ? language.text("Add a 3% recovery record to the original archive?") : language.text("Create 10% recovery volumes beside the archive?")
        alert.informativeText = language.text("Recovery records modify the original RAR. Recovery volumes require a multi-volume RAR. Keep a backup."); alert.addButton(withTitle: language.text("Continue")); alert.addButton(withTitle: language.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { launch(language.text("Recovery Data"), executable: rar, args: [command, "-cfg-", try ArchiveCommands.passwordSwitch(password), "--", archive.path], secret: password) } catch { self.error = language.message(error) }
    }
    func create(password secret: String, headers: Bool, volume: Int, recovery: Int, options: CreationOptions) {
        guard !busy else { return }
        if options.format == .rar && !requireRAR() { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Archive." + options.format.rawValue; panel.title = language.text("Create Archive")
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
            launch(language.text("Create Archive"), executable: engine, args: args, directory: inputs.first?.deletingLastPathComponent(), secret: secret, verification: verification) { _ in
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
        alert.messageText = language.text("Archive Information")
        alert.informativeText = archive.lastPathComponent + "\n" +
            language.text("Files: {0} · Folders: {1}", String(files.count), String(entries.filter(\.isDirectory).count)) + "\n" +
            language.text("Uncompressed Size: {0} bytes", String(bytes)) + "\n" +
            language.text("Based on the loaded listing, not a complete format-property inspection.")
        alert.addButton(withTitle: language.text("OK")); alert.runModal()
    }
    func check(_ path: String) { savePaths(); launch(language.text("Checking engine"), executable: path, args: ["-?"]) }
    private func requireRAR() -> Bool {
        guard !FileManager.default.isExecutableFile(atPath: rar) else { return true }
        let alert = NSAlert()
        alert.messageText = language.text("RAR Tool Required")
        alert.informativeText = language.text("RAR creation and recovery require the RARLAB tool. Download it from the official website, unpack it, and select rar in Settings.")
        alert.addButton(withTitle: language.text("Open Download Page")); alert.addButton(withTitle: language.text("Cancel"))
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
                if result.cancelled { status = language.text("Cancelled. Partial output may remain; check the destination.") }
                else if result.status == 0 {
                    if let verification {
                        status = language.text("Test After Archiving")
                        let checked = try await runner.run(executable: executable, arguments: verification, password: secret) { _, _ in }
                        stdout += "\n--- Post-create test ---\n" + String(checked.stdout.suffix(100_000))
                        stderr += "\n" + String(checked.stderr.suffix(100_000))
                        guard !checked.cancelled, checked.status == 0 else {
                            error = language.text("The archive was created, but its test failed or was cancelled. Check the log.")
                            status = language.text("Post-create Test Failed"); return
                        }
                    }
                    status = language.text("{0} · Done", title); success(result)
                }
                else { status = language.text("{0} · Exit code {1}", title, String(result.status)); error = language.text("Engine exit code {0}. Check stderr/stdout. If the password is wrong, enter it and reload.", String(result.status)) }
            } catch { self.error = language.message(error); status = language.text("Unable to Run") }
        }
    }
}
