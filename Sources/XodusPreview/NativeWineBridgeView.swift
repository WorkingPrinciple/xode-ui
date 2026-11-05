// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct NativeWineBridgeSettings: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame
    @Environment(\.dismiss) private var dismiss
    @State private var selection: NativeWineBridgeSelection?
    @State private var work: Task<Void, Never>?
    @State private var checking = false
    @State private var message: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native Wine diagnostic").font(.title2.bold())
            Text("Explicitly test \(game.title) with the exact source-pinned Heroic toolkit 3.0-3 export and original D3DMetal. This is generic Wine, not admitted Calimocho or verified game compatibility. Normal Play and your default engine do not change.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The native Highball bridge is unavailable because Ode cannot prove which engine store the Highball process uses when its supported HIGHBALL_HOME override may apply. An export snapshot is not current consent. Porting Kit is not available for a native bridge until a real wrapper exposes an exact, supported Wine/server, renderer, dependency and licence closure.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Uses the normal Xbox account, licence and private staging lifecycle, with a new Ode-owned prefix and a 120-second limit. Existing provider bottles, game files and saves are not imported. Review any native sign-in or Keychain prompt yourself.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose pinned Heroic bridge registry…", action: choose)
                .disabled(checking || !library.canTestWineBridge(game))
            if checking {
                ProgressView("Verifying complete files, links, published archives and generic Wine inspection")
                Button("Cancel check") {
                    work?.cancel()
                    selection = nil
                    checking = false
                    message = "Check cancelled. No game was started."
                }
            }
            if let message {
                Text(message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { work?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run diagnostic…") { confirming = true }
                    .disabled(checking || selection == nil || !library.canTestWineBridge(game))
            }
        }
        .padding(24).frame(width: 580)
        .onDisappear { work?.cancel() }
        .confirmationDialog("Run \(game.title) with experimental \(selection?.candidate.label ?? "Wine")?", isPresented: $confirming) {
            Button("Run 120-second native diagnostic") {
                guard let selection else { return }
                Task { await library.testWineBridge(game, selection: selection) }
                dismiss()
            }
        } message: {
            Text("No fallback or title-recipe transfer. The diagnostic is not recorded as Playing, playtime or tested-game success. Stop cancels its preflight or supervised launch.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose registry.json from an exact source-pinned bridge export, with recipe.json beside it."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let configuration = library.wineBridgeConfiguration else { return }
        work?.cancel()
        selection = nil
        checking = true
        message = "Bounded complete verification; no provider files or accounts are changed."
        work = Task {
            do {
                let selected = try await NativeWineBridgeSelection.select(registry: url, configuration: configuration)
                try Task.checkCancellation()
                selection = selected
                message = "\(selected.candidate.label) files verified, not game-qualified. Prefix: \(selected.prefix.path)"
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            checking = false
        }
    }
}
