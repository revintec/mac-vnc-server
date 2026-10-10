// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mac-vnc-server",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "mac-vnc-server-dev",
            targets: ["mac-vnc-server"]
        )
    ],
    targets: [
        .target(
            name: "CVNCZlib",
            exclude: ["vendor/LICENSE.md", "README.md"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("vendor"),
                // Architecture selection must use the target, including cross builds.
                .unsafeFlags(["-include", "CVNCZlibConfig.h"])
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "mac-vnc-server",
            dependencies: ["CVNCZlib"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "mac-vnc-serverTests",
            dependencies: ["mac-vnc-server"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
