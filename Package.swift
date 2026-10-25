// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fenestra",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fenestra",
            path: "Sources/Fenestra",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
