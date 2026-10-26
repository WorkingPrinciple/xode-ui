// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation

/// Decides when a Bonjour policy error really means local network access is off. macOS can report the
/// policy error (kDNSServiceErr_PolicyDenied, -65570) before the user answers the prompt (TN3179), so the
/// first one only means "waiting"; access counts as off only if it persists after a retry once the app is
/// active again.
struct LocalNetworkPermissionTracker: Equatable {
    enum State: Equatable { case idle, searching, waitingForAnswer, allowed, denied }
    static let policyDenied = -65570

    private(set) var state: State = .idle
    private(set) var retried = false

    mutating func start() {
        state = .searching
        retried = false
    }

    /// Returns true when the caller should retry once the app is active.
    mutating func searchFailed(code: Int, appActive: Bool) -> Bool {
        guard code == Self.policyDenied else { return false }
        if retried && appActive {
            state = .denied
            return false
        }
        state = .waitingForAnswer
        return true
    }

    mutating func retrying() { retried = true; state = .searching }
    mutating func searchSucceeded() { state = .allowed }
}

@MainActor
final class LocalNetworkDiscovery: ObservableObject {
    static let shared = LocalNetworkDiscovery()
    static var deniedStatus: String {
        "Local network access is off for \(AppBrand.displayName). Turn it on in \(PrivacyPermission.localNetwork.settingsLocation ?? "System Settings"), then choose Find consoles again."
    }
    static let waitingStatus = "Waiting for your answer to the macOS local network prompt…"
    @Published private(set) var status = "Local discovery has not been requested."
    @Published private(set) var tracker = LocalNetworkPermissionTracker()
    var denied: Bool { tracker.state == .denied }
    private var browser: NetServiceBrowser?
    private var observer: BrowserObserver?
    private var retryObserver: NSObjectProtocol?
    private var generation = 0
    var isAppActive: () -> Bool = { NSApp?.isActive ?? true }

    func search() {
        guard browser == nil else { return }
        tracker.start()
        startBrowsing()
    }

    private func startBrowsing() {
        generation += 1
        let token = generation
        let discovery = NetServiceBrowser()
        let observer = BrowserObserver(
            failed: { [weak self] code in Task { @MainActor in self?.didNotSearch(code: code, token: token) } },
            found: { [weak self] in Task { @MainActor in self?.didFind(token: token) } })
        discovery.delegate = observer
        browser = discovery
        self.observer = observer
        status = "Searching for local consoles. Approve the macOS local-network prompt if it appears."
        discovery.searchForServices(ofType: "_xbox._tcp.", inDomain: "local.")
        Task {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard generation == token, browser === discovery else { return }
            discovery.stop()
            browser = nil
            if tracker.state == .searching {
                tracker.searchSucceeded()
                status = "Local discovery attempted. No permission or console availability is inferred."
            }
        }
    }

    func didNotSearch(code: Int, token: Int? = nil) {
        if let token, token != generation { return }
        browser?.stop()
        browser = nil
        let retry = tracker.searchFailed(code: code, appActive: isAppActive())
        switch tracker.state {
        case .denied: status = Self.deniedStatus
        case .waitingForAnswer where retry:
            status = Self.waitingStatus
            scheduleRetry()
        default: status = "Local discovery couldn't start (code \(code)). Try again."
        }
    }

    func didFind(token: Int? = nil) {
        if let token, token != generation { return }
        tracker.searchSucceeded()
        status = "Found an Xbox console on your local network."
    }

    /// Retries when the app is active again (after the user answers the prompt) or after a short wait.
    private func scheduleRetry() {
        let retry: @MainActor () -> Void = { [weak self] in
            guard let self, self.tracker.state == .waitingForAnswer, self.browser == nil else { return }
            if let observer = self.retryObserver { NotificationCenter.default.removeObserver(observer) }
            self.retryObserver = nil
            self.tracker.retrying()
            self.startBrowsing()
        }
        retryObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                               object: nil, queue: .main) { _ in
            Task { @MainActor in retry() }
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if isAppActive() { retry() }
        }
    }

    /// Check-only seam: performs the retry immediately.
    func retryNow() {
        guard tracker.state == .waitingForAnswer else { return }
        tracker.retrying()
        browser?.stop()
        browser = nil
        status = "Searching for local consoles. Approve the macOS local-network prompt if it appears."
    }
}

private final class BrowserObserver: NSObject, NetServiceBrowserDelegate {
    let failed: @Sendable (Int) -> Void
    let found: @Sendable () -> Void
    init(failed: @escaping @Sendable (Int) -> Void, found: @escaping @Sendable () -> Void) {
        self.failed = failed
        self.found = found
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        failed(errorDict[NetService.errorCode]?.intValue ?? 0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        found()
    }
}
