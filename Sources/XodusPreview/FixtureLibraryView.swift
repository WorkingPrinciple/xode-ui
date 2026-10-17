// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

struct FixtureLibraryView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = LibrarySelection()
    private var filter: LibraryFilter {
        get { selection.filter }
        nonmutating set { selection.filter = newValue }
    }
    private var sort: LibrarySort { selection.sort }

    private var games: [Game] {
        let games = state.visibleGames.filter {
            filter == .all || (filter == .installed && state.installed.contains($0.id)) ||
                (filter == .owned && $0.entitlement == .purchase) ||
                (filter == .gamePass && $0.entitlement == .subscription)
        }
        return sort == .title ? games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : games
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.query.isEmpty {
                LibraryHero(title: Fixtures.games[0].title) {
                    GameArtwork(kind: Fixtures.games[0].art)
                } poster: {
                    GameArtwork(kind: Fixtures.games[0].art)
                } information: {
                    LibraryGameInformation(access: access(Fixtures.games[0]))
                    Text("\(GameOperationProgressView.bytes(Fixtures.games[0].expandedBytes)) installed - fixture")
                        .font(.caption).foregroundStyle(.secondary)
                } actions: {
                    Button { state.simulateLaunch(Fixtures.games[0]) } label: {
                        Label("Simulate play", systemImage: "play.fill")
                            .font(.title3.weight(.semibold)).frame(minHeight: 28).padding(.horizontal, 12)
                    }.modifier(LibraryActionStyle()).controlSize(.large)
                    Menu {
                        Button("View fixture details") { state.selectedGame = Fixtures.games[0] }
                    } label: {
                        Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 28, height: 28)
                    }
                    .menuIndicator(.hidden).modifier(LibraryActionStyle(primary: false))
                    .controlSize(.large).buttonBorderShape(.circle)
                    .accessibilityLabel("Actions for \(Fixtures.games[0].title)")
                }
            }
            VStack(alignment: .leading, spacing: 22) {
                FixtureNotice()
                if let notice = state.inventory.notice {
                    Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if !state.connected {
                    ContentUnavailableView {
                        Label("Connect a fixture account", systemImage: "person.crop.circle")
                    } description: { Text("No real sign-in exists. Explore a simulated account to preview the library.") }
                    actions: { Button("Open fixture onboarding") { state.showingWelcome = true } }
                } else {
                    if state.query.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Continue Playing").font(.title2.weight(.semibold))
                                Spacer()
                                Button("See All") { filter = .installed }
                            }
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 20) {
                                    ForEach(Fixtures.games.filter { state.installed.contains($0.id) }) { game in
                                        Button { state.simulateLaunch(game) } label: {
                                            VStack(alignment: .leading, spacing: 10) {
                                                GameArtwork(kind: game.art).frame(width: 260, height: 120)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                                Text(game.title).font(.headline).foregroundStyle(.primary)
                                                LibraryGameInformation(access: access(game), compact: true)
                                                Text("\(GameOperationProgressView.bytes(state.installed.contains(game.id) ? game.expandedBytes : game.downloadBytes)) \(state.installed.contains(game.id) ? "installed" : "download") - fixture")
                                                    .font(.caption)
                                            }
                                        }
                                        .buttonStyle(.plain).accessibilityLabel("Simulate play, \(game.title), installed fixture")
                                    }
                                }.scrollTargetLayout()
                            }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                        }
                    }
                    LibraryControls(count: games.count, filter: $selection.filter, sort: $selection.sort)
                        .id("library-games")
                    if games.isEmpty {
                        ContentUnavailableView {
                            Label(state.query.isEmpty ? "No games in this fixture" : "No matching titles",
                                  systemImage: "gamecontroller")
                        } description: { Text("Invented library data only. Change the filter or fixture scenario.") }
                        actions: { Button("Show all fixture games") { filter = .all; state.query = ""; state.inventory = .complete } }
                    } else {
                        LazyVGrid(columns: LibraryGridLayout.columns,
                                  alignment: .leading, spacing: 30) {
                            ForEach(games) { game in
                                LibraryCover(title: game.title, open: { state.selectedGame = game }) {
                                    GameArtwork(kind: game.art)
                                } status: {
                                    LibraryGameInformation(access: access(game), compact: true)
                                    if state.installed.contains(game.id) {
                                        Label("Installed fixture", systemImage: "internaldrive")
                                    }
                                    Text("\(game.compatibility.label) - fixture").font(.caption)
                                } actions: {
                                    Button(state.installed.contains(game.id) ? "Simulate play" : "Review fixture") {
                                        if state.installed.contains(game.id) { state.simulateLaunch(game) }
                                        else { state.selectedGame = game }
                                    }.modifier(LibraryActionStyle(primary: false))
                                }
                                .contextMenu { Button("View fixture details") { state.selectedGame = game } }
                            }
                        }

                    }
                }
                Text("Original fixture artwork. Access and compatibility are independent invented evidence.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 56).padding(.vertical, 22)
        }
    }

    private func access(_ game: Game) -> LibraryAccess? {
        switch game.entitlement {
        case .purchase: .owned
        case .subscription: .gamePass
        case .none, .unknown: nil
        }
    }
}
