// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NovaComputerUse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NovaComputerUseCore", targets: ["NovaComputerUseCore"]),
        .executable(name: "NovaComputerUseService", targets: ["NovaComputerUseService"]),
        .executable(name: "NovaComputerUseMCP", targets: ["NovaComputerUseMCP"])
    ],
    targets: [
        .target(name: "NovaComputerUseCore"),
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
        )
    ]
)
