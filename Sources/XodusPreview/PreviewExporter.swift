// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import XodusManagement
import XodusCore

@MainActor
enum PreviewExporter {
    private static var started = false
    private static var fixtureExport = true

    static var liveDataRequested: Bool { CommandLine.arguments.contains("--export-live-data") }

    static func liveConfiguration() throws -> BackendConfiguration {
        guard liveDataRequested,
              CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-live-data",
              let path = ProcessInfo.processInfo.environment["XODUS_EXPORT_ADMITTED_BUNDLE"],
              let bundle = Bundle(url: URL(fileURLWithPath: path, isDirectory: true)) else {
            throw ManagementError.pairedEngineUnavailable
        }
        let profile = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Xodus/Management", isDirectory: true)
        return try ShippingPairAdmission.configuration(bundle: bundle, stateDirectory: profile,
                                                        pins: ShippingPairPins.approved)
    }

    static func startIfRequested(state: AppState, session: LiveSession? = nil) {
        if liveDataRequested {
            guard !started, let session,
                  let flag = CommandLine.arguments.firstIndex(of: "--export-live-data"),
                  CommandLine.arguments.indices.contains(flag + 1) else { return }
            started = true
            let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
            Task {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    await session.connect()
                    guard session.isReady else { fail("Admitted live engine could not connect") }
                    await session.refreshAccount()
                    guard session.accountStatusCurrent, session.currentCredentialState == .credentialPresent,
                          !session.signInPending else { fail("Fresh saved sign-in was not confirmed; no account image exported") }
                    guard session.supports(.libraryRecent) else { fail("Admitted engine has no recent-history provider") }
                    await session.refreshRecentLibrary()
                    guard session.recentLibraryCurrent, let recent = session.recentLibrary else {
                        fail(session.recentLibraryError ?? "Actual recent-history read did not produce a confirmed snapshot")
                    }
                    await session.refreshCatalog("Halo")
                    guard !session.searching, session.catalogError == nil, !session.products.isEmpty,
                          session.catalogCorpus == "publicMicrosoftStoreSearch" else {
                        fail("Actual public Store search did not return exportable results")
                    }
                    let recentArt = recent.titles.prefix(10).compactMap {
                        CatalogArtworkReference.preferred(in: $0.artwork, roles: [.tile])
                    }
                    let catalogArt = session.products.prefix(8).compactMap {
                        CatalogArtworkReference.preferred(in: $0.artwork, roles: [.boxArt, .poster, .hero])
                    }
                    let hero = session.products.first.flatMap {
                        CatalogArtworkReference.preferred(in: $0.artwork, roles: [.hero])
                    }
                    let failedImages = await CatalogArtworkStore.shared.preload(
                        recentArt + catalogArt + (hero.map { [$0] } ?? []))
                    print("Actual metadata artwork fetch failures: \(failedImages). No metadata absence inferred.")
                    try await exportLiveViews(state: state, session: session, directory: directory)
                    guard await session.disconnect() else { fail("Live export owner did not close") }
                    print("Exported 4 actual live own-view renders. No fixtures, desktop capture or account identifiers. Compositor/a11y not certified.")
                    exit(0)
                } catch { fail("Actual live own-view export failed: \(error.localizedDescription)") }
            }
            return
        }
        guard !started, let flag = CommandLine.arguments.firstIndex(of: "--export-preview")
                ?? CommandLine.arguments.firstIndex(of: "--export-live") else { return }
        started = true
        fixtureExport = CommandLine.arguments[flag] == "--export-preview"
        guard CommandLine.arguments.indices.contains(flag + 1) else {
            fail("Own-view export requires an explicit output directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { fail("Cannot create preview export directory: \(error.localizedDescription)") }
        exportScreen(0, state: state, directory: directory)
    }

    private static func exportLiveViews(state: AppState, session: LiveSession, directory: URL) async throws {
        for screen in ["library", "discover-search", "product", "account-signed-in"] {
            state.showingAccount = false
            session.selectedProduct = nil
            state.navigate(screen == "library" ? .library : .discover)
            if screen != "library" { state.query = "Halo" }
            if screen == "product" { session.selectedProduct = session.products.first }
            if screen == "account-signed-in" { state.showingAccount = true }
            try await Task.sleep(for: .milliseconds(800))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Xodus" }) else {
                fail("Actual live window is unavailable")
            }
            let target = ["product", "account-signed-in"].contains(screen) ? window.attachedSheet : window
            guard let view = target?.contentView?.superview else { fail("Actual live own-view hierarchy is unavailable") }
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fail("Actual live view bitmap allocation failed")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                fail("Actual live own-view render produced no PNG")
            }
            let output = directory.appendingPathComponent("live-\(screen).png")
            try data.write(to: output, options: .withoutOverwriting)
            print(output.path)
        }
    }

    private static func exportScreen(_ index: Int, state: AppState, directory: URL) {
        let screens: [Destination] = [.library, .discover, .downloads]
        guard screens.indices.contains(index) else {
            print("Exported 3 native \(fixtureExport ? "fixture" : "disconnected live-shell") views. No desktop or other app capture.")
            exit(0)
        }
        let screen = screens[index]
        state.navigate(screen)
        if fixtureExport && screen == .downloads {
            state.jobs = [
                FixtureJob(gameID: Fixtures.games[2].id, phase: .verifying),
                FixtureJob(gameID: Fixtures.games[1].id, phase: .failed)
            ]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && ($0.title == "Xodus" || $0.title.contains("Fixture Preview"))
            }), let view = window.contentView?.superview else {
                fail("Native fixture window was not available for its own view export")
            }
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fail("AppKit could not allocate a native view bitmap")
            }
            // This renders only our own NSView hierarchy, never reads the desktop framebuffer.
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                fail("AppKit native view export produced no PNG")
            }
            do {
                let prefix = fixtureExport ? "native" : "live"
                let output = directory.appendingPathComponent("\(prefix)-\(screen.rawValue.lowercased()).png")
                try data.write(to: output)
                print(output.path)
            } catch { fail("Native view export failed: \(error.localizedDescription)") }
            exportScreen(index + 1, state: state, directory: directory)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Native preview export failed: \(message)\n".utf8))
        exit(1)
    }
}
