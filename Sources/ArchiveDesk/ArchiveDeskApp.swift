import SwiftUI
import AppKit

/// Load the bundled bitmap explicitly as well as declaring CFBundleIconFile.
/// Use the prepared legacy ICNS (rounded silhouette + transparent margins), never
/// the full-bleed source artwork: explicit Dock image assignment shows its raw shape.
@MainActor final class ArchiveDeskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url), icon.isValid else { return }
        icon.isTemplate = false
        NSApplication.shared.applicationIconImage = icon
        NSApplication.shared.dockTile.display()
    }
}

@main struct ArchiveDeskApp: App {
    @NSApplicationDelegateAdaptor(ArchiveDeskAppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    @StateObject private var language = AppLanguage.shared
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .preferredColorScheme(model.colorScheme)
                .onOpenURL { model.receive([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancelInspection(); model.cancelCurrentTask(); model.cleanOpenedCopies() }
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
