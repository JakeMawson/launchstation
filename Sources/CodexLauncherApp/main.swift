import LauncherCore
import SwiftUI

struct CodexLauncherApp: App {
    @StateObject private var viewModel = LauncherViewModel(client: .default)

    var body: some Scene {
        Window("Launch Station", id: "main") {
            LauncherRootView(viewModel: viewModel)
        }
        .defaultSize(width: 1040, height: 680)
        // The toolbar carries the explicitly padded title so the system title must not
        // render a second, visually duplicate label beside it.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            LauncherCommands(viewModel: viewModel)
        }

        Settings {
            LauncherSettingsView(viewModel: viewModel)
        }
    }
}

CodexLauncherApp.main()
