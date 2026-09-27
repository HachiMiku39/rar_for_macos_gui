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
                    Text(language.text("{0} 个条目", String(model.entries.count))).foregroundStyle(.secondary)
                }.padding(12)
                if model.archive != nil { navigationBar }
                if model.archive == nil {
                    ContentUnavailableView {
                        Label(language.text("压缩文件，有条有理"), systemImage: "archivebox")
                    } description: {
                        Text(language.text("内置解压引擎，支持 RAR、ZIP、7z、TAR、ISO 等格式。\n拖入普通文件或文件夹，创建新的 RAR5。"))
                    } actions: {
                        Button(language.text("打开压缩包…")) { model.chooseArchive() }.buttonStyle(.borderedProminent)
                        SettingsLink { Text(language.text("引擎与高级设置")) }
                    }.frame(maxHeight: .infinity)
                } else {
                    entryTable
                }
                Divider()
                HStack {
                    SecureField(language.text("压缩包密码（仅本次会话）"), text: $model.password).frame(maxWidth: 280)
                    Button(language.text("重新读取")) { model.browse() }.disabled(model.archive == nil)
                    Button(language.text("清除密码")) { model.password = "" }
                    Spacer()
                    Toggle(language.text("任务日志"), isOn: $showLog).toggleStyle(.checkbox)
                }.padding(10).archiveGlass().padding(.horizontal, 10).disabled(model.busy)
                if showLog {
                    HSplitView {
                        logPane(language.text("标准输出 stdout"), text: model.stdout)
                        logPane(language.text("错误输出 stderr"), text: model.stderr)
                    }.frame(height: 170)
                }
                statusBar
            }
        }
    }
    var body: some View {
        splitView.navigationTitle(model.archive?.lastPathComponent ?? "ArchiveDesk")
        .searchable(text: $model.filter, prompt: language.text("筛选路径"))
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseArchive() } label: { Label(language.text("打开"), systemImage: "folder") }
                Button { model.chooseInputs() } label: { Label(language.text("创建"), systemImage: "plus.square") }
                Button { model.extract(selected: false) } label: { Label(language.text("解压全部"), systemImage: "tray.and.arrow.down") }.disabled(model.entries.isEmpty)
                Button { model.extract(selected: true) } label: { Label(language.text("解压选中"), systemImage: "checklist") }.disabled(model.selection.isEmpty)
                Button { model.test() } label: { Label(language.text("测试"), systemImage: "checkmark.shield") }.disabled(model.archive == nil)
                Menu {
                    Button(language.text("添加 3% Recovery Record…")) { model.recovery("rr3p") }
                    Button(language.text("创建 10% Recovery Volumes…")) { model.recovery("rv10p") }
                } label: { Label(language.text("恢复数据"), systemImage: "cross.case") }.disabled(model.archive?.pathExtension.lowercased() != "rar")
            }
            ToolbarItem {
                Menu {
                    Picker(language.text("外观"), selection: $model.appearance) {
                        Text(language.text("跟随系统")).tag("system")
                        Text(language.text("日间模式")).tag("light")
                        Text(language.text("夜间模式")).tag("dark")
                    }
                } label: { Label(language.text("外观"), systemImage: "circle.lefthalf.filled") }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in guard !model.busy else { return false }; model.receive(urls); return true }
        .sheet(isPresented: $model.showCreate) { CreateView().environmentObject(model) }
        .alert(language.text("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(language.text("好")) { model.error = nil } } message: { Text(language.text(model.error ?? "")) }
        .frame(minWidth: 900, minHeight: 600)
    }
    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.directory.isEmpty).help(language.text("上一级"))
            Button { model.navigate("") } label: { Image(systemName: "house") }.help(language.text("根目录"))
            Text(model.directory.isEmpty ? language.text("根目录") : model.directory)
                .lineLimit(1).truncationMode(.middle).font(.callout)
            Spacer()
            Text(language.text("{0} 个条目", String(model.visible.count))).font(.caption).foregroundStyle(.secondary)
            Button(language.text("打开选中项")) { if let item = model.selectedEntry { model.activate(item) } }
                .disabled(model.selectedEntry == nil || (model.selectedEntry?.category == "压缩包"))
        }.padding(10).archiveGlass().padding(.horizontal, 10).padding(.bottom, 8).disabled(model.busy)
    }
    private var statusBar: some View {
        HStack {
            if model.busy {
                if let progress = model.progress { ProgressView(value: progress).frame(width: 100) }
                else { ProgressView().controlSize(.small) }
            }
            Text(language.text(model.status)).font(.caption).lineLimit(2)
            Spacer()
            if model.busy { Button(language.text("取消任务")) { model.runner.cancel() } }
        }.padding(10).background(.bar)
    }
    private var entryTable: some View {
        Table(model.visible, selection: $model.selection) {
            TableColumn(language.text("名称 / 路径")) { (item: ArchiveEntry) in
                HStack(spacing: 9) {
                    Image(systemName: item.symbol).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(item.isDirectory ? Color.accentColor : item.category == "图片" ? .pink : item.category == "视频" ? .purple : item.category == "音频" ? .orange : .secondary)
                        .frame(width: 22)
                    Text(model.filter.isEmpty ? item.name : item.path).lineLimit(1)
                }.help(item.category == "压缩包" ? language.text("暂不支持打开压缩包内的压缩包。") : item.path)
            }.width(min: 220)
            TableColumn(language.text("文件类型")) { (item: ArchiveEntry) in
                Text(item.isDirectory || item.suffix.isEmpty ? language.text(item.category) : item.suffix.uppercased() + " · " + language.text(item.category))
                    .foregroundStyle(.secondary)
            }.width(min: 105, ideal: 140)
            TableColumn(language.text("大小"), value: \ArchiveEntry.size).width(90)
            TableColumn(language.text("修改时间"), value: \ArchiveEntry.modified).width(170)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(language.text("打开选中项")) {
                if let item = model.visible.first(where: { ids.contains($0.id) }) { model.activate(item) }
            }.disabled(ids.count != 1 || model.busy || model.visible.contains { ids.contains($0.id) && $0.category == "压缩包" })
            Button(language.text("解压选中项…")) { model.selection = ids; model.extract(selected: true) }.disabled(ids.isEmpty || model.busy)
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
            Section(language.text("工作区")) {
                Label(language.text("压缩包浏览器"), systemImage: "archivebox")
                Button(language.text("创建 RAR")) { model.chooseInputs() }
                SettingsLink { Label(language.text("CLI 设置"), systemImage: "gearshape") }
            }
            Section(language.text("最近打开")) {
                Button { model.clearRecent() } label: { Label(language.text("清除历史记录"), systemImage: "clock.badge.xmark") }
                    .disabled(model.recent.isEmpty && NSDocumentController.shared.recentDocumentURLs.isEmpty)
                ForEach(model.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }.help(url.path)
                }
            }
            Section(language.text("格式支持")) {
                Text(language.text("内置 7-Zip 26.03"))
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

struct CreateView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var headers = true
    @State private var volume = "0"
    @State private var recovery = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("创建 RAR5 压缩包"), systemImage: "archivebox.fill").font(.title2)
            Text(language.text("{0} 个源项目 · 保留所选文件夹结构", String(model.inputs.count))).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading) { ForEach(model.inputs, id: \.self) { Text($0.path).font(.caption).textSelection(.enabled) } } }.frame(height: 70)
            Form {
                SecureField(language.text("密码（可选）"), text: $password)
                SecureField(language.text("确认密码"), text: $confirmation)
                Toggle(language.text("加密文件名"), isOn: $headers).disabled(password.isEmpty)
                TextField(language.text("分卷大小（MB，0 表示不分卷）"), text: $volume)
                Picker(language.text("恢复记录"), selection: $recovery) { Text(language.text("无")).tag(0); Text("3%").tag(3); Text("5%").tag(5); Text("10%").tag(10) }
            }
            Text(language.text("密码通过标准输入传递，不写入命令参数或设置。加密任务期间日志在结束后显示。新建仅支持 RAR5，不覆盖已有压缩包。")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(language.text("取消")) { dismiss() }; Button(language.text("选择保存位置…")) { model.create(password: password, headers: headers, volume: Int(volume) ?? -1, recovery: recovery) }.buttonStyle(.borderedProminent).disabled(password != confirmation || Int(volume) == nil || model.inputs.isEmpty) }
        }.padding(24).frame(width: 540)
        .onDisappear { password = ""; confirmation = "" }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        Form {
            Picker(language.text("外观"), selection: $model.appearance) {
                Text(language.text("跟随系统")).tag("system")
                Text(language.text("日间模式")).tag("light")
                Text(language.text("夜间模式")).tag("dark")
            }
            Picker(language.text("语言"), selection: $language.selected) {
                Text(language.text("跟随系统")).tag("system")
                ForEach(language.packs) { pack in Text(pack.name).tag(pack.id) }
            }
            HStack {
                Button(language.text("导入语言包…")) { language.importPack() }
                Button(language.text("查看本地化示例")) { language.showDemo() }
            }
            Text(language.text("语言包只能包含文字；缺失条目会回退到英语。系统文件对话框与 CLI 原始日志可能遵循系统或工具语言。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(language.text("命令行工具")).font(.title2)
            Text(language.text("已内置 7-Zip，浏览、解压和测试无需安装。RAR 创建与恢复数据仍需单独配置获得许可的 RARLAB 工具。")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.sevenZip.isEmpty ? language.text("正在使用内置解压引擎") : language.text("正在使用自定义解压引擎"))
                Button(language.text("检测解压引擎")) { model.check(model.resolvedSevenZip) }
                Button(language.text("恢复内置")) { model.sevenZip = ""; model.savePaths() }
            }
            pathRow(language.text("RAR（创建及恢复数据）"), path: $model.rar)
            HStack {
                Link(language.text("下载 RAR for macOS…"), destination: URL(string: "https://www.rarlab.com/download.htm")!)
                Link(language.text("RAR 使用许可"), destination: URL(string: "https://www.rarlab.com/license.htm")!)
            }
            Text(language.text("下载页面请选择 macOS ARM（Apple Silicon）或 x64（Intel）。解包后在上方选择 rar 文件。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            pathRow(language.text("可选：自定义 7zz 路径（留空使用内置）"), path: $model.sevenZip)
            Button(language.text("第三方许可与源码")) { if let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty") { NSWorkspace.shared.open(url) } }
            Text(language.text(model.status)).font(.caption)
            Link(language.text("RARLAB 官方下载与许可"), destination: URL(string: "https://www.rarlab.com/download.htm")!)
        }.padding(24).frame(width: 700).disabled(model.busy).onDisappear { model.savePaths() }
        .alert(language.text("操作未完成"), isPresented: Binding(get: { language.importError != nil }, set: { if !$0 { language.importError = nil } })) { Button("OK") { language.importError = nil } } message: { Text(language.importError ?? "") }
    }
    func pathRow(_ title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            HStack {
                TextField(language.text("绝对路径"), text: path).textFieldStyle(.roundedBorder)
                Button(language.text("选择…")) { let p = NSOpenPanel(); p.canChooseDirectories = false; if p.runModal() == .OK, let url = p.url { path.wrappedValue = url.path; model.savePaths() } }
                Button(language.text("检测")) { model.check(path.wrappedValue) }
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
