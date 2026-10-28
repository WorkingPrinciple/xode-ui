// SPDX-License-Identifier: GPL-3.0-only
#if !ODE_SHIPPING
import AppKit
import CoreFoundation
import Foundation
import SwiftUI
import OdeManagement

/// Synthetic search timing harness. It drives the real LiveSession against the
/// OdeManagementChecks fixture backend and renders LiveCatalogView into a detached
/// hosting view; it never opens a window, reads an account or contacts a service.
@MainActor
enum SearchPerformanceChecks {
    static func launch() -> Never {
        Task {
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Search benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
        CFRunLoopRun()
        fatalError("Search benchmark run loop ended")
    }

    /// Records the largest main run-loop stall while a measured interval runs.
    @MainActor final class HitchMonitor {
        private var timer: Timer?
        private var last = ContinuousClock.now
        private(set) var maxGap = Duration.zero
        private(set) var hitches = 0

        func start() {
            last = .now
            maxGap = .zero
            hitches = 0
            let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = ContinuousClock.now
            let gap = now - last
            last = now
            if gap > maxGap { maxGap = gap }
            if gap > .milliseconds(17) { hitches += 1 }
        }

        func stop() {
            tick()
            timer?.invalidate()
            timer = nil
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15).rounded()
    }

    private static func configuration(_ scenario: String) -> BackendConfiguration {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("OdeManagementChecks")
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("OdeSearchPerformance-\(UUID().uuidString)").appendingPathComponent(scenario)
        return BackendConfiguration(executable: executable, stateDirectory: state)
    }

    /// Drives LiveRootView's per-keystroke catalogue entry point, including SwiftUI's
    /// cancellation of the previous task identity on every edit.
    @MainActor final class TypingDriver {
        let session: LiveSession
        let render: (String) -> Void
        private var task: Task<Void, Never>?
        private(set) var renderCost = Duration.zero
        private(set) var worstRender = Duration.zero

        init(session: LiveSession, render: @escaping (String) -> Void) {
            self.session = session
            self.render = render
        }

        func edit(_ query: String) {
            let start = ContinuousClock.now
            render(query)
            let cost = ContinuousClock.now - start
            renderCost += cost
            worstRender = max(worstRender, cost)
            task?.cancel()
            let session = session
            task = Task { @MainActor in await session.loadCatalogAfterInput(query) }
        }

        func type(_ text: String, after prefix: String = "", gap: Duration = .milliseconds(90)) async throws {
            var typed = prefix
            for character in text {
                typed.append(character)
                edit(typed)
                try await Task.sleep(for: gap)
            }
        }
    }

    static func firstResult(_ session: LiveSession, query: String, since start: ContinuousClock.Instant,
                            deadline: Duration = .seconds(20)) async throws -> Duration {
        while ContinuousClock.now - start < deadline {
            if session.catalogMatches(query: query), session.products.first?.title.hasPrefix(query) == true {
                return ContinuousClock.now - start
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        FileHandle.standardError.write(Data("No result for \(query): matches=\(session.catalogMatches(query: query)) searching=\(session.searching) error=\(session.catalogError ?? "none") titles=\(session.products.map(\.title))\n".utf8))
        throw ManagementError.requestTimedOut
    }

    /// REQ-107 cache/debounce/fence regressions against the single-slot, 2 s fixture producer.
    static func queryCache(configuration: (String) -> BackendConfiguration,
                           check: (Bool, String) -> Void) async throws {
        let config = configuration("querycoalesce")
        try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
        let session = LiveSession(configuration: config)
        await session.connect()
        defer { try? FileManager.default.removeItem(at: config.stateDirectory.deletingLastPathComponent()) }
        check(!session.hasRecentQueryResult("Original alpha"), "REQ-107: An unseen query has no remembered result")
        await session.loadCatalogAfterInput("Original alpha")
        let first = session.products.first?.title
        check(first == "Original alpha [requests=1,max=1]" && session.hasRecentQueryResult(" Original alpha "),
              "REQ-107: A completed query is remembered for its account, market and language scope")
        await session.loadCatalogAfterInput("Original beta")
        let start = ContinuousClock.now
        await session.loadCatalogAfterInput("Original alpha")
        let repeatCost = ContinuousClock.now - start
        check(session.products.first?.title == first && !session.searching && session.catalogError == nil
              && session.catalogMatches(query: "Original alpha") && repeatCost < .milliseconds(100),
              "REQ-107: Repeating a remembered query publishes without debounce or a producer read (\(milliseconds(repeatCost)) ms)")
        let slow = Task { await session.loadCatalogOnEntry("Original slow") }
        try await waitUntil { session.searching }
        await session.loadCatalogAfterInput("Original beta")
        check(session.catalogMatches(query: "Original beta") && !session.searching
              && session.products.first?.title == "Original beta [requests=2,max=1]",
              "REQ-107: New input publishes a remembered result immediately while an older read is in flight")
        await slow.value
        check(session.catalogMatches(query: "Original beta")
              && session.products.first?.title == "Original beta [requests=2,max=1]",
              "REQ-107: The superseded in-flight read is fenced and never replaces the newer result")
        await session.refreshCatalog("Original alpha")
        check(session.products.first?.title == "Original alpha [requests=4,max=1]",
              "REQ-107: Explicit Retry/Refresh bypasses remembered results and replaces them")
        let typed = Task { await session.loadCatalogAfterInput("Original abandoned") }
        try await Task.sleep(for: .milliseconds(40))
        typed.cancel()
        await typed.value
        check(session.catalogMatches(query: "Original alpha") && !session.searching,
              "REQ-107: An edit superseded during debounce sends no producer read")
        session.market = "FR"
        session.language = "fr-FR"
        check(!session.hasRecentQueryResult("Original alpha") && session.recentQueryResultCount == 0,
              "REQ-101/107: Market or language change retires remembered results")
        check(await session.disconnect() && session.recentQueryResultCount == 0,
              "REQ-107: Disconnect retires remembered results")
        var cache = LiveSession.CatalogQueryResultCache()
        let snapshot = LiveSession.CatalogQuerySnapshot(products: [], failures: [], nextCursor: nil,
            sourceFailure: nil, checkedAt: nil, corpus: "publicMicrosoftStoreSearch", storedAt: .now)
        for index in 0...LiveSession.CatalogQueryResultCache.capacity { cache.store(snapshot, for: "key\(index)") }
        check(cache.count == LiveSession.CatalogQueryResultCache.capacity && cache.fresh("key0") == nil
              && cache.fresh("key\(LiveSession.CatalogQueryResultCache.capacity)") != nil
              && cache.fresh("key1", now: .now + LiveSession.CatalogQueryResultCache.lifetime) == nil,
              "REQ-107: Remembered results are bounded by count and age")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Writes detached PNGs of the results and loading states. No toolbar or window chrome is
    /// included; these show content layout and backdrop only, not installed-app appearance.
    private static func renderEvidence(session: LiveSession, state: AppState, directory: URL) throws -> [String] {
        var written: [String] = []
        // Fixture products carry no compatibility evidence; show them through an isolated
        // defaults suite instead of changing any real preference.
        let suiteName = "OdeSearchEvidence-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return [] }
        defaults.set(true, forKey: LibrarySupportVisibility.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func snapshot(_ query: String, name: String) throws {
            for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                for width in [CGFloat(820), CGFloat(1440)] {
                    let host = NSHostingView(rootView: ScrollView {
                        LiveCatalogView(library: state.pcGames, installed: state.installedGames,
                            operations: state.gameOperations, query: query, allowsArtworkLoading: false,
                            allowsStartupTasks: true, allowsHeroAnimation: false, clearSearch: {},
                            selection: state.discoverSelection)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .defaultAppStorage(defaults)
                    .environmentObject(session))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = directory.appendingPathComponent("search-\(name)-\(label)-\(Int(width)).png")
                    try rep.representation(using: .png, properties: [:])?.write(to: url)
                    written.append(url.lastPathComponent)
                }
            }
        }
        let pending = Task { await session.loadCatalogOnEntry("Original pending") }
        try snapshot("Original pending", name: "loading")
        pending.cancel()
        return written
    }

    static func run() async throws {
        var report: [String: Any] = [
            "harness": "synthetic fixture backend; detached rendering; not installed-app acceptance",
            "debounceMs": milliseconds(CatalogSearchTiming.debounce)
        ]
        // querycoalesce: one producer slot and a fixed 2 s synthetic producer latency.
        let latency = configuration("querycoalesce")
        try FileManager.default.createDirectory(at: latency.stateDirectory, withIntermediateDirectories: true)
        let session = LiveSession(configuration: latency)
        await session.connect()
        guard session.isReady else { throw ManagementError.invalidPayload }
        let state = AppState()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 874)
        func render(_ query: String) {
            host.rootView = AnyView(LiveCatalogView(library: state.pcGames, installed: state.installedGames,
                operations: state.gameOperations, query: query, allowsArtworkLoading: false,
                allowsStartupTasks: false, allowsHeroAnimation: false, clearSearch: {},
                selection: state.discoverSelection).environmentObject(session))
            // SwiftUI graph update and layout only: detached CPU rasterization is not the
            // compositor path the window uses, so it would overstate main-thread cost.
            host.layoutSubtreeIfNeeded()
        }
        let driver = TypingDriver(session: session, render: render)
        let monitor = HitchMonitor()

        // Discover browse is already on screen before the first keystroke in the app.
        render("")
        monitor.start()
        try await driver.type("forza")
        var start = ContinuousClock.now
        let cold = try await firstResult(session, query: "forza", since: start)
        render("forza")
        monitor.stop()
        report["coldFirstResultMs"] = milliseconds(cold)
        report["coldMaxMainGapMs"] = milliseconds(monitor.maxGap)
        report["coldMainHitches"] = monitor.hitches

        try await driver.type("halo")
        _ = try await firstResult(session, query: "halo", since: .now)
        monitor.start()
        try await driver.type("forza", gap: .milliseconds(60))
        start = ContinuousClock.now
        let repeated = try await firstResult(session, query: "forza", since: start)
        render("forza")
        monitor.stop()
        report["repeatFirstResultMs"] = milliseconds(repeated)
        report["repeatMaxMainGapMs"] = milliseconds(monitor.maxGap)

        // A pause long enough to send a prefix, then the remaining characters.
        monitor.start()
        try await driver.type("hol")
        try await Task.sleep(for: .milliseconds(400))
        try await driver.type("low", after: "hol")
        start = ContinuousClock.now
        let superseded = try await firstResult(session, query: "hollow", since: start)
        render("hollow")
        monitor.stop()
        report["supersededFirstResultMs"] = milliseconds(superseded)
        report["supersededMaxMainGapMs"] = milliseconds(monitor.maxGap)
        report["supersededMainHitches"] = monitor.hitches
        if let directory = ProcessInfo.processInfo.environment["ODE_SEARCH_EVIDENCE"] {
            let url = URL(fileURLWithPath: directory)
            report["evidence"] = try renderEvidence(session: session, state: state, directory: url)
        }
        report["keystrokeRenderWorstMs"] = milliseconds(driver.worstRender)
        report["keystrokeRenderTotalMs"] = milliseconds(driver.renderCost)
        _ = await session.disconnect()
        try? FileManager.default.removeItem(at: latency.stateDirectory.deletingLastPathComponent())
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                     as: UTF8.self))
    }
}
#endif
