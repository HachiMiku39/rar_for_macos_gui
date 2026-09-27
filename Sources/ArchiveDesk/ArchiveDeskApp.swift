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
                .preferredColorScheme(model.colorScheme)
                .onOpenURL { model.receive([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.runner.cancel(); model.cleanOpenedCopies() }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(language.text("Open Archive…")) { model.chooseArchive() }.keyboardShortcut("o").disabled(model.busy)
                Button(language.text("Create Archive…")) { model.chooseInputs() }.keyboardShortcut("n").disabled(model.busy)
            }
        }
        Settings { SettingsView().environmentObject(model).environmentObject(language).environment(\.locale, language.locale).preferredColorScheme(model.colorScheme) }
    }
}
