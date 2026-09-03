// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        .executable(name: "launch", targets: ["LaunchCLI"]),
        .executable(name: "codex-launcherd", targets: ["LauncherDaemon"]),
        .executable(name: "codex-launcher-runner", targets: ["LauncherRunner"]),
        .executable(name: "CodexLauncher", targets: ["CodexLauncherApp"])
    ],
    targets: [
        .target(
            name: "LauncherCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "LaunchCLI",
            dependencies: ["LauncherCore"]
        ),
        .executableTarget(
            name: "LauncherDaemon",
            dependencies: ["LauncherCore"]
        ),
        .executableTarget(
            name: "LauncherRunner",
            dependencies: ["LauncherCore"]
        ),
        .executableTarget(
            name: "CodexLauncherApp",
            dependencies: ["LauncherCore"]
        ),
        .testTarget(
            name: "LauncherCoreTests",
            dependencies: ["LauncherCore"]
        )
    ]
)
