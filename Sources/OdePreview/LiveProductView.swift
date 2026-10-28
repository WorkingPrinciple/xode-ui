// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import OdeManagement

struct GameDescriptionParagraphs: Equatable {
    let first: String
    let remaining: String

    init(_ description: String) {
        let text = description.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        var hasProse = false
        var hasList = false
        var boundary = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if hasProse || hasList {
                    boundary = index
                    break
                }
                continue
            }
            let heading = trimmed.unicodeScalars.contains(where: CharacterSet.letters.contains)
                && trimmed == trimmed.uppercased() && trimmed != trimmed.lowercased()
            let bullet = trimmed.range(of: #"^(?:[-*•]\s+|\d+[.)]\s+)"#,
                                       options: .regularExpression) != nil
            if (hasProse && (heading || bullet)) || (hasList && heading) {
                boundary = index
                break
            }
            if bullet { hasList = true }
            else if !heading { hasProse = true }
        }
        first = lines[..<boundary].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        remaining = lines[boundary...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GameDescriptionView: View {
    let gameID: String
    let description: String

    var body: some View {
        GameDescriptionContent(description: description).id(gameID)
    }
}

private struct GameDescriptionContent: View {
    let description: String
    @State private var expanded = false

    var body: some View {
        let paragraphs = GameDescriptionParagraphs(description)
        VStack(alignment: .leading, spacing: 14) {
            Text("About the game").font(.title2.weight(.semibold))
            Text(paragraphs.first).textSelection(.enabled)
            if !paragraphs.remaining.isEmpty {
                DisclosureGroup("More", isExpanded: $expanded) {
                    Text(paragraphs.remaining).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("ode.game.description.expand")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 680, alignment: .leading)
    }
}

enum GameDetailFacetCopy {
    static func installation(installed: Bool) -> String {
        installed ? "Installed on this Mac" : "Not installed"
    }

    static func unsupportedInstallMessage(_ issues: [LibraryCompatibilityIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        return "Installation isn't available. " + issues.map(\.browseDetail).joined(separator: " ")
    }

    static func precheckStatus(productID: String, installed: Bool, precheckingProductID: String?) -> String? {
        guard !installed, precheckingProductID == productID else { return nil }
        return "Checking installation requirements"
    }

    static func gamePassActionStatus(startupAllowed: Bool, libraryNotice: String?,
                                     operationNotice: String?) -> String? {
        if !startupAllowed { return "Wait for \(AppBrand.displayName) to finish starting." }
        return libraryNotice ?? operationNotice
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
        .accessibilityIdentifier("ode.game.heroMetadata")
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
    var queue: DownloadQueueController? = nil
    var installationID: UUID? = nil
    var allowsStartupTasks = true
    var allowsArtworkLoading = true
    var reviewInstall: ((PCGame) -> Void)? = nil
    @EnvironmentObject private var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var catalog = LibraryCatalogArtwork.shared
    @ObservedObject private var stats = LibraryXboxStats.shared
    /// 72450bd3 M2: the app's one access store, so a product page shares its cache and backoff.
    private var titleAccess: InstalledProductAccess { installedLibrary.productAccess }

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
    /// Badges show PC Game Pass only for titles in the current live public list.
    private var gameFacts: GameFacts {
        var facts = GameFacts(pc: owned, gamePass: session.gamePassBadgeProductIDs.contains(product.id), installed: installed,
                             accessIsCurrent: library.accessIsCurrent(for: product.id))
        facts.freeToPlay = catalog.freeToPlayIDs.contains(product.id)
        return facts
    }
    /// The complete, error-free public PC Game Pass list doesn't include this game and it isn't owned.
    private var publicGamePassExcludes: Bool {
        owned == nil && session.gamePassCatalogComplete() && !session.gamePassProductIDs.contains(product.id)
    }
    private var notIncluded: Bool {
        checksTitleAccess && titleAccess.notIncluded(product.id, account: session.accountHash,
                                                     publicGamePassExcludes: publicGamePassExcludes)
    }
    private var canReviewGamePass: Bool {
        currentTitleAccess || DiscoverBrowse.canReviewInstall(owned: owned != nil, accessIsCurrent: library.accessIsCurrent(for: product.id),
            gamePass: gamePass, subscriptionActive: operations.gamePassActive,
            pcCandidate: owned != nil || product.pcCatalogCandidate)
    }
    private var currentTitleAccess: Bool {
        operations.usesUnifiedAccount && session.hasConfirmedSignIn
            && titleAccess.permitsReview(product.id, account: session.accountHash,
                                         pcCandidate: product.pcCatalogCandidate)
    }
    private var checksTitleAccess: Bool {
        operations.usesUnifiedAccount && session.hasConfirmedSignIn
            && product.pcCatalogCandidate && !library.accessIsCurrent(for: product.id)
    }
    private var installAccessReason: String? {
        if !allowsStartupTasks { return "Wait for \(AppBrand.displayName) to finish starting." }
        if checksTitleAccess {
            if !titleAccess.checking && session.nativeLifecycleConfiguration == nil {
                return operations.installUnavailableReason ?? "Account access is busy. Wait before checking this game."
            }
            return titleAccess.reviewNotice(for: product.id, account: session.accountHash,
                                            publicGamePassExcludes: publicGamePassExcludes)
        }
        if let notice = library.accountReadiness.notice { return notice }
        if owned == nil && !product.pcCatalogCandidate {
            return "PC availability for this title hasn't been confirmed. Installation is unavailable."
        }
        if gamePass && !operations.gamePassActive && owned == nil {
            return "PC Game Pass download access hasn't been confirmed for this account."
        }
        return library.installAccessNotice(for: product.id)
    }
    private var installRecovery: PCGamesInstallRecovery {
        guard allowsStartupTasks else { return .none }
        if checksTitleAccess { return .none }
        if library.accountReadiness == .ready && owned == nil && !product.pcCatalogCandidate { return .none }
        return library.installRecovery(for: product.id)
    }
    private func recoverInstall() {
        if notIncluded { return }
        if checksTitleAccess {
            guard session.nativeLifecycleConfiguration != nil else { openSettings(); return }
            // 9015da43 m4: "Try Again after HH:MM" does nothing until then; the label already says so.
            guard titleAccess.pausedEnd() == nil else { return }
            Task { await titleAccess.checkProduct(product.id, session: session, force: true) }
            return
        }
        switch installRecovery {
        case .none: break
        case .accountSettings: openSettings()
        case .refreshLibrary: library.refresh()
        case .retryLibrary: Task { await library.retryLibraryLoad() }
        }
    }
    private var installRecoveryTitle: String? {
        if notIncluded { return nil }
        if checksTitleAccess {
            if titleAccess.checking { return nil }
            if session.nativeLifecycleConfiguration == nil { return "Account settings" }
            return titleAccess.errors[product.id] != nil ? titleAccess.tryAgainTitle() : "Check access for this game"
        }
        return installRecovery.title
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
                                game: installed, repairGame: library.accessIsCurrent(for: product.id) ? owned : nil,
                                installationCheckInHeader: unsupportedIssues.isEmpty
                                   && !(installedLibrary.placeholderIDs.contains(installed.id) && owned != nil)
                                   && InstalledPlayButton(library: installedLibrary, operations: operations,
                                       game: installed).ownsInstallationCheck,
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
                            if let description = details.description ?? details.shortDescription {
                                GameDescriptionView(gameID: product.id, description: description)
                                .id("detail-information")
                            }
                            media(details)
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
#if !ODE_SHIPPING
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
            if allowsStartupTasks, let installed { await installedLibrary.automaticallyCheckInstallation(installed) }
        }
        .task(id: product.id) {
            guard allowsStartupTasks,
                  operations.compatibility[product.id] == nil else { return }
            operations.precheck([product.id])
        }
        .task(id: "\(product.id):\(session.accountHash ?? ""):\(session.hasConfirmedSignIn):\(operations.usesUnifiedAccount)") {
            guard allowsStartupTasks, checksTitleAccess else { return }
            await titleAccess.checkProduct(product.id, session: session)
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
            HStack(alignment: .top, spacing: 24) {
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
                            if let installed {
                                LibraryCompatibilityIndicators(issues: unsupportedIssues, heroStyle: true)
                                InstalledGameActions(library: installedLibrary, operations: operations,
                                                     game: installed, usesGlass: true)
                            } else if let message = GameDetailFacetCopy.unsupportedInstallMessage(unsupportedIssues) {
                                InstallUnavailableNotice(message: message)
                            }
                        } else if let installed {
                            if installedLibrary.placeholderIDs.contains(installed.id), let owned {
                                Button {
                                    Task { await operations.repair(owned, installed: installed, intent: .downloadFullGame) }
                                } label: {
                                    Label("Download full game", systemImage: "icloud.and.arrow.down")
                                }
                                .modifier(LibraryActionStyle())
                                .disabled(!allowsStartupTasks || !library.accessIsCurrent(for: product.id)
                                          || !operations.canStartMutation)
                                if !allowsStartupTasks || !library.accessIsCurrent(for: product.id) || !operations.canStartMutation {
                                    InstallUnavailableNotice(message: !allowsStartupTasks
                                        ? "Wait for \(AppBrand.displayName) to finish starting."
                                        : library.installAccessNotice(for: product.id)
                                            ?? operations.installUnavailableReason ?? "Installation is not available yet.",
                                        recoveryTitle: library.accessIsCurrent(for: product.id) ? nil : installRecovery.title,
                                        recover: recoverInstall)
                                }
                            } else {
                                InstalledPlayButton(library: installedLibrary, operations: operations,
                                                    game: installed, displayTitle: product.title, usesGlass: true, prominent: true,
                                                    showsDiagnostics: false)
                            }
                            InstalledGameActions(library: installedLibrary, operations: operations,
                                                 game: installed, usesGlass: true)
                        } else if canReviewGamePass {
                            GameInstallAction(game: owned ?? PCGame(product: product), operations: operations,
                                              enabled: allowsStartupTasks,
                                              disabledReason: installAccessReason,
                                              recoveryTitle: operations.installAccountUnavailable ? "Account settings" : nil,
                                              recover: { openSettings() }, reviewInstall: reviewInstall, queue: queue)
                        } else if gamePass, !operations.usesUnifiedAccount {
                            VStack(alignment: .leading, spacing: 8) {
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
                            if let status = GameDetailFacetCopy.gamePassActionStatus(
                                startupAllowed: allowsStartupTasks, libraryNotice: library.gamePassCheckNotice,
                                operationNotice: operations.installUnavailableReason) {
                                InstallUnavailableNotice(message: status,
                                    recoveryTitle: library.gamePassCheckNotice == nil ? nil : installRecovery.title,
                                    recover: recoverInstall)
                            }
                            }
                        } else {
                            GameInstallAction(game: owned ?? PCGame(product: product), operations: operations,
                                              enabled: false, disabledReason: installAccessReason,
                                              recoveryTitle: installRecoveryTitle, recover: recoverInstall)
                        }
                    }.controlSize(.large)
                    if let installed, !InstalledGameAttentionView(installed: installedLibrary, operations: operations,
                        game: installed, close: dismiss.callAsFunction).needsAttention {
                        InstalledPlayError(library: installedLibrary, game: installed)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.bottom, 48)
        }
        .frame(minHeight: 388).clipped()
        .foregroundStyle(.white)
        .environment(\.libraryOnHeroMedia, true)
        .environment(\.colorScheme, .dark)
        .padding(.bottom, -42)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func media(_ details: CatalogDetailFacts) -> some View {
        if !details.trailers.isEmpty || !details.screenshots.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !details.screenshots.isEmpty {
                    Text("Screenshots").font(.title2.weight(.semibold))
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
                if let trailer = details.trailers.first {
                    Text("Trailer").font(.title2.weight(.semibold))
                    CatalogTrailerView(trailer: trailer, allowsLoading: allowsArtworkLoading,
                                       allowsPlayback: allowsStartupTasks)
                        .frame(maxWidth: 640, alignment: .leading)
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
