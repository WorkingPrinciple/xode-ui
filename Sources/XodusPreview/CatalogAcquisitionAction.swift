// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct CatalogAcquisitionAction: View {
    let productID: String
    let title: String
    let market: String
    let language: String
    let licensed: Bool
    let gamePass: Bool
    let commerce: CatalogCommerce?
    var enabled = true
    @State private var confirming = false
    @State private var consent = CatalogAcquisitionConsent()
    @State private var error: String?

    private var kind: CatalogAcquisition.Kind? {
        CatalogAcquisition.kind(licensed: licensed, gamePass: gamePass, commerce: commerce)
    }

    var body: some View {
        if let kind {
            Button(kind.label, systemImage: "arrow.up.right.square") {
                consent.request()
                confirming = true
            }
                .modifier(LibraryActionStyle(primary: false))
                .accessibilityIdentifier("xodus.catalog.acquireExternal")
                .disabled(!enabled || consent.authorization != nil)
                .help("Opens the game's verified Xbox page. Ode to X cannot claim a licence or make purchases.")
                .confirmationDialog("Open \(title) on xbox.com?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Open xbox.com") { consent.confirm() }
                    Button("Cancel", role: .cancel) { consent.cancel() }
                } message: {
                    Text(kind == .free
                         ? "The public PC catalogue lists the full game as free. Xbox must confirm current eligibility and the signed-in account. Ode to X will not claim a licence or buy anything. Do not proceed if Xbox asks for payment. Return and refresh your PC library after getting the game."
                         : "This is a Game Pass catalogue title, not a verified account licence. Xbox must confirm your subscription and availability. Ode to X will not claim a licence or buy anything. Do not purchase a game or subscription. Return and refresh your PC library after getting access.")
                }
                .task(id: consent.authorization) {
                    guard consent.authorization != nil else { return }
                    defer { consent.finish() }
                    guard enabled, CatalogAcquisition.kind(
                        licensed: licensed, gamePass: gamePass, commerce: commerce) != nil else {
                        error = "Game access changed. Refresh your library before opening Xbox. No page or licence was changed."
                        return
                    }
                    do {
                        let url = try await XboxProductLink.resolve(
                            productID: productID, market: market, language: language)
                        try Task.checkCancellation()
                        guard enabled, !licensed else { return }
                        guard NSWorkspace.shared.open(url) else {
                            error = "Your browser couldn't open the verified Xbox game page. No licence or purchase was attempted."
                            return
                        }
                    } catch is CancellationError { }
                    catch {
                        self.error = "The Xbox game page couldn't be verified for \(language). No page was opened and no licence or purchase was attempted. \(error.localizedDescription)"
                    }
                }
                .alert("Xbox page couldn't be opened", isPresented: Binding(
                    get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
