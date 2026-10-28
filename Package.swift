// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription
import Foundation

let shipping = ProcessInfo.processInfo.environment["ODE_SHIPPING"] == "1"
let previewOnly = ["NativeCheckOCR.swift", "SearchPresentationChecks.swift", "Artwork.swift", "RootView.swift", "FixtureLibraryView.swift", "DetailView.swift", "DownloadsView.swift",
                   "PreviewExporter.swift", "LibraryPreviewExporter.swift", "PreviewChecks.swift", "NativeChecks.swift",
                   "NativeUIChecks.swift", "CalimochoReleaseInstallerChecks.swift", "AccountCountryChecks.swift", "ApplicationTerminationChecks.swift", "CrossOverDependencyChecks.swift", "LaunchAssociationChecks.swift",
                   "OdeRuntimeChecks.swift", "RecentLibraryChecks.swift", "CatalogMediaChecks.swift", "LibraryStatsChecks.swift", "LibraryAccessChecks.swift", "InstalledGameChecks.swift", "PCGamesChecks.swift", "GameOperationChecks.swift", "DownloadQueueChecks.swift", "InstalledGameUpdateChecks.swift", "EngineManagementChecks.swift", "EngineConfiguratorChecks.swift", "CatalogDetailLoadingChecks.swift", "PresentationPerformanceChecks.swift", "SearchPerformanceChecks.swift", "PublicDescriptorChecks.swift", "BrandUXChecks.swift", "AccessibilityAuditChecks.swift", "StabilityChecks.swift", "Resources"]
// A qualification variant (never the ordinary install) adds fixed diagnostic channels and the FH6 Play gate.
let qualification = ProcessInfo.processInfo.environment["ODE_QUALIFICATION"] == "1"
let shippingSettings: [SwiftSetting] = (shipping ? [.define("ODE_SHIPPING")] : [])
    + (qualification ? [.define("ODE_QUALIFICATION"), .define("ODE_FH6_QUALIFICATION")] : [])

let package = Package(
    name: "OdeApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OdeCore", targets: ["OdeCore"]),
        .library(name: "OdeManagement", targets: ["OdeManagement"]),
        .library(name: "OdeCredentials", targets: ["OdeCredentials"]),
        .executable(name: "OdePreview", targets: ["OdePreview"]),
        .executable(name: "OdeAuthHost", targets: ["OdeAuthHost"]),
        .executable(name: "OdeCredentialBroker", targets: ["OdeCredentialBroker"])
    ] + (shipping ? [] : [
        .executable(name: "OdeFixtureChecks", targets: ["OdeFixtureChecks"]),
        .executable(name: "OdeManagementChecks", targets: ["OdeManagementChecks"]),
        .executable(name: "OdeCredentialChecks", targets: ["OdeCredentialChecks"])
    ]),
    targets: [
        .target(name: "OdeCore", exclude: shipping ? ["Fixtures.swift"] : [],
                swiftSettings: shippingSettings),
        .target(name: "OdeManagement", dependencies: ["OdeCore"],
                exclude: ["QA/CompatibilityData/next-30-queue.json",
                          "QA/CompatibilityData/queue-inspection-v1.json",
                          "QA/LaunchRecipes/preflight-game-candidates.json",
                          "QA/LaunchRecipes/small-game-candidates.json",
                          "Resources/mac-game-evidence-v1.json"],
                resources: [.copy("Resources/management-v1.schema.json"),
                            .copy("Resources/runtime-providers-v1.schema.json"),
                            .copy("Resources/mac-game-status-v1.json"),
                            .copy("Resources/LaunchRecipes"),
                            .copy("Resources/CompatibilityData")]),
        .target(name: "OdeCredentials"),
        .target(name: "OdeProcessIdentity"),
        .executableTarget(name: "OdeCredentialBroker", dependencies: ["OdeCredentials"]),
        .executableTarget(name: "OdePreview", dependencies: ["OdeCore", "OdeManagement", "OdeCredentials", "OdeProcessIdentity"],
                          exclude: shipping ? previewOnly : [],
                          resources: shipping ? [] : [.copy("Resources/Artwork")],
                          swiftSettings: shippingSettings),
        .executableTarget(name: "OdeAuthHost", exclude: shipping ? ["AuthHostChecks.swift", "Resources"] : [],
                          resources: shipping ? [] : [.copy("Resources")], swiftSettings: shippingSettings)
    ] + (shipping ? [
        .testTarget(name: "OdeShippingChecks", dependencies: ["OdePreview", "OdeManagement"],
                    path: "Tests/ShippingChecks")
    ] : [
        .executableTarget(name: "OdeFixtureChecks", dependencies: ["OdeCore"],
                          path: "Tests/FixtureChecks"),
        .executableTarget(name: "OdeManagementChecks", dependencies: ["OdeManagement"],
                          path: "Tests/ManagementChecks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "OdeCredentialChecks", dependencies: ["OdeCredentials"])
    ])
)
