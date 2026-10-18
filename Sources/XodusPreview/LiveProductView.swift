// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

enum GameDetailFacetCopy {
    static func installation(installed: Bool) -> String {
        installed ? "Installed on this Mac" : "Not installed"
    }

    static func access(acquisition: PCGameAcquisitionKind?, current: Bool) -> String {
        guard let acquisition else { return "Access not verified" }
        let label = acquisition == .subscription ? "Subscription (plan unknown)" : "Owned"
        return current ? label : "Saved \(label) - refresh required"
    }
}

struct LiveProductView: View {
    let product: CatalogProduct
    @ObservedObject var library: PCGamesController
    @ObservedObject var installedLibrary: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    var allowsStartupTasks = true
    var allowsArtworkLoading = true
    @EnvironmentObject private var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = LibraryCatalogArtwork.shared
    @ObservedObject private var stats = LibraryXboxStats.shared

    private var installed: InstalledGame? { installedLibrary.games.first { $0.storeId == product.id } }
    private var owned: PCGame? { library.representedGames.first { $0.id == product.id } }
    private var gamePass: Bool {
        session.gamePassProductIDs.contains(product.id)
    }
    private var art: LibraryCatalogArtwork.Images? { catalog.images[product.id] }
    private var details: CatalogDetailFacts? { art?.detail }
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
    private var unsupportedReason: String? {
        LibrarySupportVisibility.unsupportedReason(
            installed: installed != nil,
            packageFormat: art?.facts.packageFormat,
            compatibility: operations.compatibility[product.id]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                LibraryAmbientBackdrop(references: landscape, installed: installed,
                                       allowsLoading: allowsArtworkLoading, height: 900)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        VStack(alignment: .leading, spacing: 28) {
                        GameOperationProgressView(operations: operations, productID: product.id)
                        if owned != nil, installed == nil {
                            Text("Your library record is separate from download access. X Ode checks this edition's package and authorization when you install.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        evidence
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
                        }.padding(.horizontal, 40).padding(.bottom, 72)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .frame(minWidth: 820, idealWidth: 1040, maxWidth: 1200,
               minHeight: 600, idealHeight: 780, maxHeight: 850)
        .task(id: "\(product.id):\(product.market):\(product.language)") {
            if allowsArtworkLoading {
                await catalog.loadDetail(id: product.id, market: product.market, language: product.language)
            }
        }
        .task(id: "\(product.id):\(installed == nil):\(operations.canStartMutation)") {
            guard allowsStartupTasks, installed == nil, operations.canStartMutation,
                  operations.compatibility[product.id] == nil else { return }
            operations.precheck([product.id])
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LibraryLandscapeView(references: landscape, installed: installed, allowsLoading: allowsArtworkLoading)
            LinearGradient(colors: [.clear, .black.opacity(0.12),
                                    Color(nsColor: .windowBackgroundColor).opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
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
                                           facts: art?.facts, xbox: stats.cache?.games[product.id])
                    LibraryGameSizeView(installed: installed, downloadBytes: art?.facts.downloadBytes,
                                        packageFormat: art?.facts.packageFormat,
                                        allowsMeasurement: allowsArtworkLoading)
                    if let date = installed?.lastPlayedAt {
                        Text("Last played \(date.formatted(.relative(presentation: .named))) on this Mac")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LibraryGlassCluster {
                        if let installed {
                            InstalledPlayButton(library: installedLibrary, operations: operations,
                                                game: installed, usesGlass: true, prominent: true)
                            InstalledGameActions(library: installedLibrary, operations: operations,
                                                 game: installed, usesGlass: true)
                        } else if let unsupportedReason {
                            LibraryUnsupportedLabel(reason: unsupportedReason, heroStyle: true)
                            Link("View in Microsoft Store",
                                 destination: URL(string: "https://apps.microsoft.com/detail/\(product.id)")!)
                                .modifier(LibraryActionStyle(primary: false))
                        } else if let owned {
                            Button {
                                Task { await operations.install(owned) }
                            } label: {
                                Label("Install", systemImage: "icloud.and.arrow.down")
                            }
                                .modifier(LibraryActionStyle())
                                .disabled(!allowsStartupTasks || !library.accessIsCurrent || !operations.canStartMutation
                                          || operations.compatibility[product.id]?.supported != true)
                                .help("Install \(product.title)")
                                .accessibilityLabel("Install \(product.title)")
                        } else if canReviewGamePass {
                            Button {
                                Task { await operations.install(PCGame(product: product)) }
                            } label: {
                                Label("Install", systemImage: "icloud.and.arrow.down")
                            }
                            .modifier(LibraryActionStyle())
                            .disabled(!allowsStartupTasks || !operations.canStartMutation || !canReviewGamePass
                                      || operations.compatibility[product.id]?.supported != true)
                            .help("Install \(product.title)")
                            .accessibilityLabel("Install \(product.title)")
                        } else {
                            Link("View in Microsoft Store",
                                 destination: URL(string: "https://apps.microsoft.com/detail/\(product.id)")!)
                                .modifier(LibraryActionStyle())
                        }
                    }.controlSize(.large)
                    if installed == nil, operations.precheckingProductID == product.id {
                        ProgressView("Checking Mac compatibility").controlSize(.small)
                    }
                    if let installed { InstalledPlayError(library: installedLibrary, game: installed) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.bottom, 24)
        }.frame(height: 340).clipped().accessibilityElement(children: .contain)
    }

    private var evidence: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            facet("Library", GameDetailFacetCopy.access(acquisition: owned?.acquisitionKind,
                                                      current: library.accessIsCurrent))
            if gamePass { facet("Game Pass catalog", "PC catalogue member - account access checked separately") }
            facet("Installation", GameDetailFacetCopy.installation(installed: installed != nil))
        }
        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
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
