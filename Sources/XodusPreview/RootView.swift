// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        Group {
            if state.destination == .downloads {
                VStack(spacing: 0) {
                    GameArtwork(kind: "orbit").frame(height: 160).clipped()
                    FixtureNotice().padding(.horizontal, 30).padding(.top, 12)
                    DownloadsView()
                }
            } else if state.destination == .library {
                ScrollView { FixtureLibraryView() }.modifier(LibraryScrollEdge())
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ImmersiveHero(game: state.destination == .library ? Fixtures.games[0] : Fixtures.games[1])
                        libraryContent
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .modifier(LibraryImmersion(enabled: state.destination == .library))
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            XodusToolbar(selection: state.navigationSelection, searchText: $state.query,
                         searchFocused: Binding(get: { searchFocused }, set: { searchFocused = $0 }),
                         searchPlaceholder: state.destination == .downloads ? "Search Library or Discover"
                            : "Search \(state.destination.rawValue)",
                         searchEnabled: state.destination != .downloads, accountLabel: "Fixture account",
                         accountSymbol: "person.crop.circle",
                         libraryContrast: state.destination == .library) { state.showingWelcome = true }
        }
        .onAppear {
            PreviewExporter.startIfRequested(state: state)
            LibraryPreviewExporter.start(state: state, session: LiveSession())
        }
        .onReceive(LibraryPreviewExporter.presentation.$showGrid) { show in
            if show { proxy.scrollTo("library-games", anchor: .top) }
        }
        .sheet(item: $state.selectedGame) { game in GameDetailView(game: game) }
        .sheet(isPresented: $state.showingWelcome) { WelcomeView() }
        .alert("Fixture preview", isPresented: Binding(
            get: { state.message != nil }, set: { if !$0 { state.message = nil } }
        )) {
            Button("OK") { state.message = nil }
        } message: { Text(state.message ?? "") }
        .background {
            Button("Focus search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let notice = state.inventory.notice {
                Label(notice, systemImage: state.inventory == .offline ? "wifi.slash" : "exclamationmark.circle")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if !state.connected {
                ContentUnavailableView {
                    Label("Connect a fixture account", systemImage: "person.crop.circle")
                } description: {
                    Text("No real sign-in exists. Explore a simulated account to preview the library.")
                } actions: {
                    Button("Open fixture onboarding") { state.showingWelcome = true }
                }
            } else if state.visibleGames.isEmpty {
                emptyState
            } else {
                if state.query.isEmpty {
                    if state.destination == .library { continuePlaying }
                    else {
                        Picker("Browse fixture worlds", selection: $state.category) {
                            ForEach(BrowseCategory.allCases) { category in
                                Text(category.rawValue).tag(category)
                            }
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 680)
                    }
                }
                HStack {
                    Text(state.query.isEmpty
                         ? (state.destination == .library ? "Your Games" : "Explore the catalog")
                         : "Search results").font(.title2.bold())
                    Spacer()
                    Text("\(state.visibleGames.count) fixture titles").foregroundStyle(.secondary)
                }
                if state.destination == .library {
                    HStack {
                        Picker("Access", selection: $state.accessFilter) {
                            Text("All access").tag(Entitlement?.none)
                            Text("Purchased").tag(Entitlement?.some(.purchase))
                            Text("Subscription").tag(Entitlement?.some(.subscription))
                        }
                        .frame(width: 240)
                        Spacer()
                        Toggle("Sort by title", isOn: $state.sortByTitle).toggleStyle(.checkbox)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(
                    minimum: state.destination == .library ? 340 : 220), spacing: 22)], spacing: 26) {
                    ForEach(state.visibleGames) { game in GameTile(game: game) }
                }
            }
            Text("Invented fixture evidence. Not real ownership or verified gameplay.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(state.inventory == .failed ? "Library unavailable"
                  : state.query.isEmpty ? "No games in this fixture" : "No matching titles",
                  systemImage: state.inventory == .failed ? "exclamationmark.triangle" : "square.stack")
        } description: {
            Text(state.inventory == .failed
                 ? "Simulated INVENTORY_UNAVAILABLE. No live service was contacted."
                 : state.query.isEmpty ? "Try another scenario in Settings."
                 : "Search is limited to \(state.destination.rawValue).")
        } actions: {
            if !state.query.isEmpty { Button("Clear search") { state.query = "" } }
            if state.inventory == .failed {
                Button("Simulate successful refresh") { state.inventory = .complete }
            }
        }
        .frame(minHeight: 260)
    }

    private var continuePlaying: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue Playing").font(.title2.bold())
            HStack(spacing: 20) {
                ForEach(Fixtures.games.filter { state.installed.contains($0.id) }) { game in
                    Button { state.simulateLaunch(game) } label: {
                        HStack(spacing: 12) {
                            GameArtwork(kind: game.art).frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.title).fontWeight(.semibold)
                                Text("Simulate play").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(game.title), installed fixture. Simulate play.")
                }
                Spacer()
            }
        }
    }
}

struct ImmersiveHero: View {
    @EnvironmentObject private var state: AppState
    let game: Game

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GameArtwork(kind: game.art)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                if state.query.isEmpty {
                    Text(game.title).font(.system(size: 48, weight: .bold))
                    Text(game.subtitle).font(.title3)
                    GlassAction(title: "Explore fixture") { state.selectedGame = game }
                        .controlSize(.large)
                }
                Label("Fixture preview - invented content. No real sign-in, downloads or gameplay.",
                      systemImage: "testtube.2").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(30)
        }
        .frame(height: state.query.isEmpty ? 420 : 245)
        .clipped()
    }
}

struct FixtureNotice: View {
    var body: some View {
        Label("Fixture preview - invented content. No real account or gameplay.", systemImage: "testtube.2")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GameTile: View {
    @EnvironmentObject private var state: AppState
    let game: Game

    var body: some View {
        Button { state.selectedGame = game } label: {
            if state.destination == .library {
                HStack(alignment: .top, spacing: 12) {
                    GameArtwork(kind: game.art).frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title).font(.headline).foregroundStyle(.primary)
                        Text(game.entitlement.label).font(.callout).foregroundStyle(.secondary)
                        Text(game.compatibility == .unsupported
                             ? "Not supported on this configuration" : "\(game.compatibility.label) - fixture")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Added in demo").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Text("View").font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    GameArtwork(kind: game.art).frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(game.title).font(.headline).foregroundStyle(.primary)
                    Text(game.entitlement.label).font(.callout).foregroundStyle(.secondary)
                    Text("\(game.compatibility.label) - fixture").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.title), \(game.entitlement.label), \(game.compatibility.label). Open fixture details.")
    }
}
