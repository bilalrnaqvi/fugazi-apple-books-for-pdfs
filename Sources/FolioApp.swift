import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { switch self { case .system: "Match System"; case .light: "Light"; case .dark: "Dark" } }
    var nsAppearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .light
    }
    static func apply() { NSApp.appearance = current.nsAppearance }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let ids = LibraryStore.shared.importPDFs(urls)
            NotificationCenter.default.post(name: .folioOpenBooks, object: ids)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LibraryStore.shared.save() }   // flush any unsaved reading time
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()   // pages are always paper-white; this only affects the app's chrome
        NSWindow.allowsAutomaticWindowTabbing = false   // books open as their own windows, like Books
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore.shared
    @AppStorage("appAppearance") private var appearance: AppAppearance = .light

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add PDFs to Library…") { store.presentImportPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appearance) { _, _ in AppAppearance.apply() }
                Divider()
                Button("Zoom In") { ReaderCommand.post(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { ReaderCommand.post(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Fit Page") { ReaderCommand.post(.zoomFit) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Previous Page") { ReaderCommand.post(.previousPage) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Page") { ReaderCommand.post(.nextPage) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Go to Page…") { ReaderCommand.post(.goToPage) }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Button("Add / Remove Bookmark") { ReaderCommand.post(.toggleBookmark) }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Find in Book…") { ReaderCommand.post(.find) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Table of Contents") { ReaderCommand.post(.contents) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Notes & Highlights") { ReaderCommand.post(.notes) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Bookmarks") { ReaderCommand.post(.bookmarks) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Sidebar") { ReaderCommand.post(.toggleSidebar) }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        WindowGroup("Reader", id: "reader", for: UUID.self) { $bookID in
            if let id = bookID {
                ReaderView(bookID: id)
                    .environment(store)
                    .frame(minWidth: 600, minHeight: 500)
            }
        }
        .defaultSize(width: 1180, height: 860)
    }
}
