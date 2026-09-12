import LauncherCore
import SwiftUI

struct LaunchStationApp: App {
    @StateObject private var viewModel = LauncherViewModel(client: .default)

    var body: some Scene {
        Window("Launch Station", id: "main") {
            LauncherRootView(viewModel: viewModel)
        }
        .defaultSize(width: 1040, height: 680)
        // The AppKit title-bar installer supplies a fixed title beside the sidebar toggle, so
        // the system title must not render a second, visually duplicate label.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            LauncherCommands(viewModel: viewModel)
        }

        Settings {
            LauncherSettingsView(viewModel: viewModel)
        }
    }
}

LaunchStationApp.main()
