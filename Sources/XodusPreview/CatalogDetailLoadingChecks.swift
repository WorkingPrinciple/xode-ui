// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import SwiftUI
import Vision

private actor DetailPriorityTransport: PCGamesTransport {
    let malformedPrice: Bool
    let priced: Bool
    let media: Bool
    init(malformedPrice: Bool = false, priced: Bool = false, media: Bool = false) {
        self.malformedPrice = malformedPrice
        self.priced = priced
        self.media = media
    }
    private(set) var started = false
    private(set) var finished = false
    private(set) var detailRequests = 0
    private var releaseBulk: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = items.first(where: { $0.name == "bigIds" })?.value ?? ""
        if ids == "FIXTURE00001" {
            started = true
            await withCheckedContinuation { releaseBulk = $0 }
            finished = true
        } else {
            detailRequests += 1
        }
        var product: [String: Any] = [
                "ProductId": ids,
                "LocalizedProperties": [["ProductTitle": "Synthetic game", "Images": [],
                                         "ProductDescription": "Synthetic description."]],
                "Properties": ["Categories": ["Games"]],
        ]
        if media {
            product["LocalizedProperties"] = [[
                "ProductTitle": "Synthetic game", "ProductDescription": "Synthetic description.",
                "Images": [["ImagePurpose": "Screenshot", "Uri": "//store-images.s-microsoft.com/image/apps.fixture",
                            "Width": 1920, "Height": 1080]],
                "CMSVideos": [["HLS": "https://cdn-dynmedia-1.microsoft.com/is/content/microsoftassets/original-fixture-AVS.m3u8?packagedStreaming=true",
                               "Caption": "Synthetic trailer"]]
            ]]
        }
        if malformedPrice {
            product["DisplaySkuAvailabilities"] = [[
                "Sku": ["SkuType": "full"],
                "Availabilities": [["OrderManagementData": ["Price": ["ListPrice": "invalid"]]]]
            ]]
        } else if priced {
            product["DisplaySkuAvailabilities"] = [[
                "Sku": ["SkuType": "full"],
                "Availabilities": [[
                    "Actions": ["Purchase"],
                    "OrderManagementData": ["Price": [
                        "ListPrice": 19.99, "MSRP": 19.99, "SalePrice": 9.99, "CurrencyCode": "USD"
                    ]]
                ]]
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["Products": [product]])
        return PCGamesHTTPResponse(status: 200, data: data)
    }

    func release() { releaseBulk?.resume(); releaseBulk = nil }
}

@MainActor
enum CatalogDetailLoadingChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let transport = DetailPriorityTransport()
        let catalogue = LibraryCatalogArtwork(transport: transport)
        let bulk = Task { await catalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US") }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await transport.started else { throw PCGamesError.transport }
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        let bulkFinished = await transport.finished
        check(!bulkFinished && catalogue.images["FIXTURE00002"]?.detail?.description == "Synthetic description.",
              "Selected details publish before a blocked bulk catalogue request finishes")
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        let detailRequests = await transport.detailRequests
        check(detailRequests == 1, "Reopening cached selected details does not fetch them again")
        await transport.release()
        await bulk.value
        check(catalogue.images["FIXTURE00001"] != nil && catalogue.images["FIXTURE00002"] != nil,
              "Bulk artwork completion preserves independently loaded selected details")
        let changedTransport = DetailPriorityTransport()
        let changedCatalogue = LibraryCatalogArtwork(transport: changedTransport)
        let oldScope = Task {
            await changedCatalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US")
        }
        for _ in 0..<100 {
            if await changedTransport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await changedCatalogue.loadDetail(id: "FIXTURE00002", market: "GB", language: "en-GB")
        await changedTransport.release()
        await oldScope.value
        check(changedCatalogue.images["FIXTURE00001"] == nil &&
              changedCatalogue.images["FIXTURE00002"]?.product.market == "GB",
              "Old bulk scope cannot replace selected details after a region change")
        let malformed = LibraryCatalogArtwork(transport: DetailPriorityTransport(malformedPrice: true))
        await malformed.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        check(malformed.images["FIXTURE00002"]?.product.title == "Synthetic game"
              && malformed.images["FIXTURE00002"]?.detail?.description == "Synthetic description.",
              "REQ-61: Removed offer data is ignored while catalogue identity and game details remain readable")
        try await detailPackageFallback(check: check)
        try await commerceAbsence(check: check)
        try await detailReadingOrder(check: check)
        try await statusContrast(check: check)
        try await concurrency(check: check)
    }

    private static func detailPackageFallback(check: (Bool, String) -> Void) async throws {
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.title2.weight(.semibold))
            DetailGameSizeView(installed: nil, downloadBytes: nil, packageFormat: "MSIXVC",
                               allowsMeasurement: false)
        }
        .padding(24)
        .frame(width: 420, height: 160, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw PCGamesError.transport
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw PCGamesError.transport }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        check(labels.contains { $0 == "Details" }
              && labels.contains { $0.localizedCaseInsensitiveContains("MSIXVC") }
              && !labels.contains { $0.localizedCaseInsensitiveContains("download") }
              && !window.isVisible && !window.isKeyWindow,
              "REQ-62: Detail-only package label remains visible without rich catalogue metadata: \(labels)")
    }

    private static func statusContrast(check: (Bool, String) -> Void) async throws {
        let installed = InstalledGamesController()
        let operations = GameOperationsController(installed: installed)
        let card = GameCard(title: "Synthetic game", open: {}) {
            Color.clear.frame(height: 80)
        } status: {
            Label("Installed", systemImage: "internaldrive").font(.caption)
        }
        let catalogue = LiveCatalogView(library: PCGamesController(), installed: installed,
            operations: operations, query: "", allowsArtworkLoading: false,
            allowsStartupTasks: false, allowsHeroAnimation: false, clearSearch: {})
            .environmentObject(LiveSession())
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light),
                                      (.darkAqua, .dark)] {
            for (label, view, size) in [
                ("Installed", AnyView(card), CGSize(width: 280, height: 400)),
                ("Game Pass benefits", AnyView(catalogue), CGSize(width: 800, height: 1000))
            ] {
                let host = NSHostingView(rootView: view.padding(20)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                host.sizingOptions = []
                host.appearance = NSAppearance(named: appearance)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw PCGamesError.transport
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw PCGamesError.transport }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                guard let observation = request.results?.first(where: {
                    $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(label) == true
                }) else {
                    let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    check(false, "REQ-19: \(label) is actually rendered in \(appearance.rawValue); observed \(labels)")
                    continue
                }
                let box = observation.boundingBox
                let x0 = max(0, Int(box.minX * Double(bitmap.pixelsWide)))
                let x1 = min(bitmap.pixelsWide, Int(ceil(box.maxX * Double(bitmap.pixelsWide))))
                let y0 = max(0, Int((1 - box.maxY) * Double(bitmap.pixelsHigh)))
                let y1 = min(bitmap.pixelsHigh, Int(ceil((1 - box.minY) * Double(bitmap.pixelsHigh))))
                func luminance(x: Int, y: Int) throws -> Double {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        throw PCGamesError.transport
                    }
                    func linear(_ value: CGFloat) -> Double {
                        let v = Double(value)
                        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                    }
                    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                        + 0.0722 * linear(color.blueComponent)
                }
                var glyph: [Double] = []
                for y in y0..<y1 {
                    for x in x0..<x1 { glyph.append(try luminance(x: x, y: y)) }
                }
                guard !glyph.isEmpty else { throw PCGamesError.transport }
                glyph.sort()
                let backing = try luminance(x: 2, y: 2)
                let index = Int(Double(glyph.count - 1) * (scheme == .light ? 0.05 : 0.95))
                let foreground = glyph[index]
                let ratio = (max(backing, foreground) + 0.05) / (min(backing, foreground) + 0.05)
                check(ratio >= 4.5,
                      "REQ-19: Rendered \(label) reaches 4.5:1 in \(appearance.rawValue) (measured \(ratio):1)")
                check(!window.isVisible && !window.isKeyWindow && !operations.isBusy,
                      "REQ-19: Contrast fixture never presents a window or starts an operation")
            }
        }
    }

    private static func commerceAbsence(check: (Bool, String) -> Void) async throws {
        let catalogue = LibraryCatalogArtwork(transport: DetailPriorityTransport(priced: true))
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        guard let image = catalogue.images["FIXTURE00002"] else { throw PCGamesError.transport }
        let installed = InstalledGamesController()
        let operations = GameOperationsController(installed: installed)
        let game = PCGame(id: image.product.id, title: image.product.title, artwork: nil,
                          acquisitionKind: .purchased)
        let card = PCGameTile(game: game, installed: installed, operations: operations,
            catalog: catalogue, allowsArtworkLoading: false, viewDetails: {}, accessIsCurrent: true)
        let detail = LiveProductView(product: image.product, library: PCGamesController(),
            installedLibrary: installed, operations: operations, allowsStartupTasks: false,
            allowsArtworkLoading: false, catalog: catalogue).environmentObject(LiveSession())
        for (name, view) in [("catalogue card", AnyView(card)), ("product detail", AnyView(detail))] {
            let size = name == "catalogue card" ? CGSize(width: 280, height: 700) : CGSize(width: 1000, height: 1100)
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(.white))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PCGamesError.transport
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw PCGamesError.transport }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let showsInstall = labels.contains { $0.caseInsensitiveCompare("Install") == .orderedSame }
            check(labels.contains(where: { $0.localizedCaseInsensitiveContains("Synthetic game") })
                  && (name == "product detail" ? showsInstall : !showsInstall),
                  "REQ-61/85: Priced-fixture \(name) retains its title and exposes Install only in details (non-vacuous pixel guard)")
            check(!labels.contains(where: {
                let text = $0.lowercased()
                return text.contains("$") || text.contains("19.99") || text.contains("9.99")
                    || text.range(of: #"\b(buy|get|purchase|pre-order|claim)\b"#,
                                  options: .regularExpression) != nil
            }), "REQ-61: Priced-fixture \(name) exposes no price, Buy or acquisition action")
            check(!window.isVisible && !window.isKeyWindow,
                  "REQ-61: Rendered regression never presents or activates its synthetic window")
            window.contentView = nil
        }
    }

    private static func detailReadingOrder(check: (Bool, String) -> Void) async throws {
        let catalogue = LibraryCatalogArtwork(transport: DetailPriorityTransport(media: true))
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        guard let image = catalogue.images["FIXTURE00002"], let facts = image.detail else {
            throw PCGamesError.transport
        }
        check(facts.description == "Synthetic description." && facts.screenshots.count == 1 && facts.trailers.count == 1,
              "COR106/107: Reading-order fixture includes unchanged description, screenshot and trailer")
        let installed = InstalledGamesController()
        let operations = GameOperationsController(installed: installed)
        let detail = LiveProductView(product: image.product, library: PCGamesController(),
            installedLibrary: installed, operations: operations, allowsStartupTasks: false,
            allowsArtworkLoading: false, catalog: catalogue).environmentObject(LiveSession())
        let host = NSHostingView(rootView: detail.environment(\.colorScheme, .light).background(.white))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let document = scrollViews(host).compactMap(\.documentView).max(by: {
            $0.bounds.height < $1.bounds.height
        }), let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) else {
            throw PCGamesError.transport
        }
        document.cacheDisplay(in: document.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PCGamesError.transport }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rendered = context.makeImage() else { throw PCGamesError.transport }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: rendered).perform([request])
        let labels = (request.results ?? []).compactMap { result -> (String, Double)? in
            result.topCandidates(1).first.map { ($0.string, result.boundingBox.midY) }
        }
        let headings = ["Synthetic game", "About the game", "Screenshots", "Trailer"]
        let positions = headings.map { heading in labels.first { $0.0 == heading }?.1 }
        check(positions.allSatisfy { $0 != nil }
              && zip(positions.compactMap { $0 }, positions.compactMap { $0 }.dropFirst()).allSatisfy { $0.0 > $0.1 },
              "COR106/107: Actual detail reads hero -> About the game -> screenshots -> trailer; observed \(labels.map(\.0))")
        check(!window.isVisible && !window.isKeyWindow && !operations.isBusy,
              "COR106/107: Reading-order check uses no visible window, playback, downloads or operation")
    }

    private static func concurrency(check: (Bool, String) -> Void) async throws {
        func wait(_ transport: ControlledMetadataTransport, _ count: Int) async throws {
            for _ in 0..<200 {
                if await transport.count >= count { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw PCGamesError.transport
        }
        let transport = ControlledMetadataTransport()
        let catalogue = LibraryCatalogArtwork(transport: transport)
        let ids = (0..<20).map { String(format: "9META%07d", $0) }
        let bulk = Task { await catalogue.load(ids: ids, market: "US", language: "en-US") }
        try await wait(transport, 1)
        await transport.complete(0)
        await bulk.value
        check(catalogue.images.count == 20 && catalogue.revision == 1,
              "One 20-product response publishes one coherent public image/fact revision, not 20")
        let duplicate = Task { await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US") }
        try await wait(transport, 2)
        let joined = Task { await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US") }
        for _ in 0..<10 { await Task.yield() }
        let during = await transport.count
        check(during == 2, "Same-scope selected detail requests share one in-flight request")
        await transport.complete(1)
        await duplicate.value
        await joined.value
        check(catalogue.images["FIXTURE00002"]?.detail != nil,
              "Joined selected details both complete with the admitted public response")
        let failure = Task { await catalogue.load(ids: ["FIXTURE00003"], market: "US", language: "en-US") }
        try await wait(transport, 3)
        await transport.complete(2, status: 404)
        await failure.value
        check(catalogue.images.count == 21 && catalogue.error != nil,
              "Failed public refresh retains useful admitted metadata and reports failure, not empty success")
        let held = PCGame(id: "FIXTURE00003", title: "Held without metadata", artwork: nil)
        let fallback = LibraryGame.collection(installed: [], owned: [held], products: [],
            gamePass: [], active: false)[0]
        check(catalogue.error != nil && catalogue.images[held.id] == nil
              && fallback.title == held.title && fallback.cover == nil
              && fallback.facts.badgeLabels() == ["In your library"] && fallback.facts.support == .unknown
              && DiscoverBrowse.canReviewInstall(owned: fallback.pc != nil,
                accessIsCurrent: fallback.accessIsCurrent, gamePass: fallback.gamePass,
                subscriptionActive: false, pcCandidate: true),
              "REQ-50: Failed metadata/artwork preserves the shared title/badge fallback and current held review eligibility, not unsupported status")

        let queuedTransport = ControlledMetadataTransport()
        let queued = LibraryCatalogArtwork(transport: queuedTransport)
        let first = Task { await queued.load(ids: ["FIXTURE00001"], market: "US", language: "en-US") }
        try await wait(queuedTransport, 1)
        let second = Task { await queued.load(ids: ["FIXTURE00002"], market: "US", language: "en-US") }
        let third = Task { await queued.load(ids: ["FIXTURE00002"], market: "US", language: "en-US") }
        for _ in 0..<10 { await Task.yield() }
        await queuedTransport.complete(0)
        try await wait(queuedTransport, 2)
        for _ in 0..<10 { await Task.yield() }
        let queuedCount = await queuedTransport.count
        check(queuedCount == 2, "Multiple bulk waiters recheck the active owner; duplicate queued keys stay single-flight")
        await queuedTransport.complete(1)
        await first.value
        await second.value
        await third.value
        check(queued.images.count == 2, "Serialized bulk waiters complete without dropping useful earlier products")

        let abaTransport = ControlledMetadataTransport()
        let aba = LibraryCatalogArtwork(transport: abaTransport)
        let old = Task { await aba.load(ids: ["FIXTURE00001"], market: "US", language: "en-US") }
        try await wait(abaTransport, 1)
        let middle = Task { await aba.loadDetail(id: "FIXTURE00002", market: "GB", language: "en-GB") }
        try await wait(abaTransport, 2)
        await abaTransport.complete(1)
        await middle.value
        let current = Task { await aba.loadDetail(id: "FIXTURE00003", market: "US", language: "en-US") }
        try await wait(abaTransport, 3)
        await abaTransport.complete(2)
        await current.value
        await abaTransport.complete(0)
        await old.value
        check(Set(aba.images.keys) == ["FIXTURE00003"] && aba.images["FIXTURE00003"]?.product.market == "US",
              "A→B→A scope generation rejects an old A completion even when transport ignores cancellation")
    }
}

private actor ControlledMetadataTransport: PCGamesTransport {
    private var requests: [URLRequest] = []
    private var completions: [Int: CheckedContinuation<PCGamesHTTPResponse, Error>] = [:]
    var count: Int { requests.count }

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { completions[index] = $0 }
    }

    func complete(_ index: Int, status: Int = 200) {
        let items = URLComponents(url: requests[index].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = items.first(where: { $0.name == "bigIds" })?.value?.split(separator: ",") ?? []
        let products: [[String: Any]] = ids.map {
            ["ProductId": String($0), "LocalizedProperties": [
                ["ProductTitle": "Synthetic game", "Images": [], "ProductDescription": "Synthetic description."]
            ], "Properties": ["Categories": ["Games"]]]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["Products": products])
            completions.removeValue(forKey: index)?.resume(returning: PCGamesHTTPResponse(status: status, data: data))
        } catch { completions.removeValue(forKey: index)?.resume(throwing: error) }
    }
}
