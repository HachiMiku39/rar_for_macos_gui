import SwiftUI
import AppKit
#if canImport(ArchiveCore)
import ArchiveCore
#endif

struct BatchQueueView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    @State private var secret = ""
    @State private var encoding: ZIPNameEncoding = .auto
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Batch extraction queue")).font(.title2)
            Text(language.text("Each archive uses a same-name folder. Failures do not stop later tasks. Existing folders use the selected conflict policy. Add only the first volume of each split archive.")).font(.caption)
            List {
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, job in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(job.source.lastPathComponent).lineLimit(1)
                            Text(language.text(job.state)).font(.caption).foregroundStyle(job.state == "failed" ? .red : .secondary)
                            if !job.detail.isEmpty { Text(language.text(job.detail)).font(.caption).textSelection(.enabled) }
                        }
                        Spacer()
                        if let destination = job.destination { Button(language.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
                        if !model.queueRunning {
                            Button { if index > 0 { model.queue.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            Button { model.queue.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        }
                    }
                }
            }.frame(minHeight: 210)
            Picker(language.text("Existing files"), selection: $model.extractionPolicy) {
                ForEach(ExtractionPolicy.allCases, id: \.self) { Text(language.text($0.rawValue)).tag($0) }
            }.disabled(model.queueRunning)
            Picker(language.text("ZIP filename encoding"), selection: $encoding) {
                ForEach(ZIPNameEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.disabled(model.queueRunning)
            SecureField(language.text("Password for this batch (not saved)"), text: $secret).disabled(model.queueRunning)
            if model.queueRunning {
                Text(model.status).lineLimit(1)
                if let progress = model.progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
            }
            HStack {
                Button(language.text("Close")) { dismiss() }
                Spacer()
                if model.queueRunning { Button(language.text("Cancel entire queue")) { model.cancelCurrentTask() } }
                else { Button(language.text("Start queue…")) { model.startBatch(secret: secret, encoding: encoding); secret = "" }.disabled(model.queue.isEmpty) }
            }
        }.padding(20).frame(width: 690, height: 530)
    }
}

struct ChecksumRow: Identifiable {
    let id = UUID()
    let file: String
    let algorithm: ChecksumAlgorithm
    let digest: String
    let state: String
}
@MainActor final class ChecksumModel: ObservableObject {
    @Published var rows: [ChecksumRow] = []
    @Published var busy = false
    @Published var fraction: Double = 0
    @Published var current = ""
    @Published var error: String?
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    func calculate(algorithm: ChecksumAlgorithm) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard !busy, panel.runModal() == .OK else { return }
        start(panel.urls.map { ($0, algorithm, Optional<String>.none) })
    }
    func importList() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let records = try FileChecksums.manifest(LanguagePack.readFile(file))
            let folder = NSOpenPanel(); folder.canChooseFiles = false; folder.canChooseDirectories = true
            folder.message = AppLanguage.shared.text("Choose the root folder for relative checksum paths.")
            guard folder.runModal() == .OK, let root = folder.url else { return }
            // Validate every parent before reading anything. Final files are opened no-follow.
            let files = try records.map { (try FileChecksums.target($0, root: root), $0.algorithm, Optional($0.expected)) }
            start(files)
        } catch { self.error = AppLanguage.shared.message(error) }
    }
    private func start(_ files: [(URL, ChecksumAlgorithm, String?)]) {
        rows = []; busy = true; fraction = 0; error = nil
        task = Task {
            defer { busy = false }
            for (url, algorithm, expected) in files {
                if Task.isCancelled { current = AppLanguage.shared.text("Cancelled"); break }
                current = url.lastPathComponent; fraction = 0
                do {
                    let work = Task.detached(priority: .utility) {
                        try FileChecksums.digest(url, algorithm: algorithm) { done, total in
                            Task { @MainActor in self.fraction = total == 0 ? 1 : min(1, Double(done) / Double(total)) }
                        }
                    }
                    let digest = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    rows.append(.init(file: url.path, algorithm: algorithm, digest: digest, state: expected.map { $0 == digest ? "Match" : "Mismatch" } ?? "Calculated"))
                } catch is CancellationError { current = AppLanguage.shared.text("Cancelled"); break }
                catch { rows.append(.init(file: url.path, algorithm: algorithm, digest: "", state: AppLanguage.shared.message(error))) }
            }
        }
    }
    func copy() {
        let text = rows.filter { !$0.digest.isEmpty }.map { "\($0.algorithm.rawValue)  \($0.digest)  \($0.file)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ChecksumView: View {
    @EnvironmentObject var language: AppLanguage
    @Environment(\.dismiss) var dismiss
    @StateObject private var model = ChecksumModel()
    @State private var algorithm: ChecksumAlgorithm = .sha256
    @State private var expected = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("File checksums")).font(.title2)
            HStack {
                Picker(language.text("Algorithm"), selection: $algorithm) { ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 210)
                Button(language.text("Choose files…")) { expected = ""; model.calculate(algorithm: algorithm) }
                Button(language.text("Import checksum list…")) { expected = ""; model.importList() }
            }.disabled(model.busy)
            Text(language.text("GNU SHA-256 / MD5 lists: hash, two spaces, relative filename. MD5 is for compatibility, not security authentication.")).font(.caption).foregroundStyle(.secondary)
            List(model.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.file).lineLimit(1).truncationMode(.middle)
                    Text(row.algorithm.rawValue + " · " + language.text(row.state)).foregroundStyle(row.state == "Mismatch" ? .red : .secondary)
                    HStack {
                        Text(row.digest).font(.caption.monospaced()).textSelection(.enabled)
                        if !row.digest.isEmpty {
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.digest, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                .help(language.text("Copy results"))
                        }
                    }
                }
            }.frame(minHeight: 210)
            if model.rows.count == 1, let row = model.rows.first, !row.digest.isEmpty {
                TextField(language.text("Paste expected checksum"), text: $expected).textFieldStyle(.roundedBorder)
                if !expected.isEmpty {
                    let normalized = FileChecksums.normalized(expected, algorithm: row.algorithm)
                    Text(language.text(normalized == nil ? "Invalid checksum" : normalized == row.digest ? "Match" : "Mismatch"))
                        .foregroundStyle(normalized == row.digest ? .green : .red)
                }
            }
            if model.busy { Text(model.current).lineLimit(1); ProgressView(value: model.fraction) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(language.text("Copy results")) { model.copy() }.disabled(model.rows.isEmpty)
                Spacer()
                if model.busy { Button(language.text("Cancel")) { model.cancel() } }
                Button(language.text("Close")) { model.cancel(); dismiss() }
            }
        }.padding(20).frame(width: 720, height: 540).onDisappear { model.cancel() }
    }
}
