// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snapper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Snapper", targets: ["Snapper"])],
    targets: [
        .target(name: "SnapKit"),
        .executableTarget(
            name: "Snapper",
            dependencies: ["SnapKit"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "SnapKitTests", dependencies: ["SnapKit"]),
    ]
)
