// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NovaComputerUse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NovaComputerUseCore", targets: ["NovaComputerUseCore"]),
        .library(name: "NovaInstallerCore", targets: ["NovaInstallerCore"]),
        .executable(name: "NovaComputerUseService", targets: ["NovaComputerUseService"]),
        .executable(name: "NovaComputerUseMCP", targets: ["NovaComputerUseMCP"]),
        .executable(name: "NovaApp", targets: ["NovaApp"])
    ],
    targets: [
        .target(name: "NovaComputerUseCore"),
        .target(name: "NovaInstallerCore"),
        .executableTarget(
            name: "NovaApp",
            dependencies: ["NovaInstallerCore"]
        ),
        .executableTarget(
            name: "NovaComputerUseService",
            dependencies: ["NovaComputerUseCore"]
        ),
        .executableTarget(
            name: "NovaComputerUseMCP",
            dependencies: ["NovaComputerUseCore"]
        ),
        .testTarget(
            name: "NovaComputerUseCoreTests",
            dependencies: ["NovaComputerUseCore", "NovaComputerUseService"]
        ),
        .testTarget(
            name: "NovaComputerUseMCPTests",
            dependencies: ["NovaComputerUseCore", "NovaComputerUseMCP"]
        ),
        .testTarget(
            name: "NovaInstallerCoreTests",
            dependencies: ["NovaInstallerCore"]
        )
    ]
)
