// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct ExternalProviderOverview: View {
    var allowsCheck: Bool
    @State private var observations: [ExternalGameProvider: ExternalApplicationState] = [:]
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ExternalGameProvider.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(provider.label, value: (observations[provider] ?? .notChecked).label)
                        .font(.headline)
                    if case .detected(let app) = observations[provider] {
                        Text(app.location.path).font(.caption).textSelection(.enabled)
                    }
                    Text(description(provider))
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Get \(provider.label) from its official website", destination: provider.website)
                        .accessibilityIdentifier("xodus.engines.\(provider.rawValue).get")
                }
            }
            Button(checking ? "Checking external apps" : "Check external apps") { Task { await refresh() } }
                .disabled(checking || !allowsCheck)
                .accessibilityIdentifier("xodus.engines.external.refresh")
            Text("Configure a handoff from an installed game's Actions menu. These external launchers manage their own installations and licensing; they do not admit an Xbox runtime or replace your selected Calimocho engine. App detection does not verify game compatibility.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("These apps are checked against their publisher signatures. A selected game wrapper is user-directed, not publisher-verified.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func description(_ provider: ExternalGameProvider) -> String {
        switch provider {
        case .highball:
            "Open games already configured in Highball using its game links. Highball keeps control of its prompts, engine and bottle."
        case .portingKit:
            "Open an existing Porting Kit game app using its own Wineskin wrapper. Porting Kit is not Apple's Game Porting Toolkit."
        case .heroic:
            "Open games already configured in Heroic using an exact store and game ID. Heroic keeps control of its sign-in, runtime and installation prompts."
        }
    }

    private func refresh() async {
        guard allowsCheck, !checking else { return }
        checking = true
        defer { checking = false }
        for provider in ExternalGameProvider.allCases {
            observations[provider] = .checking
            let state = await Task.detached(priority: .utility) {
                ExternalApplicationDetector.detect(provider)
            }.value
            guard !Task.isCancelled, allowsCheck else {
                observations[provider] = .notChecked
                return
            }
            observations[provider] = state
        }
    }
}

struct ExternalGameHandoffSettings: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame
    @Environment(\.dismiss) private var dismiss
    @State private var gameLinks: [ExternalGameProvider: String] = [:]
    @State private var pendingOpen: ExternalGameProvider?

    private var current: InstalledGame {
        library.games.first(where: { $0.id == game.id }) ?? game
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("External launchers for \(game.title)").font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Link the same game and edition that you have already installed in the other app. Ode does not copy, decrypt or migrate the Xbox package, bottles, saves or sign-in. These handoffs leave the normal Play button unchanged.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach([ExternalGameProvider.highball, .heroic], id: \.self) { linkSection($0) }
                Section("Porting Kit") {
                    Text(handoff(.portingKit)?.target ?? "No game wrapper selected")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(3).truncationMode(.middle)
                    HStack {
                        Button("Choose game app…", action: chooseWrapper)
                        if handoff(.portingKit) != nil {
                            Button("Remove link") {
                                Task { await library.setExternalHandoff(nil, provider: .portingKit, for: game) }
                            }
                            Button("Open game wrapper…") { pendingOpen = .portingKit }
                        }
                    }
                    Text("Choose the game app created by Porting Kit, not Porting Kit itself or a Wine executable. The wrapper keeps its own launch settings and prefix.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!library.canUseExternalHandoff(game))
            if library.externalHandoffGameID == game.id {
                ProgressView("Handing off to external app").controlSize(.small)
            }
            if let message = library.externalHandoffMessages[game.id] {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.external.message")
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, idealWidth: 620, maxWidth: 680,
               minHeight: 520, idealHeight: 680, maxHeight: 760)
        .onAppear {
            for provider in [ExternalGameProvider.highball, .heroic] {
                gameLinks[provider] = handoff(provider)?.target ?? ""
            }
        }
        .confirmationDialog("Open \(game.title) externally?", isPresented: Binding(
            get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } }),
            presenting: pendingOpen) { provider in
                Button("Open with \(provider.label)") {
                    Task { await library.openExternalHandoff(provider, for: game) }
                }
            } message: { _ in
                Text("This starts the game configured in the selected external app, which may have its own prompts and save location. Ode won't mark it Playing or record a verified game result.")
            }
    }

    private func linkSection(_ provider: ExternalGameProvider) -> some View {
        Section(provider.label) {
            TextField("\(provider.label) game link", text: Binding(
                get: { gameLinks[provider] ?? "" }, set: { gameLinks[provider] = $0 }),
                prompt: Text(provider == .highball ? "highball://play/steam/…" : "heroic://launch/legendary/…"))
                .accessibilityIdentifier("xodus.external.\(provider.rawValue).link")
            Text(provider == .highball
                 ? "Use a Steam or Epic game link, or a pinned program link with its bottle name and UUID. Links with tokens or launcher-install actions are not accepted; Highball may ask you to confirm."
                 : "Use an existing Heroic game's link with its explicit runner: legendary (Epic), gog, nile (Amazon) or sideload. Extra arguments and alternate executable paths are not accepted.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save link") {
                    Task { await library.setExternalHandoff(gameLinks[provider], provider: provider, for: game) }
                }
                .disabled(gameLinks[provider]?.isEmpty != false)
                if handoff(provider) != nil {
                    Button("Remove link") {
                        Task { await library.setExternalHandoff(nil, provider: provider, for: game) }
                    }
                    Button("Open in \(provider.label)…") { pendingOpen = provider }
                }
            }
        }
    }

    private func handoff(_ provider: ExternalGameProvider) -> ExternalGameHandoff? {
        current.externalHandoffs?.first { $0.provider == provider }
    }

    private func chooseWrapper() {
        let panel = NSOpenPanel()
        panel.message = "Choose the game app created by Porting Kit. No files will be moved or changed."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await library.setExternalHandoff(url.path, provider: .portingKit, for: game) }
    }
}
