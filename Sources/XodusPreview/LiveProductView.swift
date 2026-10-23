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

    static func access(acquisition: PCGameAcquisitionKind?, current: Bool) -> String {
        guard let acquisition else { return "Access not verified" }
        let label = acquisition == .subscription ? "Subscription (plan unknown)" : "Owned"
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
    @ObservedObject private var catalog = LibraryCatalogArtwork.shared
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
    private var access: LibraryAccess? {
        (library.accessIsCurrent ? owned : nil)
            .map { $0.acquisitionKind == .subscription ? .subscription : .owned } ?? (gamePass ? .gamePass : nil)
    }
    private var canReviewGamePass: Bool {
        DiscoverBrowse.canReviewInstall(owned: owned != nil, accessIsCurrent: library.accessIsCurrent,
            gamePass: gamePass, subscriptionActive: operations.gamePassActive,
            pcCandidate: owned != nil || product.pcCatalogCandidate)
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
                        GameOperationProgressView(operations: operations, productID: product.id)
                        if let status = GameDetailFacetCopy.precheckStatus(
                            productID: product.id, installed: installed != nil,
                            precheckingProductID: operations.precheckingProductID) {
                            ProgressView(status).controlSize(.small)
                        }
                        if let installed {
                            InstalledGameAttentionView(installed: installedLibrary, operations: operations,
                                game: installed, repairGame: library.accessIsCurrent ? owned : nil,
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
                            gameInfo(details)
                            requirements(details)
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
        .environment(\.colorScheme, .dark)
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
                    LibraryGameInformation(access: access, gamePass: gamePass,
                                           facts: art?.facts, xbox: stats.cache?.games[product.id],
                                           showsPrice: owned == nil && installed == nil)
                    if let details {
                        GameHeroMetadata(details: details)
                    }
                    LibraryGameSizeView(installed: installed, downloadBytes: art?.facts.downloadBytes,
                                        productID: product.id, pcPackageListed: pcPackageListed,
                                        packageFormat: art?.facts.packageFormat,
                                        allowsMeasurement: allowsArtworkLoading)
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
                                .disabled(!allowsStartupTasks || !library.accessIsCurrent
                                          || !operations.canStartMutation)
                            } else {
                                InstalledPlayButton(library: installedLibrary, operations: operations,
                                                    game: installed, usesGlass: true, prominent: true)
                            }
                            InstalledGameActions(library: installedLibrary, operations: operations,
                                                 game: installed, usesGlass: true)
                        } else if let owned {
                            GameInstallAction(game: owned, operations: operations,
                                              enabled: allowsStartupTasks && library.accessIsCurrent)
                        } else if canReviewGamePass {
                            GameInstallAction(game: PCGame(product: product), operations: operations,
                                              enabled: allowsStartupTasks && canReviewGamePass)
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
                        } else {
                            Button("Install", systemImage: "icloud.and.arrow.down") {
                                Task { await operations.install(PCGame(product: product)) }
                            }
                            .modifier(LibraryActionStyle())
                            .disabled(true)
                            .help("Current ownership or Game Pass access is required to install this game.")
                        }
                        CatalogAcquisitionAction(productID: product.id, title: product.title,
                            market: product.market, language: product.language,
                            licensed: library.accessIsCurrent && owned != nil,
                            gamePass: gamePass && !installedLibrary.hasCurrentAccess(to: product.id),
                            commerce: art?.facts.commerce,
                            enabled: allowsStartupTasks && session.hasConfirmedSignIn && library.accessIsCurrent)
                    }.controlSize(.large)
                    if let installed {
                        InstalledPlayError(library: installedLibrary, game: installed)
                        if !installedLibrary.hasCurrentAccess(to: product.id) {
                            Button("Refresh PC library") { library.refresh() }
                                .disabled(!allowsStartupTasks || library.busy || !session.hasConfirmedSignIn)
                                .help("Check this account's current game access before playing.")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.bottom, 48)
        }
        .frame(height: 388).clipped()
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
                Text("Game information").font(.title2.weight(.semibold))
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
