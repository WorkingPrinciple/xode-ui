// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class LocalNetworkDiscovery: ObservableObject {
    static let shared = LocalNetworkDiscovery()
    static var deniedStatus: String { "Local network access is off for \(AppBrand.displayName). Turn it on in System Settings ▸ Privacy & Security ▸ Local Network, then choose Find consoles again." }
    @Published private(set) var status = "Local discovery has not been requested."
    @Published private(set) var denied = false
    private var browser: NetServiceBrowser?
    private var observer: BrowserObserver?

    func search() {
        guard browser == nil else { return }
        let discovery = NetServiceBrowser()
        let observer = BrowserObserver { [weak self] code in
            Task { @MainActor in self?.didNotSearch(code: code) }
        }
        discovery.delegate = observer
        browser = discovery
        self.observer = observer
        denied = false
        status = "Searching for local consoles. Approve the macOS local-network prompt if it appears."
        discovery.searchForServices(ofType: "_xbox._tcp.", inDomain: "local.")
        Task {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { discovery.stop(); browser = nil; return }
            discovery.stop()
            guard browser === discovery else { return }
            browser = nil
            if !denied {
                status = "Local discovery attempted. No permission or console availability is inferred."
            }
        }
    }

    /// Bonjour reports a privacy denial as a policy error (kDNSServiceErr_PolicyDenied, -65570).
    static func isPolicyDenial(_ code: Int) -> Bool { code == -65570 }

    func didNotSearch(code: Int) {
        browser?.stop()
        browser = nil
        if Self.isPolicyDenial(code) {
            denied = true
            status = Self.deniedStatus
        } else {
            status = "Local discovery couldn't start (code \(code)). Try again."
        }
    }
}

private final class BrowserObserver: NSObject, NetServiceBrowserDelegate {
    let failed: @Sendable (Int) -> Void
    init(failed: @escaping @Sendable (Int) -> Void) { self.failed = failed }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        failed(errorDict[NetService.errorCode]?.intValue ?? 0)
    }
}
