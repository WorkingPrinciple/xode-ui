// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", installed = "Installed", owned = "Owned", gamePass = "Game Pass"
    var id: Self { self }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title", recentlyPlayed = "Recently played"
    var id: Self { self }
}

enum LibraryGridLayout {
    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24, alignment: .top)]
    }
}

@MainActor
final class LibrarySelection: ObservableObject {
    @Published var filter: LibraryFilter = .all
    @Published var sort: LibrarySort = .title
    @Published var recentGameID: UUID?
    @Published var heroID: String?
    @Published var heroHovered = false
    @Published var heroPlaying = false
    var requestedGamePassScope: String?
}

@MainActor
final class LibraryCoverInteraction: ObservableObject {
    @Published var hovered = false
}

struct LibraryGame: Identifiable {
    let id: String
    let title: String
    let installed: InstalledGame?
    let pc: PCGame?
    let product: CatalogProduct?
    let owned: Bool
    let gamePass: Bool
    var accessIsCurrent = true
    var cover: CatalogArtworkReference? {
        if let art = pc?.artwork, [.boxArt, .poster].contains(art.role),
           let width = art.width, let height = art.height, height > width { return art }
        return product.flatMap {
            CatalogArtworkReference.preferred(in: $0.artwork.filter {
                guard let width = $0.width, let height = $0.height else { return false }
                return height > width
            }, roles: [.boxArt, .poster])
        }
    }

    static func details(id: String, title: String, artwork: [CatalogArtworkReference] = [],
                        market: String, language: String, source: String, pcCandidate: Bool) throws -> CatalogProduct {
        let art = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(artwork))
        let value = JSONValue.object([
            "productID": .string(id), "title": .string(title), "market": .string(market),
            "language": .string(language), "source": .string(source),
            "checkedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "freshness": .string("current"), "editions": .array([]),
            "pcCatalogCandidate": .bool(pcCandidate), "artwork": art,
            "artworkStatus": .string(artwork.isEmpty ? "absent" : "available")
        ])
        return try JSONDecoder().decode(CatalogProduct.self, from: JSONEncoder().encode(value))
    }

    static func collection(installed: [InstalledGame], owned: [PCGame], products: [CatalogProduct],
                           gamePass: [CatalogProduct], active: Bool,
                           accessIsCurrent: Bool = true) -> [Self] {
        guard accessIsCurrent else { return [] }
        var result: [Self] = []
        var seen = Set<String>()
        let catalog = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Discovery is public, partial membership metadata, NOT an account grant.
        // The global subscription probe has no account-bound per-product access field.
        // Until that contract exists it cannot contribute Game-Pass-only Your Games.
        let pass = Dictionary(gamePass.filter(\.pcCatalogCandidate).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let held = Dictionary(owned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for game in installed {
            let id = game.storeId.isEmpty ? game.id.uuidString : game.storeId
            guard let entitlement = held[id], seen.insert(id).inserted else { continue }
            result.append(Self(id: id, title: game.title, installed: game, pc: entitlement,
                               product: catalog[id] ?? pass[id], owned: entitlement.acquisitionKind != .subscription,
                               gamePass: entitlement.acquisitionKind == .subscription || pass[id] != nil))
        }
        for game in owned where seen.insert(game.id).inserted {
            result.append(Self(id: game.id, title: game.title, installed: nil, pc: game,
                               product: catalog[game.id] ?? pass[game.id], owned: game.acquisitionKind != .subscription,
                               gamePass: game.acquisitionKind == .subscription || pass[game.id] != nil))
        }
        return result
    }

    static func localRecords(installed: [InstalledGame], qualified: [Self],
                             query: String, sort: LibrarySort) -> [Self] {
        let qualifiedInstallations = Set(qualified.compactMap { $0.installed?.id })
        let records = installed.filter { !qualifiedInstallations.contains($0.id) }.map {
            // UUID keeps separate imports reachable even if Store IDs overlap.
            Self(id: $0.id.uuidString, title: $0.title, installed: $0, pc: nil, product: nil,
                 owned: false, gamePass: false)
        }
        return visible(records, query: query, filter: .installed, sort: sort)
    }

    static func gamePassCatalog(installed: [InstalledGame], owned: [PCGame],
                                products: [CatalogProduct]) -> [Self] {
        let held = Dictionary(owned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let local = Dictionary(installed.map { ($0.storeId, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return products.filter { $0.pcCatalogCandidate && seen.insert($0.id).inserted }.map {
            Self(id: $0.id, title: $0.title, installed: local[$0.id], pc: held[$0.id],
                 product: $0, owned: held[$0.id].map { $0.acquisitionKind != .subscription } ?? false,
                 gamePass: true)
        }
    }

    static func continuing(_ qualified: [Self], launchableIDs: Set<UUID>) -> [InstalledGame] {
        qualified.compactMap(\.installed)
            .filter { $0.lastPlayedAt != nil && launchableIDs.contains($0.id) }
            .sorted {
                if $0.lastPlayedAt != $1.lastPlayedAt {
                    return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var eligibility: LibraryEligibility? {
        LibraryEligibility.evaluate(
            entitlement: pc?.acquisitionKind ?? (owned ? .unknown : nil),
            accessIsCurrent: accessIsCurrent && (pc != nil || owned),
            verifiedGamePassAccess: false, installed: installed != nil)
    }

    static func visible(_ games: [Self], query: String, filter: LibraryFilter, sort: LibrarySort) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return games.filter {
            (query.isEmpty || $0.title.localizedStandardContains(query)) &&
            (filter == .all || (filter == .installed && $0.installed != nil) ||
             (filter == .owned && $0.owned) || (filter == .gamePass && $0.gamePass))
        }.sorted {
            if sort == .recentlyPlayed {
                let left = $0.installed?.lastPlayedAt ?? .distantPast
                let right = $1.installed?.lastPlayedAt ?? .distantPast
                if left != right { return left > right }
            }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct LibraryControls: View {
    let count: Int
    @Binding var filter: LibraryFilter
    @Binding var sort: LibrarySort

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                heading
                Spacer()
                filters
                sorting
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { heading; Spacer(); sorting }
                filters
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(filter == .gamePass ? "PC Game Pass" : "Your Games").font(.title2.weight(.semibold))
            Text(count.formatted()).font(.title3).foregroundStyle(.secondary)
        }
    }
    private var filters: some View {
        Picker("Filter games", selection: $filter) {
            ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
        .accessibilityIdentifier("xodus.library.filter")
    }
    private var sorting: some View {
        Menu {
            Picker("Sort games", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Sort games by \(sort.rawValue)")
        .accessibilityIdentifier("xodus.library.sort")
    }
}

struct LibraryHero<Artwork: View, Poster: View, Information: View, Actions: View>: View {
    let title: String
    var logos: [CatalogArtworkReference] = []
    var allowsArtworkLoading = true
    var height: CGFloat = 340
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let poster: () -> Poster
    @ViewBuilder let information: () -> Information
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork()
            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height > 340 ? height * 0.7 : 210).allowsHitTesting(false)
            if height > 340 {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .center)
                    .allowsHitTesting(false)
            }
            HStack(alignment: .bottom, spacing: 24) {
                poster().frame(width: 100, height: 150).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    LibraryLogoTitle(title: title, references: logos, allowsLoading: allowsArtworkLoading)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                    information().environment(\.libraryOnHeroMedia, true)
                    LibraryGlassCluster { actions() }.modifier(LibraryHeroControlSize()).padding(.top, 4)
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 56).padding(.bottom, height > 340 ? 56 : 24)
        }
        .frame(height: height).clipped()
        .accessibilityElement(children: .contain)
        .modifier(LibraryBackgroundExtension())
    }
}

enum LibraryAccess: String {
    case owned = "Owned", gamePass = "Game Pass catalog", subscription = "Subscription"
    var symbol: String { self == .owned ? "checkmark.seal" : "ticket" }
    var help: String {
        switch self {
        case .owned: "In your Microsoft PC game library."
        case .subscription: "Current subscription grant in your PC library. The provider and plan are not identified."
        case .gamePass: "Included in the PC Game Pass catalogue. A subscription is required to install."
        }
    }
    init?(_ game: LibraryGame) {
        switch game.eligibility {
        case .owned: self = .owned
        case .gamePass: self = .subscription
        case .installedUnknown, nil:
            guard game.gamePass else { return nil }
            self = .gamePass
        }
    }
    static func badges(_ game: LibraryGame) -> [Self] {
        if game.eligibility == .gamePass { return [.subscription] }
        return (game.eligibility == .owned ? [.owned] : []) + (game.gamePass ? [.gamePass] : [])
    }
    static func summary(owned: Bool, catalogMembership: Bool, current: Bool) -> String {
        let access = owned ? (current ? "Owned" : "Saved Owned · refresh required") : "Access not verified"
        return catalogMembership ? access + " · Game Pass catalog" : access
    }
}

struct LibraryAccessBadge: View {
    let access: LibraryAccess
    var compact = false
    var body: some View {
        if access == .subscription {
            Label(access.rawValue, systemImage: "ticket")
                .font((compact ? Font.caption : .callout).weight(.semibold))
                .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 4)
                .modifier(LibraryBadgeMaterial())
                .accessibilityLabel(access.rawValue)
        } else if access == .gamePass {
            Label("Game Pass", systemImage: "xbox.logo")
                .font((compact ? Font.caption : .callout).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 4)
                .background(Color(red: 16 / 255, green: 124 / 255, blue: 16 / 255), in: Capsule())
                .accessibilityLabel(access.rawValue)
        } else {
            Label(access.rawValue, systemImage: access.symbol)
                .font(compact ? .caption : .callout)
                .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 4)
                .modifier(LibraryBadgeMaterial())
        }
    }
}

private struct LibraryBadgeMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.xodusReviewReduceTransparency) private var reviewReduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency || reviewReduceTransparency { content.background(.background, in: Capsule()) }
        else if #available(macOS 26, *) { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.thinMaterial, in: Capsule()) }
    }
}

private struct LibraryOnHeroMediaKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var libraryOnHeroMedia: Bool {
        get { self[LibraryOnHeroMediaKey.self] }
        set { self[LibraryOnHeroMediaKey.self] = newValue }
    }
}

/// Secondary grey disappears over bright art and video frames, so hero facts stay near-white with a soft shadow.
private struct LibraryInformationStyle: ViewModifier {
    let onHeroMedia: Bool
    func body(content: Content) -> some View {
        if onHeroMedia {
            content.foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.75), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.45), radius: 8)
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

struct LibraryGameInformation: View {
    var access: LibraryAccess?
    var gamePass = false
    var facts: LibraryCatalogFacts?
    var xbox: LibraryXboxStatsCache.Game?
    var localPlaySeconds: Double? = nil
    var compact = false
    @Environment(\.libraryOnHeroMedia) private var onHeroMedia

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 8) {
                if let access {
                    LibraryAccessBadge(access: access, compact: compact).help(access.help)
                }
                if gamePass, access == nil || access == .owned {
                    LibraryAccessBadge(access: .gamePass, compact: compact).help(LibraryAccess.gamePass.help)
                }
                if let facts, !facts.genres.isEmpty {
                    Label(compact ? facts.genres[0] : facts.genres.joined(separator: " / "), systemImage: "tag")
                        .lineLimit(compact ? 1 : 2)
                }
            }
            if !compact {
                if let facts, !facts.capabilities.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        capabilityRow(facts.capabilities)
                        capabilityRow(Array(facts.capabilities.prefix(2)))
                    }
                    .help("Microsoft's PC catalog features, not verified Mac runtime support.")
                }
            }
            if let xbox {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { xboxSummary(xbox, abbreviated: compact) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 5) { xboxSummary(xbox, abbreviated: compact) }
                }
            }
            if let label = Self.playTimeLabel(seconds: localPlaySeconds) {
                Label(label, systemImage: "clock")
            }
        }
        .font(compact ? .caption : .callout)
        .modifier(LibraryInformationStyle(onHeroMedia: onHeroMedia))
    }

    private func capabilityRow(_ values: [LibraryCapability]) -> some View {
        HStack(spacing: 12) { ForEach(values) { Label($0.rawValue, systemImage: $0.symbol) } }
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func xboxSummary(_ xbox: LibraryXboxStatsCache.Game, abbreviated: Bool) -> some View {
        if let time = xbox.playTime { Label(time, systemImage: "clock") }
        Label(abbreviated ? "\(xbox.achievementsUnlocked.formatted()) achievements" : xbox.achievements,
              systemImage: "trophy").help(xbox.achievements)
        if !abbreviated, let friends = xbox.friends {
            Label(friends, systemImage: "person.2").help(xbox.friendHelp)
        }
    }

    static func playTimeLabel(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds <= 3_153_600_000 else { return nil }
        if seconds < 60 { return "Less than 1 min played on this Mac" }
        let hours = seconds >= 3600
        let amount = Int(seconds / (hours ? 3600 : 60))
        return "\(amount.formatted()) \(hours ? "h" : "min") played on this Mac"
    }
}

struct LibraryHeroControlSize: ViewModifier {
    var enabled = true
    func body(content: Content) -> some View {
        if enabled { content.controlSize(.large) }
        else { content }
    }
}

struct LibraryImmersion: ViewModifier {
    var enabled = true
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.container, edges: .top)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else { content }
    }
}

struct LibraryGlassCluster<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { HStack(spacing: 12, content: content) }
        } else { HStack(spacing: 12, content: content) }
    }
}

struct LibraryActionStyle: ViewModifier {
    var primary = true
    var usesGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.xodusReviewReduceTransparency) private var reviewReduceTransparency
    func body(content: Content) -> some View {
        if usesGlass, !reduceTransparency, !reviewReduceTransparency, #available(macOS 26, *) {
            if primary { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else if primary { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

/// Shown instead of Install when the Mac-support check already knows the game can't run.
struct LibraryUnsupportedLabel: View {
    let reason: String
    var heroStyle = false
    var body: some View {
        Label("Not on Mac yet", systemImage: "laptopcomputer.slash")
            .font(heroStyle ? .body.weight(.semibold) : .callout)
            .foregroundStyle(heroStyle ? Color.white.opacity(0.92) : .secondary)
            .shadow(color: heroStyle ? .black.opacity(0.5) : .clear, radius: 3, y: 1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .modifier(LibraryBadgeMaterial())
            .help(reason)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not on Mac yet. \(reason)")
            .accessibilityIdentifier("xodus.library.unsupported")
    }
}

struct LibraryBackgroundExtension: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.backgroundExtensionEffect() }
        else { content }
    }
}

struct LibraryScrollEdge: ViewModifier {
    var enabled = true
    func body(content: Content) -> some View {
        if enabled, #available(macOS 26, *) { content.scrollEdgeEffectStyle(.soft, for: .top) }
        else { content }
    }
}

struct LibraryCover<Artwork: View, Actions: View, Status: View>: View {
    let title: String
    var openLabel = "Open"
    var alwaysShowsActions = false
    let open: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let status: () -> Status
    @ViewBuilder let actions: () -> Actions
    @StateObject private var interaction = LibraryCoverInteraction()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var showsActions: Bool { alwaysShowsActions || interaction.hovered || focused || voiceOver }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    artwork().aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).accessibilityLabel("\(openLabel) \(title)")
                actions().controlSize(.small).buttonBorderShape(.capsule).padding(12)
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
            }
            .onHover { interaction.hovered = $0 }
            .focused($focused)
            Text(title).font(.headline).lineLimit(2).frame(minHeight: 36, alignment: .topLeading)
            status().font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
