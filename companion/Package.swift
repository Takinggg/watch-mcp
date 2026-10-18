// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WatchRecorder",
            path: "Sources/WatchRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "WatchRecorderTests",
            dependencies: ["WatchRecorder"],
            path: "Tests/WatchRecorderTests"
        ),
    ]
)
