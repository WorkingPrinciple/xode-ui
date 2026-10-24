// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import Vision
import XodusManagement

private actor SearchMetadataTransport: PCGamesTransport {
    func send(_ request: URLRequest) throws -> PCGamesHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = items.first { $0.name == "bigIds" }?.value?.split(separator: ",") ?? []
        let products = ids.map { id -> [String: Any] in
            ["ProductId": String(id), "ProductType": "Game", "ProductKind": "Game", "LocalizedProperties": [
                ["ProductTitle": "Neutral public game", "Images": []]],
             "Properties": ["Categories": ["Games"]],
             "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                ["PlatformDependencies": [["PlatformName": "Windows.Desktop"]],
                 "PackageFormat": "EAppx"]
             ]]]]]]
        }
        return PCGamesHTTPResponse(status: 200,
            data: try JSONSerialization.data(withJSONObject: ["Products": products]))
    }
}

@MainActor
enum SearchPresentationChecks {
    static func run(library: PCGamesController, check: (Bool, String) -> Void) async throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("XodusSearchChecks-\(UUID().uuidString)")
        let configuration = BackendConfiguration(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("XodusManagementChecks"),
            stateDirectory: state.appendingPathComponent("querypagination"))
        defer { try? FileManager.default.removeItem(at: state) }
        let session = LiveSession(configuration: configuration)
        await session.connect()
        await session.refreshCatalog("Neutral")
        check(session.isReady && session.products.count == 1,
              "REQ-73: Delayed public fixture is ready with one product (phase \(session.phase), error \(session.catalogError ?? session.errorMessage ?? "none"))")
        guard session.isReady, session.products.count == 1,
              library.representedGames.count > 0 else { throw PCGamesError.transport }
        let art = LibraryCatalogArtwork(transport: SearchMetadataTransport())
        await art.load(ids: session.products.map(\.id), market: session.market, language: session.language)
        check(session.products.allSatisfy { art.images[$0.id]?.facts.isBaseGame == true },
              "REQ-73: Public poster fixture has positively classified game metadata")
        let installed = InstalledGamesController()
        let operations = GameOperationsController(installed: installed)
        check(session.products.allSatisfy {
            !operations.supportIssues(productID: $0.id, packageFormat: art.images[$0.id]?.facts.packageFormat).isEmpty
        }, "REQ-73: The public fixture has a real package blocker whose admission/reason must be retained")
        var cleared = false, returned = false
        let selection = DiscoverSelection()
        let view = LiveCatalogView(library: library, installed: installed, operations: operations,
            art: art, query: "Neutral", allowsArtworkLoading: false, allowsStartupTasks: true,
            allowsHeroAnimation: false, clearSearch: { cleared = true },
            selection: selection,
            returnToSearch: { returned = true })
        view.exitSearchResults()
        check(cleared && returned, "REQ-73: Result Escape clears the query and returns to the native editor")
        var opened = 0
        let keyboardCard = GameCard(title: "Neutral keyboard game", openLabel: "View",
                                   open: { opened += 1 }) {
            Color.clear
        } status: { EmptyView() } actions: { EmptyView() }
        let keyResult = keyboardCard.openFromKeyboard()
        check(opened == 1 && keyResult == .handled,
              "REQ-73: Poster Return invokes its detail action once and consumes the event")
        check(keyboardCard.artworkAccessibilityLabel == "View Neutral keyboard game",
              "REQ-73: The directly focused poster button uses its explicit title-specific action label")
        var ringColors: [NSColor] = []
        for focused in [false, true] {
            let host = NSHostingView(rootView: Color.white.frame(width: 100, height: 150)
                .modifier(SearchResultFocusRing(focused: focused)))
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 150)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PCGamesError.transport
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let color = bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else {
                throw PCGamesError.transport
            }
            ringColors.append(color)
        }
        check(ringColors.count == 2 && ringColors[0] != ringColors[1],
              "REQ-73: The poster focus modifier draws a visible border only when focused")
        let retained = GameSearchPresentation.retainedPublicIDs(pending: true, searching: true,
            matchesQuery: true, products: session.products)
        check(retained == Set(session.products.map(\.id))
              && retained.isDisjoint(with: library.representedGames.map(\.id)),
              "REQ-73: Only retained public IDs dim; current-query local Library matches stay usable")
        check(GameSearchPresentation.firstFocusableID(local: ["local"], publicResults: ["old", "fresh"],
                retainedPublic: ["old"]) == "local"
              && GameSearchPresentation.firstFocusableID(local: [], publicResults: ["old", "fresh"],
                retainedPublic: ["old"]) == "fresh"
              && GameSearchPresentation.firstFocusableID(local: [], publicResults: ["old"],
                retainedPublic: ["old"]) == nil,
              "REQ-73: Down selects a usable named result and never a disabled retained placeholder")
        for flags in [(false, true, true), (true, false, true), (true, true, false)] {
            check(GameSearchPresentation.retainedPublicIDs(pending: flags.0, searching: flags.1,
                matchesQuery: flags.2, products: session.products).isEmpty,
                "REQ-73: Settled/error or wrong-query content cannot become a retained public placeholder")
        }
        for size in [CGSize(width: 1440, height: 874), CGSize(width: 1619, height: 1231)] {
            let host = NSHostingView(rootView: ScrollView { view }
                .environmentObject(session).environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PCGamesError.transport
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw PCGamesError.transport }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            check(labels.contains { $0.contains("Results for") }
                  && labels.contains { $0.contains("In your library") }
                  && labels.contains { $0.contains("Games (1)") }
                  && labels.contains { $0.contains("All games") },
                  "REQ-73: Actual grouped search/header/scope render at \(Int(size.width))x\(Int(size.height)): \(labels)")
            let heading = request.results?.first {
                $0.topCandidates(1).first?.string.contains("Results for") == true
            }
            let scope = request.results?.first {
                $0.topCandidates(1).first?.string.contains("All games") == true
            }
            check(heading != nil && scope != nil
                  && abs(heading!.boundingBox.midY - scope!.boundingBox.midY) < 0.03
                  && !labels.contains { $0 == "Game Pass" },
                  "REQ-73: Compact title and collapsed scope menu share one header row")
            check(!labels.contains { $0.contains("Compatibility") || $0.contains("Package not supported") },
                  "REQ-73: Search composition excludes browse Compatibility and per-card blocker diagnostics")
            if library.representedGames.count <= 5 || size.height >= 1231 {
                check(labels.contains { $0.contains("View details") },
                      "REQ-73: Visible blocked public result offers details instead of an install action")
            }
            check(!labels.contains { $0.contains("EAppx") || $0.contains("MSIXVC")
                      || $0.contains("GB download") || $0.contains("Buy") || $0.contains("19.99") },
                  "REQ-73: Search never leaks package/commerce/idle-size text")
            if library.representedGames.count > 5 {
                check(labels.contains { $0.contains("Show all 6 in Library") }
                      && !labels.contains { $0.contains("Neutral Game 6") },
                      "REQ-73: Five compact rows and Show all preserve overflow without a sixth full card")
            }
            check(!window.isVisible && !window.isKeyWindow && !operations.isBusy,
                  "REQ-73: Search render remains nonvisible/nonkey with operations idle")
            if let directory = ProcessInfo.processInfo.environment["XODUS_SEARCH_CAPTURE_DIRECTORY"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard directory.hasPrefix("/"), values.isDirectory == true,
                      values.isSymbolicLink != true else { throw PCGamesError.transport }
                let name = "req73-search-\(library.representedGames.count)-\(Int(size.width))x\(Int(size.height))"
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw PCGamesError.transport
                }
                try png.write(to: root.appendingPathComponent(name + ".png"), options: .atomic)
                try JSONEncoder().encode(labels).write(to: root.appendingPathComponent(name + "-text.json"))
            }
            selection.scope = .installed
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let scopedImage = bitmap.cgImage else { throw PCGamesError.transport }
            let scopedText = VNRecognizeTextRequest()
            scopedText.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: scopedImage).perform([scopedText])
            let scopedLabels = (scopedText.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            check(scopedLabels.contains { $0 == "Installed" }
                  && !scopedLabels.contains { $0.contains("In your library") || $0.contains("Neutral Game 1") },
                  "REQ-73: Changing the actual scope binding filters uninstalled local rows without changing query")
            selection.scope = .allGames
        }
        if library.representedGames.count == 1 {
            let installedStore = InstalledGameStore(file: state.appendingPathComponent("diagnostic/installed-games.json"))
            let installedFixture = InstalledGame(id: UUID(), title: "Neutral installed fixture",
                identityName: "Neutral.Identity", version: "1.0.0.0", storeId: session.products[0].id,
                folder: state.appendingPathComponent("missing-installation").path,
                launcher: state.appendingPathComponent("missing-installation/launch").path, importedAt: Date())
            _ = try await installedStore.upsert(installedFixture)
            let diagnosticInstalled = InstalledGamesController(store: installedStore)
            await diagnosticInstalled.load()
            diagnosticInstalled.setAccountAccessAllowed(false)
            let inlineError = diagnosticInstalled.accountAccessMessage
            check(diagnosticInstalled.games == [installedFixture]
                  && diagnosticInstalled.playErrors[installedFixture.id] == inlineError,
                  "REQ-59: Search fixture has a real installed game with an independently retained access reason")
            let diagnosticView = LiveCatalogView(library: library, installed: diagnosticInstalled,
                operations: GameOperationsController(installed: diagnosticInstalled), art: art, query: "Neutral",
                allowsArtworkLoading: false, allowsStartupTasks: true, allowsHeroAnimation: false,
                clearSearch: {}, selection: DiscoverSelection())
            for size in [CGSize(width: 1440, height: 874), CGSize(width: 1619, height: 1231)] {
                let host = NSHostingView(rootView: ScrollView { diagnosticView }
                    .environmentObject(session).environment(\.colorScheme, .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.sizingOptions = []
                host.appearance = NSAppearance(named: .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw PCGamesError.transport
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw PCGamesError.transport }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let renderedText = labels.joined(separator: " ").lowercased()
                check(labels.contains { $0.localizedCaseInsensitiveContains("Installed") }
                      && labels.contains { $0.localizedCaseInsensitiveContains("View details") }
                      && !renderedText.contains(inlineError.lowercased())
                      && !renderedText.contains("folder is no longer available"),
                      "REQ-59: Search at \(Int(size.width))x\(Int(size.height)) keeps installed state and a details action visible without per-card diagnostics: \(labels)")
                check(diagnosticInstalled.playErrors[installedFixture.id] == inlineError
                      && !window.isVisible && !window.isKeyWindow,
                      "REQ-59: Search at \(Int(size.width))x\(Int(size.height)) preserves the underlying reason and remains offscreen")
            }
        }
        if library.representedGames.count == 1 {
            let originalIDs = session.products.map(\.id)
            check(session.canLoadMoreCatalog, "REQ-73: Pagination fixture supplies an actual next cursor")
            let pagination = Task { await session.refreshCatalog("Neutral", more: true) }
            for _ in 0..<100 where !session.searching {
                try await Task.sleep(for: .milliseconds(10))
            }
            check(session.searching && session.products.map(\.id) == originalIDs
                  && session.retainedPublicIDs(query: "Neutral", pending: true).isEmpty
                  && GameSearchPresentation.firstFocusableID(local: [],
                    publicResults: originalIDs,
                    retainedPublic: session.retainedPublicIDs(query: "Neutral", pending: true)) == originalIDs.first,
                  "REQ-73: Actual pending more:true keeps the current public page reachable and focusable")
            await pagination.value
            check(session.catalogError == nil && session.products.count == 2,
                  "REQ-73: Pagination appends a distinct public product without replacing the current page")
            let refreshedIDs = Set(session.products.map(\.id))
            let replacement = Task { await session.refreshCatalog("Neutral") }
            for _ in 0..<100 where !session.searching {
                try await Task.sleep(for: .milliseconds(10))
            }
            check(session.searching && Set(session.products.map(\.id)) == refreshedIDs
                  && session.retainedPublicIDs(query: "Neutral", pending: true) == refreshedIDs
                  && GameSearchPresentation.firstFocusableID(local: [],
                    publicResults: session.products.map(\.id),
                    retainedPublic: session.retainedPublicIDs(query: "Neutral", pending: true)) == nil,
                  "REQ-73: Actual replacement pending fences retained placeholders instead of admitting focus")
            await replacement.value
            check(session.catalogError == nil && session.products.count == 1
                  && session.retainedPublicIDs(query: "Neutral", pending: true).isEmpty,
                  "REQ-73: Replacement completion restores fresh public result admission")
        }
        check(await session.disconnect(), "REQ-73: Search composition releases its neutral mock child")
    }
}
