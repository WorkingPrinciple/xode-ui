// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class LocalNetworkDiscovery: ObservableObject {
    static let shared = LocalNetworkDiscovery()
    @Published private(set) var status = "Local discovery has not been requested."
    private var browser: NetServiceBrowser?

    func search() {
        guard browser == nil else { return }
        let discovery = NetServiceBrowser()
        browser = discovery
        status = "Searching for local consoles. Approve the macOS local-network prompt if it appears."
        discovery.searchForServices(ofType: "_xbox._tcp.", inDomain: "local.")
        Task {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { discovery.stop(); browser = nil; return }
            discovery.stop()
            browser = nil
            status = "Local discovery attempted. No permission or console availability is inferred."
        }
    }
}
