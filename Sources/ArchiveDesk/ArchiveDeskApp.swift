import SwiftUI
import AppKit

@main struct ArchiveDeskApp: App {
    @StateObject private var model = Model()
    @StateObject private var language = AppLanguage.shared
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .onOpenURL { model.receive([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.runner.cancel() }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(language.text("打开压缩包…")) { model.chooseArchive() }.keyboardShortcut("o").disabled(model.busy)
                Button(language.text("创建 RAR…")) { model.chooseInputs() }.keyboardShortcut("n").disabled(model.busy)
            }
        }
        Settings { SettingsView().environmentObject(model).environmentObject(language).environment(\.locale, language.locale) }
    }
}
