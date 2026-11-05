// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusManagement

/// REQ-188: Library tiles show the matching game's real install, repair or uninstall activity.
/// Pure projection transitions plus offscreen native renders (never-shown borderless windows).
@MainActor
enum LibraryActivityChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        transitions(check: check)
        try await rendering(check: check)
    }

    private static let id = "9NBLGGH4R315"
    private static func progress(_ phase: GameScriptProgress.Phase, _ done: Int64, _ total: Int64?) -> GameScriptProgress {
        GameScriptProgress(phase: phase, bytesDone: done, bytesTotal: total, message: nil)
    }
    private static func job(_ phase: InstallPhase, product: String = id, done: Int64? = nil,
                            total: Int64? = nil) -> InstallJob {
        var value = InstallJob(productID: product, title: "Synthetic")
        value.phase = phase
        value.progress = done.flatMap { InstallProgress(bytesDone: $0, bytesTotal: total) }
        return value
    }

    static func transitions(check: (Bool, String) -> Void) {
        typealias Ops = LibraryActivity.Operations
        func resolve(_ ops: Ops, _ jobs: [InstallJob] = [], product: String = id) -> LibraryActivity? {
            LibraryActivity.resolve(productID: product, operations: ops, jobs: jobs)
        }
        let idle = Ops()
        check(resolve(idle) == nil, "REQ-188: An idle product shows no Library activity")

        let queued = resolve(idle, [job(.queued)])
        check(queued?.state == .queued && queued?.title == "Queued" && queued?.isInFlight == true,
              "REQ-188: A waiting queue job shows Queued on its tile")

        for kind in [GameOperationRecord.Kind.install, .repair, .resume] {
            let entry = QueuedGameInstall(record: GameOperationRecord(id: InstalledGamesController.runID(),
                kind: kind, productID: id, title: "Synthetic", destination: "/Synthetic/Game",
                installedID: kind == .install ? nil : UUID()), storageVolume: nil)
            let waiting = Ops(queuedInstalls: [entry])
            check(resolve(waiting)?.state == .queued && resolve(waiting)?.kind == LibraryActivity.Kind(kind)
                  && resolve(waiting)?.fraction == nil && resolve(waiting, product: "UNRELATED001") == nil,
                  "REQ-188: Production \(kind) queue projects only its matching product and operation kind")
            var paused = waiting
            paused.installQueuePaused = true
            check(resolve(paused)?.state == .paused,
                  "REQ-188: Production \(kind) queue pause is not reported as active progress")
            var active = waiting
            active.operation = .repair
            active.operationProductID = id
            active.progress = progress(.downloading, 42, 100)
            check(resolve(active)?.title == "Repairing 42%",
                  "REQ-188: Active producer work wins over a waiting production \(kind) request")
        }

        var running = Ops(operation: .install, operationProductID: id, feedbackProductID: id, feedbackKind: .install)
        let starting = resolve(running)
        check(starting?.state == .active(phase: nil, fraction: nil) && starting?.title == "Installing"
              && starting?.fraction == nil && starting?.percent == nil,
              "REQ-188: An install without reported progress stays indeterminate")

        running.progress = progress(.downloading, 420, nil)
        let unknownTotal = resolve(running)
        check(unknownTotal?.fraction == nil && unknownTotal?.title == "Installing"
              && unknownTotal?.accessibilityText == "Installing. Downloading. Details in Downloads",
              "REQ-188: Bytes without a total never become a fabricated percentage")

        running.progress = progress(.downloading, 0, 0)
        check(resolve(running)?.fraction == nil, "REQ-188: A zero byte total stays indeterminate")

        running.progress = progress(.downloading, 42, 100)
        let downloading = resolve(running)
        check(downloading?.fraction == 0.42 && downloading?.title == "Installing 42%"
              && downloading?.accessibilityText == "Installing 42%. Downloading. Details in Downloads"
              && !(downloading?.accessibilityText.localizedCaseInsensitiveContains("remaining") ?? true)
              && !(downloading?.accessibilityText.localizedCaseInsensitiveContains("min") ?? true),
              "REQ-188: Reported bytes show a real percentage and no ETA is invented")
        check(resolve(running, product: "9NBLGGH0THER") == nil,
              "REQ-188: Activity appears only on the matching game")
        check(resolve(running, [job(.queued)])?.fraction == 0.42,
              "REQ-188: The live operation wins over a queue record for the same game")

        running.cancelling = true
        check(resolve(running)?.state == .stopping && resolve(running)?.title == "Stopping…",
              "REQ-188: Cancelling shows Stopping until the producer reports the outcome")
        running.cancelling = false
        running.recoveryRequired = true
        check(resolve(running)?.state == .needsCheck && resolve(running)?.isInFlight == false,
              "REQ-188: An interrupted operation shows Needs checking, not progress")

        let completed = Ops(feedbackProductID: id, feedbackKind: .install, notice: "Synthetic was installed.")
        check(resolve(completed)?.state == .completed && resolve(completed)?.title == "Installed",
              "REQ-188: A successful install shows Installed")
        let repaired = Ops(feedbackProductID: id, feedbackKind: .repair, notice: "Synthetic is ready to play.")
        check(resolve(repaired)?.title == "Repaired", "REQ-188: A successful repair shows Repaired")
        let failed = Ops(feedbackProductID: id, feedbackKind: .install, error: "Download failed.", failureCode: 11)
        check(resolve(failed)?.state == .failed && resolve(failed)?.title == "Installation failed",
              "REQ-188: A failed install shows Installation failed")
        let cancelled = Ops(feedbackProductID: id, feedbackKind: .repair,
                            notice: "Repair cancelled. Partial files are kept.", failureCode: 14)
        check(resolve(cancelled)?.state == .cancelled && resolve(cancelled)?.title == "Repair cancelled",
              "REQ-188: Exit code 14 shows a cancellation, never success")
        let unexplained = Ops(feedbackProductID: id, feedbackKind: .install, failureCode: 3)
        check(resolve(unexplained) == nil,
              "REQ-188: A terminal state without an outcome message stays unknown instead of guessed")
        let unrelatedFeedback = Ops(feedbackProductID: id, error: "Compatibility couldn't be checked.")
        check(resolve(unrelatedFeedback) == nil,
              "REQ-188: Feedback that did not come from an install, repair or uninstall is not shown as one")

        var uninstall = Ops(operation: .uninstall, operationProductID: id, progress: progress(.configuring, 0, nil))
        check(resolve(uninstall)?.title == "Uninstalling"
              && resolve(uninstall)?.accessibilityText == "Uninstalling. Details in Downloads",
              "REQ-188: Uninstall does not borrow install phase wording")
        uninstall = Ops(feedbackProductID: id, feedbackKind: .uninstall, notice: "Synthetic was uninstalled.")
        check(resolve(uninstall)?.title == "Uninstalled", "REQ-188: A finished uninstall shows Uninstalled")
        let resumed = Ops(operation: .resume, operationProductID: id)
        check(resolve(resumed)?.title == "Installing", "REQ-188: A resumed install reads as installing")

        let preparing = Ops(installingDirectly: true, directInstallProductID: id)
        check(resolve(preparing)?.state == .preparing, "REQ-188: Pre-consent preparation shows Preparing")
        let stoppingPreparation = Ops(installingDirectly: true, directInstallProductID: id, directInstallCancelled: true)
        check(resolve(stoppingPreparation)?.state == .stopping, "REQ-188: Stopping preparation shows Stopping")

        let other = "9NBLGGH0THER"
        var concurrent = Ops(operation: .install, operationProductID: other,
                             progress: progress(.downloading, 42, 100),
                             installingDirectly: true, directInstallProductID: id)
        check(resolve(concurrent)?.state == .preparing
              && resolve(concurrent, product: other)?.title == "Installing 42%",
              "REQ-200: Another game's preparation and the active download remain visible together")
        concurrent.cancelling = true
        check(resolve(concurrent)?.state == .preparing
              && resolve(concurrent, product: other)?.state == .stopping
              && !GameInstallAction.isStopping(for: id, operations: concurrent)
              && GameInstallAction.isStopping(for: other, operations: concurrent),
              "REQ-200: Stopping the active download does not stop another game's preparation")
        concurrent.cancelling = false
        concurrent.directInstallCancelled = true
        check(resolve(concurrent)?.state == .stopping
              && resolve(concurrent, product: other)?.title == "Installing 42%"
              && GameInstallAction.isStopping(for: id, operations: concurrent)
              && !GameInstallAction.isStopping(for: other, operations: concurrent),
              "REQ-200: Stopping preparation does not stop another game's active download")
        concurrent.directInstallProductID = other
        check(resolve(concurrent, product: other)?.title == "Installing 42%",
              "REQ-200: The active operation keeps precedence for the same product")
        concurrent.installingDirectly = false
        concurrent.directInstallProductID = nil
        check(!GameInstallAction.isStopping(for: other, operations: concurrent),
              "REQ-200: A finished preparation's stale cancellation flag does not disable a later download")

        check(resolve(idle, [job(.downloading, done: 30, total: 120)])?.title == "Installing 25%",
              "REQ-188: Queue progress with a known total shows its percentage")
        check(resolve(idle, [job(.verifying, done: 30, total: nil)])?.fraction == nil,
              "REQ-188: Queue progress without a total stays indeterminate")
        let stoppingJob = job(.downloading, done: 30, total: 120)
        let pendingActivity = LibraryActivity.resolve(productID: id, operations: idle, jobs: [stoppingJob],
                                                      stoppingJobIDs: [stoppingJob.id])
        check(pendingActivity?.state == .stopping && pendingActivity?.fraction == nil
              && LibraryActivity.resolve(productID: id, operations: idle, jobs: [stoppingJob],
                                         stoppingJobIDs: [UUID()])?.title == "Installing 25%",
              "REQ-188: Pending queue stops are shown only on the matching job")
        check(resolve(idle, [job(.paused)])?.title == "Paused", "REQ-188: A paused queue job shows Paused")
        check(resolve(idle, [job(.failed)])?.title == "Installation failed"
              && resolve(idle, [job(.completed)])?.title == "Installed"
              && resolve(idle, [job(.cancelled)])?.title == "Installation cancelled",
              "REQ-188: Finished queue jobs keep their terminal state")
        check(resolve(idle, [job(.completed), job(.queued)])?.state == .queued,
              "REQ-188: A live queue job outranks an older finished one")
        check(resolve(completed, [job(.failed)])?.state == .completed,
              "REQ-188: The operation outcome outranks a stale finished queue record")

        let controller = GameOperationsController(installed: InstalledGamesController())
        check(LibraryActivity.resolve(productID: id, operations: LibraryActivity.Operations(controller)) == nil
              && controller.feedbackKind == nil,
              "REQ-188: A fresh operations controller projects no tile activity")
    }

    private static func render<V: View>(_ view: V, size: CGSize,
                                        appearance: NSAppearance.Name = .aqua) async throws -> (NSWindow, NSHostingView<AnyView>, CGImage) {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PCGamesError.transport }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw PCGamesError.transport }
        return (window, host, image)
    }

    private static func tileLabelFailures(_ text: String, image: CGImage, size: CGSize,
                                          appearance: NSAppearance.Name = .aqua,
                                          title: Bool = false) throws -> [String] {
        let scale = CGFloat(image.width) / size.width
        guard abs(CGFloat(image.height) / size.height - scale) < 0.001 else { throw PCGamesError.transport }
        let titleTop = 16 + (size.width - 32) * 1.5 + 10
        let region: CGRect
        let style: RenderedLabel.Style
        if title {
            region = CGRect(x: 16, y: titleTop - 2, width: size.width - 32, height: 40)
            style = .headline
        } else {
            // Exclude the status icon and Downloads button, but reject extra text in the row.
            region = CGRect(x: 32, y: titleTop + 43, width: size.width - 62, height: 24)
            style = .captionMedium
        }
        return try renderedLabelFailures(image, [.init(text, style, foreground: .primary)],
            textRegion: region.applying(CGAffineTransform(scaleX: scale, y: scale)),
            appearance: appearance == .darkAqua ? .dark : .light, scale: scale)
    }

    static func rendering(check: (Bool, String) -> Void) async throws {
        let active = LibraryActivity(kind: .install, state: .active(phase: "Downloading", fraction: 0.42))
        let failed = LibraryActivity(kind: .repair, state: .failed)
        var opened = 0
        func card(_ activity: LibraryActivity?) -> some View {
            GameCard(title: "Synthetic game", activity: activity, openLabel: "View", open: {}) {
                LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom)
            } status: {
                if let activity { LibraryActivityStatus(activity: activity, showDownloads: { opened += 1 }) }
            }
            .padding(16)
        }
        let standardSize = CGSize(width: 220, height: 420)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (activity, expected) in [(active, "Installing 42%"), (failed, "Repair failed")] {
                let (window, _, image) = try await render(card(activity), size: standardSize, appearance: appearance)
                defer { window.contentView = nil }
                try save(image, "tile-\(appearance == .aqua ? "light" : "dark")-\(activity.title)")
                let statusFailures = try tileLabelFailures(expected, image: image, size: standardSize,
                                                           appearance: appearance)
                let titleFailures = try tileLabelFailures("Synthetic game", image: image, size: standardSize,
                                                          appearance: appearance, title: true)
                check(statusFailures.isEmpty && titleFailures.isEmpty
                      && !window.isVisible && !window.isKeyWindow,
                      "REQ-188: \(appearance == .aqua ? "Light" : "Dark") tile renders \(expected) offscreen: "
                      + "\((statusFailures + titleFailures).joined(separator: "; "))")
            }
        }

        let narrowSize = CGSize(width: 150, height: 330)
        let narrow = try await render(card(active), size: narrowSize)
        defer { narrow.0.contentView = nil }
        try save(narrow.2, "tile-narrow")
        let narrowFailures = try tileLabelFailures("Installing 42%", image: narrow.2, size: narrowSize)
        let wrongProgress = try tileLabelFailures("Installing 43%", image: narrow.2, size: narrowSize)
        let missingPercent = try tileLabelFailures("Installing 42", image: narrow.2, size: narrowSize)
        check(!wrongProgress.isEmpty && !missingPercent.isEmpty,
              "REQ-188: The rendered-label check rejects a changed digit or omitted percent glyph")
        check(active.title == "Installing 42%" && narrowFailures.isEmpty
              && narrow.1.frame.width == 150 && !narrow.0.isVisible,
              "REQ-188: A narrow resized tile keeps the activity readable without widening: \(narrowFailures)")

        let indeterminate = LibraryActivity(kind: .install, state: .active(phase: "Downloading", fraction: nil))
        let narrowUnknown = try await render(card(indeterminate), size: narrowSize)
        defer { narrowUnknown.0.contentView = nil }
        try save(narrowUnknown.2, "tile-narrow-indeterminate")
        let unknownFailures = try tileLabelFailures("Installing", image: narrowUnknown.2, size: narrowSize)
        let unknownPercentage = try tileLabelFailures("Installing 42%", image: narrowUnknown.2, size: narrowSize)
        check(indeterminate.title == "Installing"
              && unknownFailures.isEmpty && !unknownPercentage.isEmpty,
              "REQ-188: A narrow indeterminate tile does not satisfy the percentage assertion: \(unknownFailures)")

        let concurrent = LibraryActivity.Operations(operation: .install, operationProductID: "9NBLGGH0THER",
            progress: progress(.downloading, 42, 100), cancelling: true,
            installingDirectly: true, directInstallProductID: id)
        let concurrentPreparation = LibraryActivity.resolve(productID: id, operations: concurrent)
        let concurrentTile = try await render(card(concurrentPreparation), size: standardSize)
        defer { concurrentTile.0.contentView = nil }
        let concurrentFailures = try tileLabelFailures("Preparing", image: concurrentTile.2, size: standardSize)
        let preparingCard = GameCard(title: "Synthetic game", activity: concurrentPreparation,
                                    openLabel: "View", open: {}) { Color.gray } status: { EmptyView() }
        check(concurrentFailures.isEmpty
              && preparingCard.coverStatusDescription == "Preparing. Details in Downloads"
              && !concurrentTile.0.isVisible,
              "REQ-200: Another game's preparation is rendered and exposed accessibly: \(concurrentFailures)")

        let plain = GameCard(title: "Synthetic game", activity: nil, open: {}) { Color.gray } status: { EmptyView() }
        let busy = GameCard(title: "Synthetic game", activity: active, openLabel: "View", open: {}) { Color.gray } status: { EmptyView() }
        check(plain.coverStatusDescription.isEmpty
              && busy.coverStatusDescription == "Installing 42%. Downloading. Details in Downloads"
              && busy.artworkAccessibilityLabel == "View Synthetic game",
              "REQ-188: VoiceOver hears the tile activity while the open label is unchanged")

        LibraryActivityStatus(activity: active, showDownloads: { opened += 1 }).showDownloads()
        check(opened == 1, "REQ-188: The tile routes to Downloads for details")
    }

    /// Writes a render for review when `XODUS_UX_RENDER_DIRECTORY` is set.
    private static func save(_ image: CGImage, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["XODUS_UX_RENDER_DIRECTORY"] else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("req188-\(name).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PCGamesError.transport
        }
        try data.write(to: file, options: .atomic)
    }
}
