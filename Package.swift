// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dotmeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CDotmeter",
            path: "Sources/CDotmeter",
            publicHeadersPath: "include"
        ),
        // What the app and its helper share: the messages between them and the rule for what may be deleted.
        .target(
            name: "DotmeterShared",
            path: "Sources/DotmeterShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs with the system's rights, started by launchd when the app asks: see Sources/DotmeterHelper/main.swift.
        .executableTarget(
            name: "DotmeterHelper",
            dependencies: ["DotmeterShared"],
            path: "Sources/DotmeterHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Dotmeter",
            dependencies: ["CDotmeter", "DotmeterShared"],
            path: "Sources/Dotmeter",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
                .linkedLibrary("IOReport"),
            ]
        ),
    ]
)
