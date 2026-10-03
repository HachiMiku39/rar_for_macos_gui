import SwiftUI
import UniformTypeIdentifiers
#if canImport(ArchiveCore)
import ArchiveCore
#endif

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @State private var showLog = false
    private var splitView: some View {
        NavigationSplitView {
            sidebar.disabled(model.busy).navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.tint)
                    Text(model.archive?.path ?? "ArchiveDesk").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Text(language.text("{0} items", String(model.entries.count))).foregroundStyle(.secondary)
                }.padding(12)
                if model.archive != nil { navigationBar }
                if model.archive != nil && !model.editRefusal.isEmpty {
                    Text(language.text(model.editRefusal)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                }
                if let kind = model.packageKind {
                    HStack {
                        Label(language.text(kind.rawValue), systemImage: kind == .ipa ? "iphone" : "apps.iphone")
                        Text(language.text("Read-only package · Extraction does not remove protection")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(language.text(model.inspecting ? "Inspection in progress…" : "Inspect Package")) { model.inspectPackage() }.disabled(model.busy)
                    }.padding(.horizontal, 14).padding(.bottom, 8)
                    if kind != .ipa && kind != .apk {
                        Text(language.text("Package structure does not match IPA or APK. It can still be browsed as an archive.")).font(.caption).foregroundStyle(.orange).padding(.horizontal, 14)
                    }
                }
                if model.archive == nil {
                    ContentUnavailableView {
                        Label(language.text("Archives, neatly organized"), systemImage: "archivebox")
                    } description: {
                        Text(language.text("Built-in extraction for RAR, ZIP, 7z, TAR, ISO and more.\nDrop files or folders to create RAR5, ZIP or 7z."))
                    } actions: {
                        Button(language.text("Open Archive…")) { model.chooseArchive() }.buttonStyle(.borderedProminent)
                        SettingsLink { Text(language.text("Engines & Settings")) }
                    }.frame(maxHeight: .infinity)
                } else {
                    entryTable
                    if model.visible.count < model.visibleTotal {
                        Button(language.text("Show more items ({0} of {1})", String(model.visible.count), String(model.visibleTotal))) { model.showMoreRows() }.padding(6)
                    }
                }
                Divider()
                HStack {
                    SecureField(language.text("Archive password (this session only)"), text: $model.password).frame(maxWidth: 280)
                    Button(language.text("Reload")) { model.browse() }.disabled(model.archive == nil)
                    Button(language.text("Clear Password")) { model.password = "" }
                    Spacer()
                    Toggle(language.text("Task Log"), isOn: $showLog).toggleStyle(.checkbox)
                }.padding(10).archiveGlass().padding(.horizontal, 10).disabled(model.busy)
                if showLog {
                    HSplitView {
                        logPane(language.text("Standard output · stdout"), text: model.stdout)
                        logPane(language.text("Error output · stderr"), text: model.stderr)
                    }.frame(height: 170)
                }
                if model.busy { taskMonitor }
                statusBar
            }
        }
    }
    var body: some View {
        splitView.navigationTitle(model.archive?.lastPathComponent ?? "ArchiveDesk")
        .searchable(text: $model.filter, prompt: language.text("Filter paths"))
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseArchive() } label: { Label(language.text("Open"), systemImage: "folder") }
                Button { model.chooseInputs() } label: { Label(language.text("Create"), systemImage: "plus.square") }
                Button { model.extract(selected: false) } label: { Label(language.text("Extract All"), systemImage: "tray.and.arrow.down") }.disabled(model.entries.isEmpty)
                Button { model.extract(selected: true) } label: { Label(language.text("Extract Selected"), systemImage: "checklist") }.disabled(model.selection.isEmpty)
                Button { model.test() } label: { Label(language.text("Test"), systemImage: "checkmark.shield") }.disabled(model.archive == nil)
                Menu {
                    Button(language.text("Add to Archive…")) { model.addToArchive() }
                    Button(language.text("Delete from Archive…")) { model.deleteFromArchive() }.disabled(model.selection.isEmpty)
                    Button(language.text("Rename in Archive…")) { model.renameInArchive() }.disabled(model.selectedEntry == nil || model.selectedEntry?.isDirectory == true)
                } label: { Label(language.text("Edit Archive"), systemImage: "square.and.pencil") }.disabled(!model.canEdit)
                Menu {
                    Button(language.text("Add 3% Recovery Record…")) { model.recovery("rr3p") }
                    Button(language.text("Create 10% Recovery Volumes…")) { model.recovery("rv10p") }
                } label: { Label(language.text("Recovery Data"), systemImage: "cross.case") }.disabled(model.archive?.pathExtension.lowercased() != "rar")
            }
            ToolbarItem {
                Button { model.archiveInfo() } label: { Label(language.text("Archive Information"), systemImage: "info.circle") }.disabled(model.archive == nil || model.busy)
            }
            ToolbarItem {
                Menu {
                    Picker(language.text("Appearance"), selection: $model.appearance) {
                        Text(language.text("System Default")).tag("system")
                        Text(language.text("Light")).tag("light")
                        Text(language.text("Dark")).tag("dark")
                    }
                } label: { Label(language.text("Appearance"), systemImage: "circle.lefthalf.filled") }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in guard !model.busy else { return false }; model.receive(urls); return true }
        .sheet(isPresented: $model.showCreate) { CreateView().environmentObject(model) }
        .sheet(isPresented: $model.showExtraction) { ExtractionOptionsView().environmentObject(model).environmentObject(language) }
        .sheet(isPresented: $model.showPackage) { PackageInspectionView().environmentObject(model).environmentObject(language) }
        .alert(language.text("Operation Unsuccessful"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(language.text("OK")) { model.error = nil } } message: { Text(language.text(model.error ?? "")) }
        .frame(minWidth: 900, minHeight: 600)
    }
    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.directory.isEmpty).help(language.text("Up One Level"))
            Button { model.navigate("") } label: { Image(systemName: "house") }.help(language.text("Archive Root"))
            Text(model.directory.isEmpty ? language.text("Archive Root") : model.directory)
                .lineLimit(1).truncationMode(.middle).font(.callout)
            Spacer()
            Text(language.text("{0} items", String(model.visible.count))).font(.caption).foregroundStyle(.secondary)
            Button(language.text("Open Selected Item")) { if let item = model.selectedEntry { model.activate(item) } }
                .disabled(model.selectedEntry == nil || (model.selectedEntry?.category == "Archive"))
        }.padding(10).archiveGlass().padding(.horizontal, 10).padding(.bottom, 8).disabled(model.busy)
    }
    private var statusBar: some View {
        HStack {
            Text(language.text(model.status)).font(.caption).lineLimit(2)
            if let task = model.engineTask, model.busy, task.state == .running {
                Text(language.text(task.state.rawValue)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { Button(language.text("Cancel Task")) { model.cancelCurrentTask() } }
        }.padding(10).background(.bar)
    }
    private func byteText(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
    }
    private func rateText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return byteText(UInt64(min(value, Double(Int64.max / 2)))) + "/s"
    }
    private var taskMonitor: some View {
        let sample = model.resourceSample
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text(model.taskPhase), systemImage: "chart.bar.xaxis")
                Spacer()
                Text(language.text("Elapsed: {0}", String(format: "%02d:%02d", Int(sample.elapsed) / 60, Int(sample.elapsed) % 60)))
                Text(model.progress.map { String(format: "%.0f%%", $0 * 100) } ?? language.text("Indeterminate"))
                    .frame(minWidth: 90, alignment: .trailing)
            }.font(.callout).monospacedDigit()
            if let value = model.progress { ProgressView(value: value).accessibilityLabel(language.text("Current phase progress")) }
            else { ProgressView().progressViewStyle(.linear).accessibilityLabel(language.text("Indeterminate")) }
            HStack(spacing: 24) {
                metric("CPU", sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", "cpu")
                metric("RAM", byteText(sample.memory), "memorychip")
                metric("Disk read", rateText(sample.readPerSecond), "arrow.down.circle")
                metric("Disk write", rateText(sample.writePerSecond), "arrow.up.circle")
                Spacer(minLength: 0)
            }
            if let total = sample.capacity, let free = sample.free, total > 0 {
                HStack {
                    Label(language.text("Destination volume"), systemImage: "externaldrive")
                    Text(language.text("Used: {0} · Free: {1}", byteText(total - min(free, total)), byteText(free)))
                    Spacer()
                    Text(String(format: "%.1f%%", Double(total - min(free, total)) / Double(total) * 100)).monospacedDigit()
                }.font(.caption)
            } else { Text(language.text("Destination volume: unavailable")).font(.caption) }
            if !model.currentTaskFile.isEmpty { Text(model.currentTaskFile).font(.caption).lineLimit(1).truncationMode(.middle) }
            Text(language.text("Current phase only. CPU/RAM/I/O: ArchiveDesk + active engine; 100% CPU = one core. I/O is sampled process disk traffic, not device utilization; cached reads may be zero. — means unavailable."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).archiveGlass().padding(.horizontal, 10).padding(.top, 8)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(language.text(title), systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).monospacedDigit()
        }.frame(minWidth: 100, alignment: .leading)
    }
    private var entryTable: some View {
        Table(model.visible, selection: $model.selection) {
            TableColumn(language.text("Name / Path")) { (item: ArchiveEntry) in
                HStack(spacing: 9) {
                    Image(systemName: item.symbol).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.isDirectory ? Color.accentColor : item.category == "Image" ? .pink : item.category == "Video" ? .purple : item.category == "Audio" ? .orange : .secondary)
                        .frame(width: 22)
                    Text(model.filter.isEmpty ? item.name : item.path).lineLimit(1)
                }.help(item.category == "Archive" ? language.text("Opening nested archives is not supported yet.") : item.path)
            }.width(min: 220)
            TableColumn(language.text("Kind")) { (item: ArchiveEntry) in
                Text(item.isDirectory || item.suffix.isEmpty ? language.text(item.category) : item.suffix.uppercased() + " · " + language.text(item.category))
                    .foregroundStyle(.secondary)
            }.width(min: 105, ideal: 140)
            TableColumn(language.text("Size"), value: \ArchiveEntry.size).width(90)
            TableColumn(language.text("Modified"), value: \ArchiveEntry.modified).width(170)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(language.text("Open Selected Item")) {
                if let item = model.visible.first(where: { ids.contains($0.id) }) { model.activate(item) }
            }.disabled(ids.count != 1 || model.busy || model.visible.contains { ids.contains($0.id) && $0.category == "Archive" })
            Button(language.text("Extract Selected…")) { model.selection = ids; model.extract(selected: true) }.disabled(ids.isEmpty || model.busy)
            Divider()
            Button(language.text("Delete from Archive…")) { model.selection = ids; model.deleteFromArchive() }.disabled(!model.canEdit || ids.isEmpty)
            Button(language.text("Rename in Archive…")) { model.selection = ids; model.renameInArchive() }.disabled(!model.canEdit || ids.count != 1 || model.visible.contains { ids.contains($0.id) && $0.isDirectory })
        } primaryAction: { ids in
            if ids.count == 1, let item = model.visible.first(where: { ids.contains($0.id) }) { model.activate(item) }
        }
        .onKeyPress(.return) {
            guard let item = model.selectedEntry else { return .ignored }
            model.activate(item); return .handled
        }
    }
    private var sidebar: some View {
        List {
            Section(language.text("Workspace")) {
                Label(language.text("Archive Browser"), systemImage: "archivebox")
                Button(language.text("Create Archive")) { model.chooseInputs() }
                SettingsLink { Label(language.text("Engine Settings"), systemImage: "gearshape") }
            }
            Section(language.text("Recent Archives")) {
                Button { model.clearRecent() } label: { Label(language.text("Clear History"), systemImage: "clock.badge.xmark") }
                    .disabled(model.recent.isEmpty && NSDocumentController.shared.recentDocumentURLs.isEmpty)
                ForEach(model.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }.help(url.path)
                }
            }
            Section(language.text("Supported Formats")) {
                Text(language.text("7-Zip 26.03 included"))
                Text("IPA · APK")
                Text("RAR · ZIP · 7z · TAR · ISO")
                Text("CAB · ARJ · LZH · GZ · UUE…")
            }.foregroundStyle(.secondary).font(.caption)
        }
    }
    func logPane(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) { Text(text.isEmpty ? "—" : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(10).frame(minWidth: 180, maxWidth: .infinity)
    }
}

struct ExtractionOptionsView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(language.text("Extraction Options")).font(.title2)
            Toggle(language.text("Create a new subfolder"), isOn: $model.extractionNewFolder)
            Picker(language.text("When files already exist"), selection: $model.extractionPolicy) {
                ForEach(ExtractionPolicy.allCases, id: \.self) { Text(language.text($0.rawValue)).tag($0) }
            }.disabled(model.extractionNewFolder)
            Text(language.text("Update mode adds missing files and replaces existing files only when the extracted copy is newer. Replaced files are kept as backups. Folder/file conflicts and links are refused.")).font(.caption).foregroundStyle(.secondary)
            Toggle(language.text("Open destination after extraction"), isOn: $model.extractionOpenFolder)
            Text(language.text("Files are staged and checked by the engine before publication (CRC where available). Cancellation keeps completed files but removes the current partial file. General archives are limited by disk space and index memory; package inspection has separate limits.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(language.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(language.text("Choose Extraction Location")) { model.performExtraction() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530)
    }
}

struct PackageInspectionView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(language.text("Package Inspection"), systemImage: "shippingbox").font(.title2)
                Spacer()
                if model.inspecting { ProgressView().controlSize(.small); Button(language.text("Cancel Task")) { model.cancelInspection() } }
                Button(language.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(model.archive?.lastPathComponent ?? "").foregroundStyle(.secondary)
            Text(language.text("Inspection uses a temporary copy and never runs package code. You can close this panel and continue browsing.")).font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report = model.packageReport {
                        Text(language.text(report.kind.rawValue)).font(.headline)
                        ForEach(report.fields) { field in
                            HStack(alignment: .top) { Text(language.text(field.label)).foregroundStyle(.secondary).frame(width: 190, alignment: .leading); Text(language.text(field.value)).textSelection(.enabled); Spacer() }
                        }
                        Divider()
                        Text(language.text("Protection") + ": " + language.text(report.protection)).font(.headline)
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in Text(language.text(warning)).foregroundStyle(.orange).textSelection(.enabled) }
                        ForEach(Array(report.evidence.enumerated()), id: \.offset) { _, evidence in Text(evidence).font(.caption.monospaced()).textSelection(.enabled) }
                        ForEach(report.slices) { slice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(slice.path).font(.caption.monospaced()).textSelection(.enabled)
                                Text(slice.architecture + " · " + language.text(slice.state))
                                if let cryptid = slice.cryptid { Text("cryptid=\(cryptid) · cryptoff=\(slice.cryptoff ?? 0) · cryptsize=\(slice.cryptsize ?? 0)").font(.caption).foregroundStyle(.secondary) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else { Text(language.text(model.inspecting ? "Reading metadata and protection markers…" : "Inspection cancelled. You can retry.")) }
                    DisclosureGroup(language.text("Task Log")) { Text(model.inspectionLog).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(language.text("Scan Again")) { model.inspectPackage() }.disabled(model.inspecting || model.busy)
        }.padding(24).frame(width: 740, height: 640)
    }
}

struct CreateView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var headers = true
    @State private var volume = "0"
    @State private var recovery = 0
    @State private var options = Self.savedProfile()
    @State private var profileSaved = false
    @State private var section = 0
    private static func savedProfile() -> CreationOptions {
        guard let data = UserDefaults.standard.data(forKey: "creationProfileV1"),
              let value = try? JSONDecoder().decode(CreationOptions.self, from: data),
              (try? value.validatedPatterns()) != nil else { return CreationOptions() }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(language.text("Create Archive"), systemImage: "archivebox.fill").font(.title2)
                Spacer()
                Button(language.text("Reset Options")) { options = CreationOptions(); profileSaved = false }
                Button(language.text("Save as Default Profile")) {
                    if (try? options.validatedPatterns()) != nil, let data = try? JSONEncoder().encode(options) {
                        UserDefaults.standard.set(data, forKey: "creationProfileV1"); profileSaved = true
                    }
                }.disabled((try? options.validatedPatterns()) == nil)
            }
            Text(language.text("{0} source items · Folder structure preserved", String(model.inputs.count))).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading) { ForEach(model.inputs, id: \.self) { Text($0.path).font(.caption).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 50)
            Picker("", selection: $section) {
                Text(language.text("General")).tag(0)
                Text(language.text("Security & Recovery")).tag(1)
                Text(language.text("File")).tag(2)
                Text(language.text("Advanced & Times")).tag(3)
            }.pickerStyle(.segmented)
            Group {
                switch section {
                case 0:
                Form {
                    Picker(language.text("Archive Format"), selection: $options.format) {
                        ForEach(CreationFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker(language.text("Compression Level"), selection: $options.level) {
                        ForEach(Array(["Store Only", "Fastest", "Fast", "Normal", "Good", "Best"].enumerated()), id: \.offset) { i, key in Text(language.text(key)).tag(i) }
                    }
                    Toggle(language.text("Solid Archive"), isOn: $options.solid).disabled(options.format == .zip)
                    Picker(language.text("RAR Dictionary Size"), selection: $options.dictionaryMB) {
                        ForEach([4,8,16,32,64,128,256], id: \.self) { Text("\($0) MB").tag($0) }
                    }.disabled(options.format != .rar)
                    TextField(language.text("Volume size (MB; 0 = single archive)"), text: $volume)
                    Toggle(language.text("Test After Archiving"), isOn: $options.testAfter)
                    Text(language.text("Solid mode can improve compression of similar files, but single-file extraction may be slower. Volumes use a new separate folder.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                case 1:
                Form {
                    SecureField(language.text("Password (optional)"), text: $password)
                    SecureField(language.text("Confirm password"), text: $confirmation)
                    Toggle(language.text("Encrypt file names"), isOn: $headers).disabled(password.isEmpty || options.format == .zip)
                    Text(language.text("ZIP uses AES-256 but cannot encrypt filenames; some system extractors do not support it. RAR5 / 7z support filename encryption.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker(language.text("Recovery record"), selection: $recovery) {
                        Text(language.text("None")).tag(0); Text("3%").tag(3); Text("5%").tag(5); Text("10%").tag(10)
                    }.disabled(options.format != .rar)
                    Toggle(language.text("BLAKE2 File Checksums"), isOn: $options.blake2).disabled(options.format != .rar)
                }
                case 2:
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("Exclude Patterns (one per line)"))
                    TextEditor(text: $options.exclusions).font(.system(.body, design: .monospaced))
                        .accessibilityLabel(language.text("Exclude Patterns (one per line)")).border(.secondary.opacity(0.3))
                    Text(language.text("Examples: *.tmp or *.DS_Store. Supports * and ?. No absolute paths, .. or @ list files.")).font(.caption).foregroundStyle(.secondary)
                    Toggle(language.text("Store Already-compressed Types (RAR)"), isOn: $options.storeCompressed).disabled(options.format != .rar)
                }.padding(18)
                default:
                Form {
                    Picker(language.text("Thread Limit"), selection: $options.threads) {
                        Text(language.text("Automatic")).tag(0)
                        ForEach([1,2,4,8,16,32,64], id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker(language.text("Quick Open Information (RAR)"), selection: $options.quickOpen) {
                        Text(language.text("Automatic")).tag(0); Text(language.text("Do Not Add")).tag(1); Text(language.text("All Files")).tag(2)
                    }.disabled(options.format != .rar)
                    Section(language.text("RAR File Times")) {
                        Toggle(language.text("Store Modification Time"), isOn: $options.modifiedTime)
                        Toggle(language.text("Store Access Time"), isOn: $options.accessTime)
                        Toggle(language.text("High-precision Times"), isOn: $options.highPrecision)
                    }.disabled(options.format != .rar)
                    Text(language.text("On macOS, ctime means status-change time, not creation time. The Windows creation-time switch is omitted. ZIP / 7z use engine defaults.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                }
            }.formStyle(.grouped).frame(width: 612, height: 340)
            Text(language.text(profileSaved ? "Profile saved (without passwords, source paths, volume size or recovery ratio)." : "Passwords stay in memory. Creates new archives only; never replaces archives or deletes source files."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(language.text("Cancel")) { dismiss() }
                Button(language.text("Choose Save Location…")) {
                    model.create(password: password, headers: headers, volume: Int(volume) ?? -1, recovery: options.format == .rar ? recovery : 0, options: options)
                }.buttonStyle(.borderedProminent)
                    .disabled(password != confirmation || !(0...1_000_000).contains(Int(volume) ?? -1) || model.inputs.isEmpty || (try? options.validatedPatterns()) == nil)
            }
        }.frame(width: 612).padding(24)
            .onDisappear { password = ""; confirmation = "" }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        Form {
            Picker(language.text("Appearance"), selection: $model.appearance) {
                Text(language.text("System Default")).tag("system")
                Text(language.text("Light")).tag("light")
                Text(language.text("Dark")).tag("dark")
            }
            Picker(language.text("Language"), selection: $language.selected) {
                Text(language.text("System Default")).tag("system")
                ForEach(language.packs) { pack in Text(pack.name).tag(pack.id) }
            }
            HStack {
                Button(language.text("Import Language Pack…")) { language.importPack() }
                Button(language.text("Localization Demo")) { language.showDemo() }
            }
            Text(language.text("Language packs contain text only; missing entries fall back to English. System dialogs and raw CLI logs may use the system or tool language.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker(language.text("Memory Usage"), selection: $model.memoryMode) {
                ForEach(MemoryMode.allCases, id: \.self) { Text(language.text($0.rawValue)).tag($0) }
            }
            Text(language.text("Budgets are ceilings, not preallocated RAM. Critical memory pressure or low disk space stops the task safely.")).font(.caption).foregroundStyle(.secondary)
            Text(language.text("Archive Engines")).font(.title2)
            Text(language.text("7-Zip is included for browsing, extraction and testing. RAR creation and recovery require a separately licensed RARLAB tool.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.sevenZip.isEmpty ? language.text("Using the built-in extraction engine") : language.text("Using a custom extraction engine"))
                Button(language.text("Check Engine")) { model.check(model.resolvedSevenZip) }
                Button(language.text("Use Built-in")) { model.sevenZip = ""; model.savePaths() }
            }
            pathRow(language.text("RAR (creation and recovery)"), path: $model.rar)
            HStack {
                Link(language.text("Download RAR for macOS…"), destination: URL(string: "https://www.rarlab.com/download.htm")!)
                Link(language.text("RAR License"), destination: URL(string: "https://www.rarlab.com/license.htm")!)
            }
            Text(language.text("Choose macOS ARM (Apple Silicon) or x64 (Intel) on the download page. Unpack it, then select the rar executable above.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            pathRow(language.text("Optional custom 7zz path (blank = built-in)"), path: $model.sevenZip)
            Button(language.text("Third-party Licenses & Source")) { if let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty") { NSWorkspace.shared.open(url) } }
            Text(language.text(model.status)).font(.caption)
            Link(language.text("RARLAB Downloads & License"), destination: URL(string: "https://www.rarlab.com/download.htm")!)
        }.padding(24).frame(width: 700).disabled(model.busy).onDisappear { model.savePaths() }
        .alert(language.text("Operation Unsuccessful"), isPresented: Binding(get: { language.importError != nil }, set: { if !$0 { language.importError = nil } })) { Button("OK") { language.importError = nil } } message: { Text(language.importError ?? "") }
    }
    func pathRow(_ title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            HStack {
                TextField(language.text("Absolute path"), text: path).textFieldStyle(.roundedBorder)
                Button(language.text("Choose…")) { let p = NSOpenPanel(); p.canChooseDirectories = false; if p.runModal() == .OK, let url = p.url { path.wrappedValue = url.path; model.savePaths() } }
                Button(language.text("Check")) { model.check(path.wrappedValue) }
                Image(systemName: FileManager.default.isExecutableFile(atPath: path.wrappedValue) ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(FileManager.default.isExecutableFile(atPath: path.wrappedValue) ? .green : .orange)
            }
        }
    }
}

private extension View {
    @ViewBuilder func archiveGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
