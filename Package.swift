// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LaunchStation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        .executable(name: "launch", targets: ["LaunchCLI"]),
        .executable(name: "launchstationd", targets: ["LauncherDaemon"]),
        .executable(name: "launchstation-runner", targets: ["LauncherRunner"]),
        .executable(name: "LaunchStation", targets: ["LaunchStationApp"])
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
            name: "LaunchStationApp",
            dependencies: ["LauncherCore"]
        ),
        .testTarget(
            name: "LauncherCoreTests",
            dependencies: ["LauncherCore"]
        )
    ]
)
