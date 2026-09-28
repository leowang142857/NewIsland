import SwiftUI
import AppKit

@main
struct GrokIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            VStack(alignment: .leading, spacing: 8) {
                Text("grok岛")
                    .font(.title3.weight(.semibold))
                Text("The island panel is the main UI. This settings pane is a stub.")
                    .foregroundStyle(.secondary)
                Text("Modules are stored in Application Support/GrokIsland/function-modules.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("在桌面创建快捷方式") {
                    _ = try? DesktopShortcut.install()
                }
            }
            .padding(20)
            .frame(minWidth: 360)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = IslandSettings()
    lazy var engine: IslandEngine = {
        let storage = settings.storage
        let grok = CursorAgentGrokClient(credentials: { storage.credentials() })
        return IslandEngine(grokBot: GrokBotExecutor(client: grok))
    }()
    lazy var monitor = CloudActivityMonitor(storage: settings.storage)
    private var panelController: IslandPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        panelController = IslandPanelController(engine: engine, monitor: monitor, settings: settings)
        panelController?.show()
        monitor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // TODO: When Grok Bot is wired, map grok-island:// callbacks into IslandEngine.
        let dropped = urls.filter { $0.scheme != GrokBotTransport.urlScheme }
        if !dropped.isEmpty {
            engine.ingestDroppedURLs(dropped)
        }
    }
}
