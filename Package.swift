// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription
import Foundation

let shipping = ProcessInfo.processInfo.environment["XODUS_SHIPPING"] == "1"
let previewOnly = ["Artwork.swift", "RootView.swift", "FixtureLibraryView.swift", "DetailView.swift", "DownloadsView.swift",
                   "PreviewExporter.swift", "LibraryPreviewExporter.swift", "PreviewChecks.swift", "NativeChecks.swift",
                   "NativeUIChecks.swift", "ApplicationTerminationChecks.swift", "CrossOverDependencyChecks.swift",
                   "RecentLibraryChecks.swift", "CatalogMediaChecks.swift", "LibraryStatsChecks.swift", "LibraryAccessChecks.swift", "InstalledGameChecks.swift", "PCGamesChecks.swift", "GameOperationChecks.swift", "DownloadQueueChecks.swift", "InstalledGameUpdateChecks.swift", "Resources"]
let shippingSettings: [SwiftSetting] = shipping ? [.define("XODUS_SHIPPING")] : []

let package = Package(
    name: "XodusAppFoundation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XodusCore", targets: ["XodusCore"]),
        .library(name: "XodusManagement", targets: ["XodusManagement"]),
        .library(name: "XodusCredentials", targets: ["XodusCredentials"]),
        .executable(name: "XodusPreview", targets: ["XodusPreview"]),
        .executable(name: "XodusAuthHost", targets: ["XodusAuthHost"]),
        .executable(name: "XodusCredentialBroker", targets: ["XodusCredentialBroker"])
    ] + (shipping ? [] : [
        .executable(name: "XodusFixtureChecks", targets: ["XodusFixtureChecks"]),
        .executable(name: "XodusManagementChecks", targets: ["XodusManagementChecks"]),
        .executable(name: "XodusCredentialChecks", targets: ["XodusCredentialChecks"])
    ]),
    targets: [
        .target(name: "XodusCore", exclude: shipping ? ["Fixtures.swift"] : [],
                swiftSettings: shippingSettings),
        .target(name: "XodusManagement", dependencies: ["XodusCore"],
                resources: [.copy("Resources/management-v1.schema.json"),
                            .copy("Resources/runtime-providers-v1.schema.json")]),
        .target(name: "XodusCredentials"),
        .executableTarget(name: "XodusCredentialBroker", dependencies: ["XodusCredentials"]),
        .executableTarget(name: "XodusPreview", dependencies: ["XodusCore", "XodusManagement", "XodusCredentials"],
                          exclude: shipping ? previewOnly : [],
                          resources: shipping ? [] : [.copy("Resources/Artwork")],
                          swiftSettings: shippingSettings),
        .executableTarget(name: "XodusAuthHost", exclude: shipping ? ["AuthHostChecks.swift", "Resources"] : [],
                          resources: shipping ? [] : [.copy("Resources")], swiftSettings: shippingSettings)
    ] + (shipping ? [
        .testTarget(name: "XodusShippingChecks", dependencies: ["XodusPreview", "XodusManagement"],
                    path: "Tests/ShippingChecks")
    ] : [
        .executableTarget(name: "XodusFixtureChecks", dependencies: ["XodusCore"],
                          path: "Tests/FixtureChecks"),
        .executableTarget(name: "XodusManagementChecks", dependencies: ["XodusManagement"],
                          path: "Tests/ManagementChecks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "XodusCredentialChecks", dependencies: ["XodusCredentials"])
    ])
)
