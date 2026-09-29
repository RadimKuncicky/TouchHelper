// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchHelper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TouchHelper", targets: ["TouchHelper"])
    ],
    targets: [
        .executableTarget(
            name: "TouchHelper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
