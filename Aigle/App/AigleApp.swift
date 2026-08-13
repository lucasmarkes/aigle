import SwiftUI

@main
struct AigleApp: App {
    @State private var controller = LibraryController()
    @State private var settings = AppSettings.shared
    @State private var commandBus = CommandBus()
    @State private var extensionServer = ExtensionServer()
    @State private var setup = SetupModel()

    /// Any change here restarts (or stops) the listener.
    private var serverConfiguration: String {
        "\(settings.extensionServerEnabled)-\(settings.extensionPort)-\(settings.extensionToken)"
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(settings)
                .environment(commandBus)
                .environment(extensionServer)
                .environment(setup)
                .preferredColorScheme(settings.appearance.colorScheme)
                .task { await controller.restoreLastLibrary() }
                // The browser-extension listener follows the preference from
                // launch onward — opening Settings is never a prerequisite.
                .task(id: serverConfiguration) {
                    extensionServer.sync(settings: settings, controller: controller)
                }
                .onOpenURL { url in DeepLink.handle(url, controller: controller) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AigleCommands(controller: controller, bus: commandBus, setup: setup) }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(settings)
                .environment(extensionServer)
                .environment(setup)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            MenuBarPanel()
                .environment(controller)
        } label: {
            Image(systemName: "bird.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Routes `aigle://` deep links (used by the embedded Safari extension) into the app.
enum DeepLink {
    @MainActor
    static func handle(_ url: URL, controller: LibraryController) {
        guard url.scheme == "aigle", url.host() == "save",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw)
        else { return }
        let type = components.queryItems?.first(where: { $0.name == "type" })?.value ?? "page"
        if type == "image" || type == "video" {
            controller.importRemoteMedia(target)
        } else {
            controller.importLink(target, into: nil)
        }
    }
}
