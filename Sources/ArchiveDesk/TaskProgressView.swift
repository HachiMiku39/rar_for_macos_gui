import SwiftUI
import AppKit
#if canImport(ArchiveCore)
import ArchiveCore
#endif

/// A separate, non-modal panel: never competes with the create/extract/queue sheets.
@MainActor final class TaskProgressWindowController {
    private weak var model: Model?
    private var panel: NSPanel?
    init(model: Model) { self.model = model }
    var isVisible: Bool { panel?.isVisible == true }
    func show() {
        guard let model else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 440),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("ArchiveDesk.TaskProgress")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isFloatingPanel = false
            window.level = .normal
            window.worksWhenModal = true
            window.contentView = NSHostingView(rootView: TaskProgressView()
                .environmentObject(model).environmentObject(model.language))
            window.center()
            panel = window
        }
        refreshTitle()
        panel?.makeKeyAndOrderFront(nil)
    }
    func hide() { panel?.orderOut(nil) }
    func refreshTitle() {
        guard let model else { return }
        panel?.title = model.language.text("Task progress") + " — " + model.language.text(model.taskTitle)
    }
}

struct TaskProgressView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.busy ? "archivebox" : model.taskResult == "completed" ? "checkmark.circle.fill" : model.taskResult == "failed" ? "exclamationmark.triangle.fill" : "stop.circle")
                    .foregroundStyle(model.taskResult == "failed" ? Color.orange : Color.accentColor)
                Text(language.text(model.taskTitle)).font(.title2)
                Spacer()
                Text(language.text(model.busy ? (model.cancellingTask ? "Cancelling…" : "running") : model.taskResult))
            }
            Text(language.text(model.status)).font(.callout).lineLimit(3).textSelection(.enabled)
            TaskMetricsView()
            if !model.busy {
                Text(language.text("Final task report · resource values are the last sample.")).font(.caption).foregroundStyle(.secondary)
            }
            if !model.busy && model.taskResult == "failed" {
                ScrollView { Text(language.text(model.error ?? model.stderr)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
            }
            HStack {
                Text(language.text("Hiding this window does not cancel the task.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(language.text(model.busy ? "Hide progress" : "Close")) { model.hideTaskProgress() }
                if model.busy {
                    Button(language.text(model.cancellingTask ? "Cancelling…" : model.queueRunning ? "Cancel entire queue" : "Cancel Task")) { model.cancelCurrentTask() }
                        .disabled(model.cancellingTask)
                }
            }
        }.padding(20).frame(width: 650).fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(model.colorScheme).environment(\.locale, language.locale)
    }
}

struct TaskMetricsView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    private func byteText(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
    }
    private func rateText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return byteText(UInt64(min(value, Double(Int64.max / 2)))) + "/s"
    }
    var body: some View {
        let sample = model.resourceSample
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text(model.taskPhase), systemImage: "chart.bar.xaxis")
                Spacer()
                Text(language.text("Elapsed: {0}", String(format: "%02d:%02d", Int(model.busy ? sample.elapsed : model.taskElapsed) / 60, Int(model.busy ? sample.elapsed : model.taskElapsed) % 60)))
                Text((model.busy ? model.progress : model.lastPhaseProgress).map { String(format: "%.0f%%", $0 * 100) } ?? language.text("Indeterminate"))
                    .frame(minWidth: 90, alignment: .trailing)
            }.font(.callout).monospacedDigit()
            if let value = (model.busy ? model.progress : model.lastPhaseProgress) { ProgressView(value: value).accessibilityLabel(language.text("Current phase progress")) }
            else if model.busy { ProgressView().progressViewStyle(.linear).accessibilityLabel(language.text("Indeterminate")) }
            else { Text(language.text("The engine did not report a final percentage.")).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 24) {
                metric("CPU capacity", sample.cpuCapacityPercent.map { String(format: "%.1f%%", $0) } ?? "—", "cpu")
                metric("RAM", byteText(sample.memory), "memorychip")
                metric("Disk read", rateText(sample.readPerSecond), "arrow.down.circle")
                metric("Disk write", rateText(sample.writePerSecond), "arrow.up.circle")
                Spacer(minLength: 0)
            }
            Text(language.text("Process CPU: {0} · 100% = one logical core", sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
                .font(.caption).monospacedDigit()
            if let total = sample.capacity, let free = sample.free, total > 0 {
                HStack {
                    Label(language.text("Destination volume"), systemImage: "externaldrive")
                    Text(language.text("Used: {0} · Free: {1}", byteText(total - min(free, total)), byteText(free)))
                    Spacer()
                    Text(String(format: "%.1f%%", Double(total - min(free, total)) / Double(total) * 100)).monospacedDigit()
                }.font(.caption)
            } else { Text(language.text("Destination volume: unavailable")).font(.caption) }
            if !model.currentTaskFile.isEmpty { Text(model.currentTaskFile).font(.caption).lineLimit(1).truncationMode(.middle) }
            Text(language.text("CPU capacity: our share of all logical cores (0–100%). Process CPU: Activity Monitor scale, may exceed 100%. Both include ArchiveDesk + active engine, not other apps. RAM/I/O use the same scope; cached reads may be zero. — means unavailable."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).archiveGlass().padding(.horizontal, 10).padding(.top, 8)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(language.text(title), systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).monospacedDigit()
        }.frame(minWidth: 95, alignment: .leading)
    }
}
