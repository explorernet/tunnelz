import AppKit
import SwiftUI
import SwiftData

@main
struct TunnelzApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var processManager: TunnelProcessManager
    private let modelContainer: ModelContainer

    init() {
        let processManager = TunnelProcessManager()
        _processManager = State(initialValue: processManager)
        AppLifecycleDelegate.processManager = processManager
        modelContainer = Self.makeModelContainer()
        _ = AppUpdater.shared
    }

    /// Keeps the store in Tunnelz's own folder rather than the shared default.store,
    /// which every unsandboxed SwiftData app would otherwise write to.
    private static func makeModelContainer() -> ModelContainer {
        let folder = URL.applicationSupportDirectory.appending(path: "Tunnelz", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: folder.appending(path: "Tunnelz.store"))
        return try! ModelContainer(for: Tunnel.self, CapturedRequest.self, configurations: configuration)
    }

    var body: some Scene {
        WindowGroup("Tunnelz", id: "main") {
            AppRootView(processManager: processManager)
        }
        .defaultSize(width: 1_220, height: 760)
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(!AppUpdater.shared.isAvailable)
            }
        }

        Window("Add Tunnel", id: "add-tunnel") {
            AddTunnelWindowView(processManager: processManager)
        }
        .windowResizability(.contentSize)
        .modelContainer(modelContainer)

        MenuBarExtra("Tunnelz", systemImage: "circle.circle") {
            MenuBarView(processManager: processManager)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
        }
        .defaultSize(width: 820, height: 590)
        .windowResizability(.automatic)
    }
}
