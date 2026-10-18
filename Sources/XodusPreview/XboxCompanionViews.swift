// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

enum XboxCompanionCopy {
    static let accountScope =
        "Your Xbox account can differ from the Microsoft account used to buy PC games."
    static let achievementsIntro =
        "Your progress across Xbox and PC. Choose a game to see its achievements."
    static let remotePlay =
        "Remote Play opens on Xbox's website in your browser."
    static let connectionsTitle = "Friends and following"
}

enum XboxBrand {
    static let green = Color(red: 16 / 255, green: 124 / 255, blue: 16 / 255)
    static let lightGreen = Color(red: 82 / 255, green: 176 / 255, blue: 67 / 255)
    static let gradient = LinearGradient(colors: [lightGreen, green], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct XboxProminentButton: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.buttonStyle(.borderedProminent).tint(XboxBrand.green) } else { content }
    }
}

struct AccountHubDestinations: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                destination(.profile, symbol: "person.crop.circle", detail: "Gamer profile and friends")
                Divider()
                destination(.achievements, symbol: "trophy", detail: "Your game progress")
                Divider()
                destination(.consoles, symbol: "xbox.logo", detail: "Your Xbox consoles")
                Divider()
                destination(.engines, symbol: "gearshape.2", detail: "Mac runtime configuration")
            }
            .padding(.top, 2)
    }

    private func destination(_ value: AccountDestination, symbol: String, detail: String) -> some View {
        Button {
            state.accountDestination = value
        } label: {
            HStack {
                Label(value.rawValue, systemImage: symbol)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value.rawValue), \(detail)")
    }
}

struct XboxProfileView: View {
    @ObservedObject var companion: XboxCompanionController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Profile").font(.title2.bold())
            accountScope
            if companion.refreshing && companion.cache == nil {
                ProgressView("Loading Xbox profile")
            } else if let cache = companion.cache {
                profile(cache.profile)
                friends(cache.friends)
                recent(cache.recentGames)
            } else {
                unavailable("Profile unavailable", error: companion.error,
                            description: "Check the Xbox game-service account and refresh.")
            }
            if let error = companion.error, companion.cache != nil {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var accountScope: some View {
        Text("Profile and social data use your Xbox account. \(XboxCompanionCopy.accountScope)")
            .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func profile(_ section: XboxCompanionSection<XboxProfile>) -> some View {
        if let profile = section.value, section.available {
            GroupBox {
                HStack(alignment: .top, spacing: 16) {
                    if let reference = XboxCompanionArtwork.reference(profile.avatarURL) {
                        CatalogArtworkView(reference: reference, status: .available)
                            .frame(width: 88, height: 88).clipShape(Circle())
                            .accessibilityLabel("\(profile.gamertag) gamer picture")
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 72))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(profile.gamertag).font(.title2.weight(.semibold))
                        if let name = profile.displayName { Text(name).foregroundStyle(.secondary) }
                        if let score = profile.gamerscore {
                            Label("\(score.formatted()) G", systemImage: "trophy")
                        }
                        if let bio = profile.bio { Text(bio).fixedSize(horizontal: false, vertical: true) }
                        if let location = profile.location {
                            Label(location, systemImage: "location").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        } else if section.unavailable {
            unavailable("Profile unavailable", error: section.error?.reason,
                        description: "Xbox did not provide profile data for this account.")
        }
    }

    @ViewBuilder private func friends(_ section: XboxCompanionSection<[XboxFriend]>) -> some View {
        if let friends = section.value, section.available {
            GroupBox(XboxCompanionCopy.connectionsTitle) {
                if friends.isEmpty {
                    Text("No friends were returned.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(friends) { friend in
                            HStack(spacing: 12) {
                                if let reference = XboxCompanionArtwork.reference(friend.avatarURL) {
                                    CatalogArtworkView(reference: reference, status: .available)
                                        .frame(width: 36, height: 36).clipShape(Circle())
                                } else {
                                    Image(systemName: "person.crop.circle").font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(friend.gamertag).font(.headline)
                                    if let presence = friend.presenceText ?? friend.presenceState {
                                        Text(presence).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if section.unavailable {
            unavailable("Friends unavailable", error: section.error?.reason,
                        description: "Xbox did not provide a friends list.")
        }
    }

    @ViewBuilder private func recent(_ section: XboxCompanionSection<[XboxRecentGame]>) -> some View {
        if let games = section.value, section.available {
            GroupBox("Recent Xbox activity") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Play history is separate from your owned PC library.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(games.prefix(8)) { game in
                        HStack(spacing: 12) {
                            if let reference = XboxCompanionArtwork.reference(game.artworkURL) {
                                CatalogArtworkView(reference: reference, status: .available)
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "gamecontroller").frame(width: 56, height: 56)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(game.name).font(.headline)
                                if let devices = game.devices, !devices.isEmpty {
                                    Text(devices.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                if let value = game.lastPlayed, let date = XboxViewFormatting.date(value) {
                                    Text("Played \(date.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } else if section.unavailable {
            unavailable("Recent activity unavailable", error: section.error?.reason,
                        description: "Xbox did not provide recent play history.")
        }
    }

    private func unavailable(_ title: String, error: String?, description: String) -> some View {
        ContentUnavailableView(title, systemImage: "person.crop.circle.badge.exclamationmark",
            description: Text(error ?? description))
    }
}

@MainActor
private final class XboxAchievementSelection: ObservableObject {
    @Published var titleID: String?
}

struct XboxAchievementsView: View {
    @ObservedObject var companion: XboxCompanionController
    let status: GameServiceStatus?
    @StateObject private var selection = XboxAchievementSelection()

    private var games: [XboxRecentGame] { companion.cache?.recentGames.value ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                if selection.titleID != nil {
                    Button("All games", systemImage: "chevron.left") { selection.titleID = nil }
                }
                Text("Achievements").font(.title2.bold())
                Spacer()
            }
            Text(XboxCompanionCopy.achievementsIntro)
                .font(.callout).foregroundStyle(.secondary)
            if let titleID = selection.titleID, let game = games.first(where: { $0.titleId == titleID }) {
                achievementList(game)
            } else if games.isEmpty {
                ContentUnavailableView("No achievements to show", systemImage: "trophy",
                    description: Text(companion.cache?.recentGames.error?.reason
                                      ?? "Check Xbox access in Settings to load your recent games."))
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(games) { game in
                        Button {
                            selection.titleID = game.titleId
                            Task { await companion.loadAchievements(titleID: game.titleId, status: status) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.name).font(.headline)
                                    XboxAchievementSummary(game: game)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private func achievementList(_ game: XboxRecentGame) -> some View {
        if companion.refreshingTitles.contains(game.titleId), companion.achievements[game.titleId] == nil {
            ProgressView("Loading \(game.name) achievements")
        } else if let cache = companion.achievements[game.titleId] {
            if !cache.complete, let reason = cache.error?.reason {
                Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if cache.achievements.isEmpty {
                ContentUnavailableView("No achievements returned", systemImage: "trophy",
                    description: Text("Xbox hasn't provided any achievements for this game."))
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(cache.achievements) { achievement in
                    HStack(alignment: .top, spacing: 12) {
                        if let reference = XboxCompanionArtwork.reference(achievement.artworkURL) {
                            CatalogArtworkView(reference: reference, status: .available)
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: achievement.unlocked ? "trophy.fill" : "lock")
                                .frame(width: 56, height: 56)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(achievement.name).font(.headline)
                                if let score = achievement.gamerscore {
                                    Text("\(score.formatted()) G").foregroundStyle(.secondary)
                                }
                            }
                            if let description = achievement.description, !description.isEmpty {
                                Text(description).font(.callout).foregroundStyle(.secondary)
                            } else if achievement.isSecret == true {
                                Text("Secret achievement").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(Array(achievement.requirements.enumerated()), id: \.offset) { _, requirement in
                                if let current = requirement.current, let target = requirement.target {
                                    Text("\(current) / \(target)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if achievement.unlocked, let value = achievement.unlockTime,
                               let date = XboxViewFormatting.date(value) {
                                Text("Earned \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(achievement.progressState).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
        } else {
            ContentUnavailableView {
                Label("Achievements unavailable", systemImage: "trophy")
            } description: {
                Text(companion.achievementErrors[game.titleId]
                     ?? "Choose Refresh to try loading this title again.")
            } actions: {
                Button("Refresh") {
                    Task { await companion.loadAchievements(titleID: game.titleId, status: status, force: true) }
                }
            }
        }
    }
}

struct XboxAccountSummaryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @ObservedObject var companion: XboxCompanionController

    var body: some View {
        VStack(spacing: 20) {
            if let cache = companion.cache {
                if let profile = cache.profile.value, cache.profile.available {
                    VStack(spacing: 8) {
                        if let reference = XboxCompanionArtwork.reference(profile.avatarURL) {
                            CatalogArtworkView(reference: reference, status: .available)
                                .frame(width: 88, height: 88).clipShape(Circle())
                                .overlay(Circle().strokeBorder(XboxBrand.gradient, lineWidth: 3))
                                .accessibilityLabel("\(profile.gamertag) gamer picture")
                        }
                        Text(profile.gamertag).font(.title2.bold())
                        if let name = profile.displayName, name != profile.gamertag {
                            Text(name).font(.callout).foregroundStyle(.secondary)
                        }
                        if let score = profile.gamerscore {
                            Label("\(score.formatted()) G", systemImage: "trophy.fill")
                                .font(.callout.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(XboxBrand.gradient, in: Capsule())
                        }
                    }
                }
                if let games = cache.recentGames.value, cache.recentGames.available, !games.isEmpty {
                    accountSection("Achievements", symbol: "trophy.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(games.prefix(3)) { game in
                                HStack(spacing: 10) {
                                    if let reference = XboxCompanionArtwork.reference(game.artworkURL) {
                                        CatalogArtworkView(reference: reference, status: .available)
                                            .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        Image(systemName: "gamecontroller").frame(width: 36, height: 36)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(game.name).font(.callout.weight(.medium)).lineLimit(1)
                                        XboxAchievementSummary(game: game)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            Button("See all achievements") { state.accountDestination = .achievements }
                                .buttonStyle(.plain).foregroundStyle(XboxBrand.green).font(.callout.weight(.medium))
                                .accessibilityIdentifier("xodus.account.achievements")
                        }
                    }
                }
                if let friends = cache.friends.value, cache.friends.available, !friends.isEmpty {
                    accountSection("Friends", symbol: "person.2.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(friends.prefix(5)) { friend in
                                HStack(spacing: 8) {
                                    if let reference = XboxCompanionArtwork.reference(friend.avatarURL) {
                                        CatalogArtworkView(reference: reference, status: .available)
                                            .frame(width: 24, height: 24).clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                    }
                                    Text(friend.gamertag).font(.callout)
                                    if let presence = friend.presenceText ?? friend.presenceState {
                                        Text(presence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            if friends.count > 5 {
                                Button("See all \(friends.count.formatted()) friends") { state.accountDestination = .profile }
                                    .buttonStyle(.plain).foregroundStyle(XboxBrand.green).font(.callout.weight(.medium))
                            }
                        }
                    }
                }
            } else if companion.refreshing {
                ProgressView().controlSize(.small).accessibilityLabel("Loading Xbox profile")
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "xbox.logo")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(XboxBrand.green)
                        .frame(width: 88, height: 88)
                        .background(.quaternary, in: Circle())
                        .accessibilityHidden(true)
                    Text(state.gameOperations.serviceStatus?.serviceRunning == false
                         ? "Restoring Xbox services" : "Xbox profile unavailable")
                        .font(.title3.weight(.semibold))
                    Text(state.gameOperations.serviceStatus?.serviceRunning == false
                         ? "X Ode is reconnecting automatically. Your saved account and games remain unchanged."
                         : "Connect Xbox services to load your gamer picture, achievements, and friends.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                    if state.gameOperations.serviceStatus?.serviceRunning == false {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Restoring Xbox services")
                    } else if state.gameOperations.serviceStatus?.serviceRunning == true,
                              state.gameOperations.serviceStatus?.signedIn == false,
                              state.gameOperations.canSignIn {
                        Button("Continue with Microsoft") {
                            state.gameOperations.signInForGames()
                        }
                        .buttonStyle(.borderedProminent).tint(XboxBrand.green)
                    } else if state.gameOperations.serviceError != nil {
                        Button("Try again") { state.gameOperations.refreshService() }
                    }
                }
            }
            accountSection("Membership", symbol: "checkmark.seal.fill") {
                libraryAndGamePass
            }
        }
        .tint(XboxBrand.green)
        .frame(maxWidth: 420)
    }

    private func accountSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            content().frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(XboxBrand.green)
        }
    }

    private var libraryAndGamePass: some View {
        XboxLibraryAccessSummary(library: state.pcGames, operations: state.gameOperations,
                                 gamePassCatalogCount: session.gamePassProducts.count)
    }
}

private struct XboxLibraryAccessSummary: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var operations: GameOperationsController
    let gamePassCatalogCount: Int

    var body: some View {
        let games = library.representedGames
        let fromGamePass = games.filter { $0.acquisitionKind == .subscription }.count
        let owned = games.count - fromGamePass
        VStack(spacing: 6) {
            if !games.isEmpty {
                Text("\(owned.formatted()) owned · \(fromGamePass.formatted()) from Game Pass")
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("xodus.account.libraryCounts")
            }
            if let status = operations.gamePassStatus, status.active == true {
                let plan = status.planLabel ?? "Game Pass"
                let expiry = status.expiryDate.map { " · renews or ends \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                Label("\(plan) active\(expiry)", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(XboxBrand.green)
                if gamePassCatalogCount > 0 {
                    Text("\(gamePassCatalogCount.formatted()) PC games available with Game Pass")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if operations.gamePassStatus?.active == false {
                Text("No Game Pass membership").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { if operations.gamePassStatus == nil { await operations.loadGamePassCache() } }
    }
}

private struct XboxAchievementSummary: View {
    let game: XboxRecentGame
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let unlocked = game.achievementsUnlocked, let total = game.achievementsTotal, total > 0 {
                ProgressView(value: Double(min(unlocked, total)), total: Double(total))
                    .tint(XboxBrand.green).accessibilityHidden(true)
            }
            details
        }
    }

    private var details: some View {
        HStack(spacing: 10) {
            if let unlocked = game.achievementsUnlocked {
                Text(game.achievementsTotal.map { "\(unlocked.formatted()) of \($0.formatted()) achievements" }
                     ?? "\(unlocked.formatted()) achievements")
            }
            if let score = game.gamerscore {
                Text(game.gamerscoreTotal.map { "\(score.formatted()) / \($0.formatted()) G" }
                     ?? "\(score.formatted()) G")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

struct XboxConsolesView: View {
    @ObservedObject var companion: XboxCompanionController
    private let remotePlay = URL(string: "https://www.xbox.com/remoteplay")!
    private let setup = URL(string: "https://www.xbox.com/en-US/consoles/remote-play")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("My Consoles").font(.title2.bold())
            Text("Your consoles from the Xbox game-service account.")
                .font(.callout).foregroundStyle(.secondary)
            if let section = companion.cache?.consoles, let consoles = section.value, section.available {
                if consoles.isEmpty {
                    ContentUnavailableView("No consoles returned", systemImage: "xbox.logo",
                        description: Text("Xbox did not return a console for this account."))
                } else {
                    ForEach(consoles) { console in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(console.name).font(.headline)
                                    Spacer()
                                    Text(XboxViewFormatting.powerState(console.powerState))
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("Type", value: XboxViewFormatting.consoleType(console.consoleType))
                                if let enabled = console.streamingEnabled {
                                    LabeledContent("Remote play", value: enabled ? "Enabled" : "Not enabled")
                                }
                                if let enabled = console.remoteManagementEnabled {
                                    LabeledContent("Remote management", value: enabled ? "Enabled" : "Unavailable")
                                }
                                ForEach(console.storage) { storage in
                                    LabeledContent(storage.name ?? "Storage") {
                                        Text(XboxViewFormatting.storage(storage))
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Console data unavailable", systemImage: "xbox.logo",
                    description: Text(companion.cache?.consoles.error?.reason
                                      ?? companion.error ?? "Refresh the Xbox game-service account."))
            }
            GroupBox("Remote play") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(XboxCompanionCopy.remotePlay)
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Link("Play now", destination: remotePlay)
                        Link("Setup and support", destination: setup)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

// Keep property-wrapper state unambiguous with SDKs that also export a State macro.
private typealias EngineViewState<Value> = SwiftUI.State<Value>

struct EnginesView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @EngineViewState private var defaultEngine: RuntimeProviderKind? = EngineDefaults.defaultEngine()
    @EngineViewState private var runnerPaths = EngineDefaults.runnerPaths()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Engines").font(.title2.bold())
            Text("CrossOver readiness is observed independently from declared Wine, GPTK and graphics components. Experimental configurations remain explicitly labelled.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                RuntimeProviderSection(settings: state.runtimeSettings, backendPath: session.backendPath)
                Section("Launch routing") {
                    Picker("Default engine", selection: Binding(
                        get: { defaultEngine },
                        set: { value in
                            defaultEngine = value
                            EngineDefaults.setDefaultEngine(value)
                        })) {
                        Text("Automatic (first installed runner)").tag(Optional<RuntimeProviderKind>.none)
                        ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { provider in
                            Text(RuntimeProviderSettings.providerLabel(provider)).tag(Optional(provider))
                        }
                    }
                    Text("Selects the provider sent to the game's launch script. A per-game override takes precedence. An unavailable selection refuses launch rather than substituting another runner. The launcher must support this selector; the handoff alone is not gameplay proof.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Experimental runner executables") {
                        ForEach(RuntimeProviderSettings.providerChoices.filter { $0 != .crossover }, id: \.self) { kind in
                            TextField("\(kind.label) executable path", text: Binding(
                                get: { runnerPaths[kind] ?? "" },
                                set: { path in
                                    runnerPaths[kind] = path
                                    EngineDefaults.setRunnerPath(path, for: kind)
                                }))
                            .accessibilityIdentifier("xodus.engine.path.\(kind.rawValue)")
                        }
                        Text("Register each provider's absolute runner path separately, not the app engine. File availability is checked; toolkit identity and version are your declarations. These Experimental paths are not compatibility or gameplay proof.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 440)
        }
        .task { await state.runtimeSettings.refreshCrossOverDependency() }
    }
}

enum XboxViewFormatting {
    static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func storage(_ value: XboxConsole.Storage) -> String {
        switch (value.freeBytes, value.totalBytes) {
        case let (free?, total?):
            "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        case let (free?, nil): "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
        case let (nil, total?): "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) total"
        default: "Storage details unavailable"
        }
    }
    static func consoleType(_ value: String?) -> String {
        switch value {
        case "XboxSeriesX": "Xbox Series X"
        case "XboxSeriesS": "Xbox Series S"
        case "XboxOneX": "Xbox One X"
        case "XboxOneS": "Xbox One S"
        case "XboxOne": "Xbox One"
        default: "Xbox console"
        }
    }
    static func powerState(_ value: String?) -> String {
        switch value {
        case "ConnectedStandby": "Standby"
        case "On": "On"
        case "Off": "Off"
        default: "Status unavailable"
        }
    }
}
