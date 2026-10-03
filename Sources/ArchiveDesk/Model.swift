import SwiftUI
import AppKit
#if canImport(ArchiveCore)
import ArchiveCore
#endif

@MainActor final class Model: ObservableObject {
    let language = AppLanguage.shared
    @Published var archive: URL?
    @Published var entries: [ArchiveEntry] = [] { didSet { refreshVisible() } }
    @Published var selection: Set<String> = []
    @Published var filter = "" { didSet { refreshVisible() } }
    @Published var busy = false { didSet { if busy != oldValue { busy ? startMonitoring() : stopMonitoring() } } }
    @Published var status = AppLanguage.shared.text("Open an archive, or drop files to create one")
    @Published var stdout = ""
    @Published var stderr = ""
    @Published var progress: Double?
    @Published var engineTask: ArchiveTaskSnapshot?
    @Published var resourceSample = ResourceSample()
    @Published var taskPhase = "Preparing"
    @Published var currentTaskFile = ""
    private var monitorTask: Task<Void, Never>?
    private var monitorID = UUID()
    private var monitorLocation: URL?
    @Published var memoryMode = MemoryMode(rawValue: UserDefaults.standard.string(forKey: "memoryMode") ?? "adaptive") ?? .adaptive {
        didSet { UserDefaults.standard.set(memoryMode.rawValue, forKey: "memoryMode"); ArchiveResources.shared.configure(memoryMode) }
    }
    @Published var password = ""
    @Published var showCreate = false
    @Published var showExtraction = false
    @Published var extractionPolicy: ExtractionPolicy = .ask
    @Published var extractionNewFolder = true
    @Published var extractionOpenFolder = true
    @Published var editRefusal = "Open an archive first."
    private var extractionSelection: [String] = []
    var canEdit: Bool { archive != nil && editRefusal.isEmpty && !busy && !inspecting }
    @Published var inputs: [URL] = []
    @Published var error: String?
    @Published var recent: [URL] = (UserDefaults.standard.stringArray(forKey: "recentArchives") ?? []).map { URL(fileURLWithPath: $0) }
    @Published var directory = "" { didSet { refreshVisible() } }
    @Published var packageKind: PackageKind?
    @Published var packageReport: PackageReport?
    @Published var inspecting = false
    @Published var showPackage = false
    @Published var inspectionLog = ""
    private var inspectionTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private let inspectionRunner = CLIRunner()
    private var inspectionID = UUID()
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
    init() {
        ArchiveResources.shared.configure(memoryMode)
        runner.observe = { [weak self] snapshot in Task { @MainActor in
            guard let self, self.busy else { return }
            self.engineTask = snapshot
            if snapshot.state == .queued || snapshot.state == .running {
                self.progress = snapshot.fraction
                self.currentTaskFile = ""
                self.taskPhase = ["a": "Compressing", "x": "Extracting", "t": "Verifying", "l": "Reading archive", "lt": "Reading archive"][snapshot.operation] ?? "Processing"
            }
        } }
    }
    private func startMonitoring() {
        monitorTask?.cancel(); monitorID = UUID()
        let id = monitorID, engine = runner, location = monitorLocation ?? FileManager.default.temporaryDirectory
        resourceSample = ResourceSample(); engineTask = nil; progress = nil; taskPhase = "Preparing"; currentTaskFile = ""
        monitorTask = Task.detached(priority: .utility) { [weak self] in
            var sampler = ResourceSampler()
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                var counters = engine.resourceCounters()
                if let app = ResourceCounters.readProcess(getpid()) { counters["ArchiveDesk"] = app }
                let now = ProcessInfo.processInfo.systemUptime
                var sample = sampler.sample(counters, at: now); sample.elapsed = now - start
                if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: location.path) {
                    sample.capacity = (attrs[.systemSize] as? NSNumber)?.uint64Value
                    sample.free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value
                }
                await self?.acceptSample(sample, id: id)
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
            }
        }
    }
    private func acceptSample(_ sample: ResourceSample, id: UUID) { if busy && monitorID == id { resourceSample = sample } }
    private func stopMonitoring() { monitorTask?.cancel(); monitorTask = nil; monitorID = UUID(); monitorLocation = nil }
    @Published private(set) var visible: [ArchiveEntry] = []
    @Published private(set) var visibleTotal = 0
    private var allVisible: [ArchiveEntry] = []
    private var visibleID = UUID()
    private var visibleTask: Task<Void, Never>?
    private func refreshVisible() {
        visibleTask?.cancel()
        let id = UUID(); visibleID = id
        let source = entries, path = directory, query = filter
        visible = []; allVisible = []; visibleTotal = 0
        guard !source.isEmpty else { return }
        visibleTask = Task {
            let work = Task.detached(priority: .userInitiated) { ArchiveBrowser.children(source, directory: path, filter: query) }
            let rows = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, visibleID == id else { return }
            allVisible = rows; visibleTotal = rows.count; visible = Array(rows.prefix(2000))
        }
    }
    func showMoreRows() { visible = Array(allVisible.prefix(visible.count + 2000)) }
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
        cancelInspection(); packageKind = nil; packageReport = nil
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
            editRefusal = "Archive must be listed successfully before editing."
            entries = []; selection = []; directory = ""
            launch(language.text("Reading archive"), executable: executable(for: archive), args: args, secret: password, preparing: archive) { result in
                let parsed = result.archiveEntries(backend: .sevenZip)
                guard Set(parsed.map(\.path)).count == parsed.count else { self.error = self.language.text("Duplicate paths prevent reliable item selection."); return }
                self.entries = parsed
                self.editRefusal = self.password.isEmpty ? (ArchiveEditor.refusal(archive, listing: result.stdout) ?? "") : "Encrypted archives are read-only in this version."
                let kind = PackageInspector.kind(archive: archive, entries: parsed)
                if kind == .ipa || kind == .apk { self.editRefusal = "Application packages are read-only." }
                self.packageKind = kind == .ipa || kind == .apk || ["ipa", "apk"].contains(archive.pathExtension.lowercased()) ? kind : nil
                self.packageReport = nil
                self.status = self.language.text("{0} items · {1}", String(parsed.count), archive.lastPathComponent)
            }
        } catch { self.error = language.message(error) }
    }
    func cancelInspection() { inspectionTask?.cancel(); inspectionRunner.cancel(); inspectionID = UUID() }
    func cancelCurrentTask() { exportTask?.cancel(); runner.cancel() }
    func inspectPackage() {
        showPackage = true
        guard !inspecting, !busy, let archive, packageKind != nil else { return }
        packageReport = nil; inspectionLog = ""; inspecting = true
        let id = UUID(); inspectionID = id
        let engine = resolvedSevenZip, secret = password, engineRunner = inspectionRunner
        let rulesURL = Bundle.main.resourceURL?.appendingPathComponent("PackageRules/apk-packers.json")
        let rules = rulesURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([PackerRule].self, from: $0) } ?? []
        inspectionTask = Task {
            let work = Task.detached(priority: .utility) {
                try await PackageInspector.inspect(archive: archive, sevenZip: engine, password: secret, runner: engineRunner, rules: rules) { a, b in
                    Task { @MainActor in if self.inspectionID == id { self.inspectionLog = String((a + "\n" + b).suffix(100_000)) } }
                }
            }
            do {
                let report = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); engineRunner.cancel() })
                if inspectionID == id { packageReport = report }
            } catch {
                if inspectionID == id {
                    packageReport = PackageReport(kind: packageKind ?? .other, warnings: [error.localizedDescription])
                }
            }
            inspecting = false
        }
    }
    func extract(selected: Bool) {
        guard !busy else { return }
        guard archive != nil, !entries.isEmpty else { return }
        guard entries.allSatisfy({ ArchiveCommands.safePath($0.path) && !$0.isLink }) else { error = language.text("This archive contains unsafe paths or links. Extraction was refused; inspect it with a trusted tool."); return }
        let chosen = selected ? entries.filter { item in
            selection.contains(item.path) || selection.contains { item.path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") }
        }.map(\.path) : []
        guard !selected || !chosen.isEmpty else { return }
        // Preserve directory selections instead of expanding thousands of paths into argv.
        extractionSelection = selected ? Array(selection).sorted() : []; showExtraction = true
    }
    func performExtraction() {
        guard !busy, let archive else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = language.text("Choose Extraction Location")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = extractionNewFolder ? parent.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(8)), isDirectory: true) : parent
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveDesk-extract-" + UUID().uuidString)
        do {
            try ExtractionMerger.checkDirectory(parent)
            if extractionNewFolder { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            monitorLocation = destination
            showExtraction = false; busy = true; stdout = ""; stderr = ""; status = language.text("Extracting to {0}", destination.lastPathComponent)
            let source = session?.workingURL ?? archive, chosen = extractionSelection, secret = password, engine = resolvedSevenZip, engineRunner = runner
            let policy = extractionPolicy, openFolder = extractionOpenFolder
            let mobile = packageKind != nil
            exportTask = Task {
                defer { busy = false; progress = nil; try? FileManager.default.removeItem(at: stage) }
                do {
                    let work = Task.detached(priority: .userInitiated) {
                        let log: (String, String) -> Void = { a, b in
                            Task { @MainActor in self.stdout = String(a.suffix(100_000)); self.stderr = String(b.suffix(100_000)) }
                        }
                        if mobile {
                            _ = try await PackageExporter.extract(archive: source, destination: stage, selected: chosen, sevenZip: engine, password: secret, runner: engineRunner, update: log)
                        } else {
                            // Keep multi-volume siblings available to the ordinary engine.
                            let listed = try await engineRunner.run(executable: engine, arguments: ArchiveCommands.list(source, password: secret, using: .sevenZip), password: secret, update: log)
                            guard !listed.cancelled, listed.status == 0 else { throw ArchiveError.invalid("Reading the archive failed. Check the task log.") }
                            let rows = listed.archiveEntries(backend: .sevenZip)
                            let compressed = UInt64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            _ = try ExtractionSafety.validate(rows, compressedBytes: compressed)
                            let selectedRows = chosen.isEmpty ? rows : rows.filter { row in chosen.contains { row.path == $0 || row.path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") } }
                            let estimated = try ExtractionSafety.validate(selectedRows)
                            try DiskSpace.requireStaging(estimated, stage: stage, destination: destination)
                            try Task.checkCancellation()
                            let extracted = try await engineRunner.run(executable: engine, arguments: ArchiveCommands.extract(source, destination: stage, selected: chosen, password: secret, using: .sevenZip), password: secret, diskGuard: stage, update: log)
                            guard !extracted.cancelled, extracted.status == 0 else { throw ArchiveError.invalid("Extraction failed. Check the task log. The destination was not changed.") }
                        }
                        await self.updateTaskPhase("Publishing files", fraction: nil)
                        return try await ExtractionMerger.merge(from: stage, to: destination, policy: policy, conflict: { path in
                            await self.askConflict(path)
                        }) { report in Task { @MainActor in
                            guard self.busy else { return }
                            self.status = self.extractionSummary(report)
                            self.updateTaskPhase("Publishing files", fraction: report.fraction)
                            self.currentTaskFile = report.currentFile
                        } }
                    }
                    let report = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); engineRunner.cancel() })
                    status = extractionSummary(report)
                    if openFolder { NSWorkspace.shared.open(destination) }
                } catch { self.error = language.message(error); status = language.text("Export incomplete. Partial files may remain in the destination.") }
            }
        } catch { self.error = language.message(error) }
    }
    private func extractionSummary(_ report: ExtractionReport) -> String {
        language.text("Written: {0} · Skipped: {1} · Renamed: {2} · Backups: {3}", String(report.written), String(report.skipped), String(report.renamed), String(report.backups))
    }
    private func updateTaskPhase(_ phase: String, fraction: Double?) { guard busy else { return }; taskPhase = phase; progress = fraction }
    private func askConflict(_ path: String) async -> ConflictChoice {
        let alert = NSAlert(); alert.messageText = language.text("File already exists")
        alert.informativeText = path + "\n" + language.text("Replacing keeps a backup beside the existing file.")
        for title in ["Skip", "Replace", "Rename", "Cancel Task"] { alert.addButton(withTitle: language.text(title)) }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return .cancel }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .skip)
                case .alertSecondButtonReturn: continuation.resume(returning: .replace)
                case .alertThirdButtonReturn: continuation.resume(returning: .rename)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }
    func addToArchive() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        editArchive(.add(panel.urls), detail: language.text("Selected files are added at the archive root. Matching paths will be replaced."))
    }
    func deleteFromArchive() {
        guard canEdit, !selection.isEmpty else { return }
        editArchive(.delete(Array(selection)), detail: language.text("Delete selected items and their contents from this archive?") + "\n" + selection.sorted().joined(separator: "\n"))
    }
    func renameInArchive() {
        guard canEdit, let item = selectedEntry, !item.isDirectory else { return }
        let alert = NSAlert(); alert.messageText = language.text("Rename in Archive")
        let input = NSTextField(string: item.name); input.frame = NSRect(x: 0, y: 0, width: 340, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: language.text("Continue")); alert.addButton(withTitle: language.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try ArchiveEditor.renameDestination(item.path, name: input.stringValue, entries: entries) }
        catch { self.error = language.message(error); return }
        editArchive(.rename(item.path, input.stringValue), detail: item.path + " → " + input.stringValue)
    }
    private func editArchive(_ edit: ArchiveEdit, detail: String) {
        guard canEdit, let archive else { return }
        if archive.pathExtension.lowercased() == "rar" && !requireRAR() { return }
        let alert = NSAlert(); alert.messageText = language.text("Modify this archive?")
        alert.informativeText = detail + "\n\n" + language.text("A copy is modified and tested first. The original is kept as an ArchiveDesk-backup file before replacement. This needs extra disk space.")
        alert.addButton(withTitle: language.text("Continue")); alert.addButton(withTitle: language.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelInspection(); busy = true; stdout = ""; stderr = ""; status = language.text("Editing archive copy")
        let engine = resolvedSevenZip, rarEngine = rar, engineRunner = runner
        exportTask = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try await ArchiveEditor.apply(edit, archive: archive, sevenZip: engine, rar: rarEngine, runner: engineRunner) { a, b in
                        Task { @MainActor in self.stdout = String(a.suffix(100_000)); self.stderr = String(b.suffix(100_000)) }
                    }
                }
                let backup = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); engineRunner.cancel() })
                busy = false; browse()
                let done = NSAlert(); done.messageText = language.text("Archive updated")
                done.informativeText = language.text("Original backup: {0}", backup.path); done.addButton(withTitle: language.text("OK"))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { done.beginSheetModal(for: window) { _ in } }
            } catch { busy = false; self.error = language.message(error); status = language.text("Editing stopped. The original archive was not replaced.") }
        }
    }
    private func exportPackage(_ archive: URL, to destination: URL, selected: [String]) {
        busy = true; progress = nil; stdout = ""; stderr = ""; status = language.text("Exporting Package")
        let engine = resolvedSevenZip, secret = password, engineRunner = runner
        exportTask = Task {
            defer { busy = false; progress = nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    try await PackageExporter.extract(archive: archive, destination: destination, selected: selected, sevenZip: engine, password: secret, runner: engineRunner) { a, b in
                        Task { @MainActor in self.stdout = String(a.suffix(100_000)); self.stderr = String(b.suffix(100_000)) }
                    }
                }
                let renamed = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); engineRunner.cancel() })
                status = renamed == 0 ? language.text("Package Export Complete") : language.text("Export complete. Conflicting names were renamed; see the path-map JSON.")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.error = language.text(error.localizedDescription)
                status = language.text("Export incomplete. Partial files may remain in the destination.")
            }
        }
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
        do {
            _ = try ArchiveCommands.create(output: selectedOutput, inputs: inputs, password: secret, headers: headers, volumeMB: volume, recovery: recovery, options: options)
            let engine = options.format == .rar ? rar : resolvedSevenZip, source = inputs, engineRunner = runner
            monitorLocation = selectedOutput.deletingLastPathComponent()
            showCreate = false; busy = true; stdout = ""; stderr = ""; status = language.text("Create Archive")
            exportTask = Task {
                defer { busy = false; progress = nil }
                do {
                    let work = Task.detached(priority: .userInitiated) {
                        try await ArchiveCreator.create(output: selectedOutput, inputs: source, password: secret, headers: headers, volumeMB: volume, recovery: recovery, options: options, executable: engine, runner: engineRunner, phase: { phase, fraction in
                            Task { @MainActor in self.updateTaskPhase(phase, fraction: fraction) }
                        }) { a, b in Task { @MainActor in self.stdout = String(a.suffix(100_000)); self.stderr = String(b.suffix(100_000)) } }
                    }
                    let output = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel(); engineRunner.cancel() })
                    status = language.text("{0} · Done", language.text("Create Archive"))
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } catch is CancellationError { status = language.text("Cancelled. No unfinished archive was published.") }
                catch { self.error = language.message(error); status = language.text("Creation failed. No unfinished archive was published.") }
            }
        } catch { self.error = language.message(error) }
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
        exportTask = Task {
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
