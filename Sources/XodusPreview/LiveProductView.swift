// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

enum GameDetailFacetCopy {
    static func installation(installed: Bool) -> String {
        installed ? "Installed on this Mac" : "Not installed"
    }

    static func precheckStatus(productID: String, installed: Bool, precheckingProductID: String?) -> String? {
        guard !installed, precheckingProductID == productID else { return nil }
        return "Checking installation requirements"
    }

    static func gamePassCheckStatus(libraryAccessIsCurrent: Bool) -> String? {
        libraryAccessIsCurrent ? nil : "Refresh your PC library before checking Game Pass access."
    }

    static func access(acquisition: PCGameAcquisitionKind?, current: Bool) -> String? {
        guard let acquisition else { return nil }
        let label: String
        switch acquisition {
        case .purchased: label = "Owned"
        case .subscription: label = "Subscription (plan unknown)"
        case .unknown: label = "In your library"
        }
        return current ? label : "Saved \(label) - refresh required"
    }
}

struct GameHeroMetadata: View {
    let details: CatalogDetailFacts

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { facts }
            VStack(alignment: .leading, spacing: 6) { facts }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("xodus.game.heroMetadata")
    }

    @ViewBuilder private var facts: some View {
        if let rating = details.storeRating {
            Label(Self.ratingLabel(rating), systemImage: "star")
        }
        if let release = details.releaseDate {
            Label(release.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                .accessibilityLabel("Released \(release.formatted(date: .long, time: .omitted))")
        }
        if let rating = details.contentRating {
            Text(rating.label)
                .help((rating.descriptors + rating.interactiveElements).joined(separator: " · "))
                .accessibilityLabel("Content rating \(rating.label)")
        }
    }

    static func ratingLabel(_ rating: CatalogStoreRating) -> String {
        "\(rating.average.formatted(.number.precision(.fractionLength(1)))) / 5 · \(rating.count.formatted()) ratings"
    }
}

struct LiveProductView: View {
    let product: CatalogProduct
    @ObservedObject var library: PCGamesController
    @ObservedObject var installedLibrary: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    var installationID: UUID? = nil
    var allowsStartupTasks = true
    var allowsArtworkLoading = true
    @EnvironmentObject private var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var catalog = LibraryCatalogArtwork.shared
    @ObservedObject private var stats = LibraryXboxStats.shared

    private var installed: InstalledGame? {
        installedLibrary.games.first { $0.storeId == product.id && (installationID == nil || $0.id == installationID) }
    }
    private var owned: PCGame? { library.representedGames.first { $0.id == product.id } }
    private var gamePass: Bool {
        session.gamePassProductIDs.contains(product.id)
    }
    private var art: LibraryCatalogArtwork.Images? { catalog.images[product.id] }
    private var details: CatalogDetailFacts? { art?.detail }
    private var pcPackageListed: Bool? {
        LibraryPCPackageEvidence.listed(observed: art?.facts.pcPackageListed,
                                       candidate: product.pcCatalogCandidate)
    }
    private var gameFacts: GameFacts {
        GameFacts(pc: owned, gamePass: gamePass, installed: installed, accessIsCurrent: library.accessIsCurrent(for: product.id))
    }
    private var canReviewGamePass: Bool {
        DiscoverBrowse.canReviewInstall(owned: owned != nil, accessIsCurrent: library.accessIsCurrent(for: product.id),
            gamePass: gamePass, subscriptionActive: operations.gamePassActive,
            pcCandidate: owned != nil || product.pcCatalogCandidate)
    }
    private var installAccessReason: String? {
        if !allowsStartupTasks { return "Wait for Ode to X to finish starting." }
        if owned == nil && !product.pcCatalogCandidate {
            return "PC availability for this title hasn't been confirmed. Installation is unavailable."
        }
        return library.installAccessNotice(for: product.id)
    }
    private var landscape: [CatalogArtworkReference] {
        art?.landscape ?? product.artwork.filter { $0.role == .hero }
    }
    private var unsupportedIssues: [LibraryCompatibilityIssue] {
        operations.supportIssues(
            productID: product.id,
            packageFormat: installed?.packageType?.label ?? art?.facts.packageFormat
        )
    }
    var body: some View {
        ZStack {
            LibraryAmbientBackdrop(references: landscape, installed: installed,
                                   allowsLoading: allowsArtworkLoading)
            VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        VStack(alignment: .leading, spacing: 28) {
                        if installed == nil, unsupportedIssues.isEmpty, !canReviewGamePass,
                           library.hasSavedSignIn, !library.needsSignIn {
                            Button("Refresh library") { library.refresh() }
                                .disabled(!allowsStartupTasks || library.busy || library.restoringPresence)
                        }
                        GameOperationProgressView(operations: operations, productID: product.id)
                        if let status = GameDetailFacetCopy.precheckStatus(
                            productID: product.id, installed: installed != nil,
                            precheckingProductID: operations.precheckingProductID) {
                            ProgressView(status).controlSize(.small)
                        }
                        if let installed {
                            InstalledGameAttentionView(installed: installedLibrary, operations: operations,
                                game: installed, repairGame: library.accessIsCurrent(for: product.id) ? owned : nil,
                                close: dismiss.callAsFunction)
                        }
                        if let error = catalog.detailErrors[product.id] ?? catalog.error {
                            HStack {
                                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                                Spacer()
                                Button("Try Again") {
                                    Task { await catalog.retry(id: product.id, market: product.market, language: product.language) }
                                }.disabled(!allowsArtworkLoading)
                            }
                        }
                        if let details {
                            media(details)
                            if let description = details.description ?? details.shortDescription {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("About the game").font(.title2.weight(.semibold))
                                    Text(description).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 680, alignment: .leading)
                                }
                                .id("detail-information")
                            }
                            requirements(details)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Details").font(.title2.weight(.semibold))
                            DetailGameSizeView(installed: installed, downloadBytes: art?.facts.downloadBytes,
                                               packageFormat: art?.facts.packageFormat,
                                               allowsMeasurement: allowsArtworkLoading)
                            if let details { gameInfo(details) }
                        }
                        GameCompatibilityFacts(productID: product.id,
                            pcPackageListed: pcPackageListed,
                            packageFormat: installed?.packageType?.label ?? art?.facts.packageFormat,
                            compatibility: operations.compatibility[product.id])
                        GameSaveLocationView(productID: product.id)
                        }.padding(.horizontal, 40).padding(.bottom, 72)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
#if !XODUS_SHIPPING
                .onReceive(LibraryPreviewExporter.presentation.$showDetailInformation) { show in
                    if show { proxy.scrollTo("detail-information", anchor: .top) }
                }
#endif
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            }
        }
        .frame(minWidth: 820, idealWidth: 1040, maxWidth: 1200,
               minHeight: 600, idealHeight: 780, maxHeight: 850)
        .task(id: "\(product.id):\(product.market):\(product.language)") {
            if allowsArtworkLoading {
                await catalog.loadDetail(id: product.id, market: product.market, language: product.language)
            }
        }
        .task(id: installed?.id) {
            if allowsStartupTasks, let installed { await installedLibrary.checkInstallation(installed) }
        }
        .task(id: product.id) {
            guard allowsStartupTasks,
                  operations.compatibility[product.id] == nil else { return }
            operations.precheck([product.id])
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LibraryLandscapeView(references: landscape, installed: installed, allowsLoading: allowsArtworkLoading)
                .mask(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.78),
                    .init(color: .black.opacity(0.72), location: 0.90),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.10), location: 0.50),
                .init(color: .black.opacity(0.34), location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 24) {
                if let cover = art?.cover ?? CatalogArtworkReference.preferred(in: product.artwork, roles: [.boxArt, .poster]) {
                    CatalogArtworkView(reference: allowsArtworkLoading ? cover : nil, status: .available)
                        .frame(width: 100, height: 150).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    LibraryLogoTitle(title: product.title, references: art?.logos ?? [],
                                     allowsLoading: allowsArtworkLoading)
                    GameHeroAccess(facts: gameFacts)
                    LibraryGameInformation(gameFacts: gameFacts, detail: true,
                                           showsAccessBadges: false,
                                           facts: art?.facts, xbox: stats.cache?.games[product.id])
                    if let details {
                        GameHeroMetadata(details: details)
                    }
                    if let date = installed?.lastPlayedAt {
                        Text("Last played \(date.formatted(.relative(presentation: .named))) on this Mac")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LibraryGlassCluster {
                        if !unsupportedIssues.isEmpty {
                            LibraryCompatibilityIndicators(issues: unsupportedIssues, heroStyle: true)
                            if let installed {
                                InstalledGameActions(library: installedLibrary, operations: operations,
                                                     game: installed, usesGlass: true)
                            }
                        } else if let installed {
                            if installedLibrary.placeholderIDs.contains(installed.id), let owned {
                                Button {
                                    Task { await operations.repair(owned, installed: installed) }
                                } label: {
                                    Label("Download full game", systemImage: "icloud.and.arrow.down")
                                }
                                .modifier(LibraryActionStyle())
                                .disabled(!allowsStartupTasks || !library.accessIsCurrent(for: product.id)
                                          || !operations.canStartMutation)
                                if !library.accessIsCurrent(for: product.id) || !operations.canStartMutation {
                                    Text(library.installAccessNotice(for: product.id)
                                         ?? operations.installUnavailableReason ?? "Installation is not available yet.")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                InstalledPlayButton(library: installedLibrary, operations: operations,
                                                    game: installed, usesGlass: true, prominent: true)
                            }
                            InstalledGameActions(library: installedLibrary, operations: operations,
                                                 game: installed, usesGlass: true)
                        } else if canReviewGamePass {
                            GameInstallAction(game: owned ?? PCGame(product: product), operations: operations,
                                              enabled: allowsStartupTasks,
                                              disabledReason: installAccessReason)
                        } else if gamePass, !operations.usesUnifiedAccount {
                            Button {
                                operations.checkGamePass(
                                    discoveryProducts: session.gamePassProducts,
                                    ownedGames: library.accessIsCurrent ? library.representedGames : nil
                                )
                            } label: {
                                Label("Check Game Pass access", systemImage: "checkmark.shield")
                            }
                            .modifier(LibraryActionStyle())
                            .disabled(!allowsStartupTasks || !operations.canStartMutation || !library.accessIsCurrent)
                            .help(library.accessIsCurrent
                                  ? "Verify this account's current PC Game Pass download access."
                                  : "Refresh your PC library before checking Game Pass access.")
                            if let status = GameDetailFacetCopy.gamePassCheckStatus(
                                libraryAccessIsCurrent: library.accessIsCurrent) {
                                Text(status)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            GameInstallAction(game: owned ?? PCGame(product: product), operations: operations,
                                              enabled: false, disabledReason: installAccessReason)
                        }
                    }.controlSize(.large)
                    if let installed {
                        InstalledPlayError(library: installedLibrary, game: installed)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.bottom, 48)
        }
        .frame(height: 388).clipped()
        .foregroundStyle(.white)
        .environment(\.libraryOnHeroMedia, true)
        .environment(\.colorScheme, .dark)
        .padding(.bottom, -42)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func media(_ details: CatalogDetailFacts) -> some View {
        if !details.trailers.isEmpty || !details.screenshots.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trailers and screenshots").font(.title2.weight(.semibold))
                if let trailer = details.trailers.first {
                    CatalogTrailerView(trailer: trailer, allowsLoading: allowsArtworkLoading,
                                       allowsPlayback: allowsStartupTasks)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                if !details.screenshots.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(details.screenshots.enumerated()), id: \.element.url) { index, image in
                                CatalogArtworkView(reference: allowsArtworkLoading ? image : nil, status: .available)
                                    .frame(width: 320, height: 180).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .accessibilityLabel("Screenshot \(index + 1) of \(details.screenshots.count)")
                            }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                }
            }
        }
    }

    private func gameInfo(_ details: CatalogDetailFacts) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if details.developer != nil || details.publisher != nil || details.releaseDate != nil ||
                details.storeRating != nil || details.contentRating != nil {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    if let developer = details.developer { facet("Developer", developer) }
                    if let publisher = details.publisher { facet("Publisher", publisher) }
                    if let release = details.releaseDate {
                        facet("Release date", release.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let rating = details.storeRating {
                        facet("Microsoft Store rating",
                              "\(rating.average.formatted(.number.precision(.fractionLength(1)))) / 5 · \(rating.count.formatted()) ratings")
                    }
                    if let rating = details.contentRating {
                        facet("Content rating", ([rating.label] + rating.descriptors + rating.interactiveElements).joined(separator: " · "))
                    }
                }.font(.callout)
            }
        }
    }

    @ViewBuilder private func requirements(_ details: CatalogDetailFacts) -> some View {
        if let requirements = details.requirements {
            VStack(alignment: .leading, spacing: 16) {
                Text("Windows PC requirements").font(.title2.weight(.semibold))
                Text("Publisher-provided PC requirements, not a Mac compatibility assessment.")
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    if let cpu = requirements.MinimumProcessor { facet("Minimum CPU", cpu) }
                    if let gpu = requirements.MinimumGraphics { facet("Minimum GPU", gpu) }
                    if let cpu = requirements.RecommendedProcessor { facet("Recommended CPU", cpu) }
                    if let gpu = requirements.RecommendedGraphics { facet("Recommended GPU", gpu) }
                }.font(.callout)
            }
        } else if details.requirementsVaryByEdition {
            Text("PC requirements vary by edition. Check the publisher's requirements for your edition.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func facet(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
