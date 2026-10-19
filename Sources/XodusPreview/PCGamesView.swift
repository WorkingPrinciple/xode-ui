// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct PCGamesView: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let query: String
    var allowsStartupTasks = true
    var showsCollection = true
    let browse: () -> Void
    let recentActivity: () -> Void

    private var visibleGames: [PCGame] {
        library.representedGames.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if library.needsKeychainApproval {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Ode to X needs one-time Keychain approval.", systemImage: "key")
                        .font(.headline)
                    Text("Approve the Ode to X credential helper to move your saved PC-games sign-in into its protected storage. The helper stays unchanged when Ode to X updates. Updating the helper itself may require another approval.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if library.approvingKeychain {
                        ProgressView("Waiting for Keychain approval").controlSize(.small)
                        Button("Cancel approval") { Task { await library.cancelKeychainApproval() } }
                    } else {
                        Button("Approve Keychain access") { library.approveKeychain() }
                            .buttonStyle(.borderedProminent)
                            .disabled(library.busy || library.restoringPresence || library.presenceUnavailable)
                            .accessibilityIdentifier("xodus.pcGames.approveKeychain")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if library.legacyKeychainRetained {
                Label("Your sign-in is saved in the credential helper. An older Keychain item was retained; Ode to X won't retry removing it.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.pcGames.legacyKeychainRetained")
            }
            if library.presenceUnavailable {
                ContentUnavailableView {
                    Label("Saved sign-in unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Your saved PC-library sign-in couldn't be checked. No account was removed.")
                } actions: {
                    Button("Try again") { Task { await library.retryLibraryLoad() } }
                        .disabled(library.busy || library.restoringPresence)
                        .accessibilityIdentifier("xodus.pcGames.retryPresence")
                }
            } else if !library.hasSavedSignIn || library.needsSignIn {
                ContentUnavailableView {
                    Label("Sign in to see your PC games", systemImage: "gamecontroller")
                } description: {
                    Text("See the games in your Microsoft account that are available for PC.")
                        .frame(maxWidth: 520)
                } actions: {
                    Button(library.usesUnifiedAccount ? "Reload library" : "Sign in") {
                        if library.usesUnifiedAccount { Task { await library.retryLibraryLoad() } }
                        else { library.signIn() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.busy || library.restoringPresence || library.needsKeychainApproval)
                        .accessibilityIdentifier("xodus.pcGames.signIn")
                    Button("Browse games", action: browse)
                    Button("Recent activity", action: recentActivity)
                        .accessibilityIdentifier("xodus.library.openRecentActivity")
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                if showsCollection { HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Your PC games").font(.title.bold())
                    if showsCollection, let snapshot = library.snapshot {
                        Text("\(snapshot.games.count)").font(.title3).foregroundStyle(.secondary)
                            .accessibilityLabel("\(snapshot.games.count) PC games")
                    }
                    Spacer()
                    Button("Refresh") { library.refresh() }
                        .disabled(library.busy || library.restoringPresence || library.needsKeychainApproval)
                        .accessibilityIdentifier("xodus.pcGames.refresh")
                    Text("Manage sign-in in Account").font(.callout).foregroundStyle(.secondary)
                } }
                if library.busy && !library.approvingKeychain {
                    ProgressView("Loading your PC games").controlSize(.small)
                        .accessibilityIdentifier("xodus.pcGames.loading")
                }
                if let snapshot = library.snapshot {
                    if showsCollection, snapshot.games.isEmpty {
                        Text("No PC games were found in this account.").foregroundStyle(.secondary)
                    } else if showsCollection, visibleGames.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if showsCollection {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)], spacing: 28) {
                            ForEach(visibleGames) { game in
                                PCGameTile(game: game, installed: installed, operations: operations,
                                           allowsArtworkLoading: allowsStartupTasks, badge: query.isEmpty ? nil : .owned,
                                           accessIsCurrent: library.accessIsCurrent)
                            }

                        }
                    }
                    if showsCollection { VStack(alignment: .leading, spacing: 6) {
                        if snapshot.excludedCount > 0 {
                            Text("\(snapshot.excludedCount) games not shown (not for PC or unavailable)")
                        }
                        Text("Last updated \(Text(snapshot.updatedAt, style: .relative)) ago")
                        if library.error != nil { Text("Showing the last complete library.") }
                    }
                    .font(.callout).foregroundStyle(.secondary) }
                    if !showsCollection, !library.accessIsCurrent {
                        Text("Showing your saved library. Refresh to check for changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if showsCollection { HStack {
                    Button("Browse games", action: browse)
                    Button("Recent activity", action: recentActivity)
                        .accessibilityIdentifier("xodus.library.openRecentActivity")
                } }
            }
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.pcGames.error")
            }
        }
        .task { if allowsStartupTasks && showsCollection { await library.loadOnAppear() } }
        .sheet(isPresented: Binding(get: { library.sheetPresented }, set: { value in
            if !value { Task { await library.cancelSignIn() } }
        })) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sign in to see your PC games").font(.title2.bold())
                Text("Open Microsoft's sign-in page and enter this code to see the PC games in your account.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let code = library.deviceCode {
                    Text(code.userCode).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                        .accessibilityLabel("Microsoft sign-in code, \(code.userCode)")
                        .accessibilityIdentifier("xodus.pcGames.deviceCode")
                    Button("Open microsoft.com/link") { library.openVerification() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("xodus.pcGames.openVerification")
                    Text("Waiting for you to finish sign-in.").foregroundStyle(.secondary)
                } else if library.busy { ProgressView("Preparing sign-in").controlSize(.small) }
                if let error = library.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { Task { await library.cancelSignIn() } }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("xodus.pcGames.cancel")
                }
            }
            .padding(28).frame(width: 480)
            .interactiveDismissDisabled(library.busy)
        }
    }
}

struct PCGameTile: View {
    let game: PCGame
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    var allowsArtworkLoading = true
    var badge: CatalogAccessBadge?
    var viewDetails: (() -> Void)?
    var accessIsCurrent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CatalogArtworkView(reference: allowsArtworkLoading ? game.artwork : nil,
                               status: game.artwork == nil ? .absent : .available, contentMode: .fit)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(game.title).font(.headline)
                .lineLimit(2).frame(minHeight: 40, alignment: .topLeading)
            if let badge {
                Text(accessIsCurrent
                     ? (game.acquisitionKind == .subscription ? "Subscription (plan unknown)" : badge.rawValue)
                     : "Saved library - refresh required")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let match = PCGamesController.installedMatch(game, in: installed.games) {
                InstalledPlayButton(library: installed, operations: operations, game: match)
                InstalledPlayError(library: installed, game: match)
            } else {
                Text("Not installed").font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { await operations.install(game) }
                } label: {
                    Label("Install", systemImage: "icloud.and.arrow.down")
                }
                    .disabled(!accessIsCurrent || !operations.canStartMutation)
                    .help("Install \(game.title)")
                    .accessibilityLabel("Install \(game.title)")
                    .accessibilityIdentifier("xodus.pcGames.download")
            }
            if let viewDetails { Button("View game", action: viewDetails) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension PCGame {
    init(product: CatalogProduct) {
        self.init(id: product.id, title: product.title,
                  artwork: CatalogArtworkReference.preferred(in: product.artwork, roles: [.boxArt, .poster, .tile, .hero]))
    }
}
