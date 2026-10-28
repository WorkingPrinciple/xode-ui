// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import OSLog
import XodusCredentials
import XodusManagement

enum PCGamesAccountReadiness {
    case ready, closing, updating, keychainApproval, signIn, unavailable, accountMismatch

    var notice: String? {
        switch self {
        case .ready: nil
        case .closing: "Account access is closing. Installation is unavailable."
        case .updating: "Wait for your library to finish updating before installing."
        case .keychainApproval: "Approve Keychain access in Account settings, then refresh your library."
        case .signIn: "Sign in in Account settings, then refresh your library to check access."
        case .unavailable: "Your library couldn't be updated. Refresh your library to check access before installing."
        case .accountMismatch: "Refresh your library for the current account before installing."
        }
    }

    func gamePassCheckNotice(libraryIsComplete: Bool) -> String? {
        notice ?? (libraryIsComplete ? nil : "Refresh your PC library before checking Game Pass access.")
    }
}

enum PCGamesInstallRecovery {
    case none, accountSettings, refreshLibrary, retryLibrary

    var title: String? {
        switch self {
        case .none: nil
        case .accountSettings: "Account settings"
        case .refreshLibrary: "Refresh library"
        case .retryLibrary: "Try loading library again"
        }
    }
}

@MainActor
final class PCGamesController: ObservableObject {
    @Published private(set) var hasSavedSignIn = false
    @Published private(set) var needsSignIn = false
    @Published private(set) var busy = false
    @Published private(set) var sheetPresented = false
    @Published private(set) var deviceCode: PCGamesDeviceCode?
    @Published private(set) var snapshot: PCGamesSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var needsKeychainApproval = false
    @Published private(set) var approvingKeychain = false
    @Published private(set) var legacyKeychainRetained = false
    @Published private(set) var restoringPresence = false
    @Published private(set) var presenceUnavailable = false
    /// REQ-119: this scope's collection read has been sent, or can't be; background account reads wait for it.
    @Published private(set) var collectionReadStarted = false
    /// REQ-7/63: active Game Pass plan IDs from the last collection read, bound to the account that read it.
    @Published private(set) var activeGamePassPlans: Set<String> = []
    private var activeGamePassPlansAccount: String?
    private(set) var accountDisconnecting = false
    private let store: any PCGamesRefreshStore
    private let client: PCGamesClient
    private let market: String
    private let language: String
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var restored = false
    private var terminating = false
    private var attemptedAutomaticLoad = false
    private let signInOwner = UUID()
    private weak var unifiedSession: LiveSession?
    private(set) var usesUnifiedAccount = false
    private var lastAutomaticAttempt: (account: String, date: Date)?
    private var snapshotScope: String?
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")

    func useUnifiedAccount(_ session: LiveSession) {
        if usesUnifiedAccount, unifiedSession === session { return }
        guard !busy, !restoringPresence else { return }
        unifiedSession = session
        usesUnifiedAccount = true
    }

    /// The snapshot only while it belongs to the current account, country and market.
    var representedSnapshot: PCGamesSnapshot? {
        guard !needsSignIn else { return nil }
        if usesUnifiedAccount {
            guard unifiedSession?.hasConfirmedSignIn == true,
                  unifiedSession?.accountCountryReady == true,
                  snapshotScope == unifiedSession?.accountCatalogScope,
                  accountHash == unifiedSession?.accountHash else { return nil }
        }
        return snapshot
    }
    var representedGames: [PCGame] { representedSnapshot?.games ?? [] }
    var accountHash: String? { snapshot?.boundAccountHash ?? snapshot?.accountID.flatMap(XboxAccountBinding.hash) }
    /// P0 (owner): missing game details recover silently. Nothing shows while any game is usable; a quiet,
    /// non-actionable line shows only after the automatic retries are used up and no game could be shown.
    var resolutionNotice: String? {
        Self.detailNotice(busy: busy, detailFailures: snapshot?.detailFailureCount ?? 0,
                          usableGames: representedGames.count, retriesLeft: detailRetriesLeft)
    }
    static let detailUnavailableNotice = "Game details are still loading from Microsoft."
    static let detailRetryDelays: [Duration] = [.seconds(4), .seconds(15), .seconds(60)]
    static func detailNotice(busy: Bool, detailFailures: Int, usableGames: Int, retriesLeft: Int) -> String? {
        guard !busy, detailFailures > 0, usableGames == 0, retriesLeft == 0 else { return nil }
        return detailUnavailableNotice
    }
    @Published private(set) var detailRetriesLeft = PCGamesController.detailRetryDelays.count
    private var detailRetry: Task<Void, Never>?
    private var detailRetryToken: UUID?
    /// True only while a silent retry is actually waiting to fire; cleared however that task ends.
    @Published private(set) var detailRetryPending = false
    /// P0: a read error stays quiet while a silent retry is scheduled; it shows once the retries are used up.
    var surfacedError: String? { Self.surfacedError(error, retryPending: detailRetryPending) }
    static func surfacedError(_ error: String?, retryPending: Bool) -> String? { retryPending ? nil : error }

    /// Re-reads the library after a backoff while some details failed; bounded, cancelled by sign-out.
    /// bc33adf2 M-a: Microsoft throttling (with its delay) and a rejected sign-in stop automatic library retries.
    private(set) var throttledUntil: Date?
    nonisolated static func automaticRetryAllowed(after error: Error) -> Bool {
        switch error as? ManagementError {
        case .authenticatedReadThrottled?, .recentLibraryThrottled?, .authenticatedReadFailed(.authExchangeFailed)?:
            return false
        default: return true
        }
    }
    nonisolated static func throttlePause(after error: Error) -> TimeInterval? {
        switch error as? ManagementError {
        case .authenticatedReadThrottled(let seconds)?, .recentLibraryThrottled(let seconds)?:
            return TimeInterval(seconds ?? 600)
        default: return nil
        }
    }

    func recordThrottle(after error: Error, now: Date = Date()) {
        if let pause = Self.throttlePause(after: error) { throttledUntil = now.addingTimeInterval(pause) }
    }

    /// bc33adf2 M-a: whether an automatic detail retry may be scheduled at `now` (none during a throttle).
    func detailRetryAllowed(now: Date = Date()) -> Bool {
        throttledUntil.map { now >= $0 } ?? true
    }

    func scheduleDetailRetry(account: String, now: Date = Date()) {
        guard detailRetryAllowed(now: now) else { return }
        cancelDetailRetry()
        let attempt = Self.detailRetryDelays.count - detailRetriesLeft
        guard attempt >= 0, attempt < Self.detailRetryDelays.count else { return }
        let delay = Self.detailRetryDelays[attempt]
        let token = UUID()
        detailRetryToken = token
        detailRetryPending = true
        detailRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            // Review M1: a retry that exits without firing must not keep the error hidden.
            if self.detailRetryToken == token { self.cancelDetailRetry() }
            guard !Task.isCancelled, !self.busy, !self.terminating, !self.accountDisconnecting,
                  self.unifiedSession?.accountHash == account else { return }
            self.detailRetriesLeft -= 1
            self.logger.notice("Retrying unavailable game details silently; \(self.detailRetriesLeft) retries left")
            self.refreshUnifiedAccount()
        }
    }
    private func cancelDetailRetry() {
        detailRetry?.cancel()
        detailRetry = nil
        detailRetryToken = nil
        if detailRetryPending { detailRetryPending = false }
    }

    var retainedLibraryNotice: String? {
        guard error != nil, let snapshot else { return nil }
        return snapshot.isComplete ? "Showing the last complete library."
            : "Showing available details from an incomplete library."
    }
    var accessIsCurrent: Bool {
        snapshot?.isComplete == true && snapshot?.restored == false && accountAccessIsCurrent
    }
    /// REQ-119: the library on screen is the saved copy, still being read again from the account.
    var showingSavedLibrary: Bool { representedSnapshot?.restored == true }
    /// REQ-119: injectable saved-library store; nil keeps checks and previews isolated.
    var savedLibrary: LibrarySnapshotStore? = LibrarySnapshotStore.production

    /// REQ-119: draws the saved library for this account and catalogue scope at once on a warm launch.
    /// Only fills an empty library; the account read replaces it. Returns whether a saved library is shown.
    @discardableResult
    func restoreSavedLibrary() -> Bool {
        guard usesUnifiedAccount, snapshot == nil, let session = unifiedSession, session.hasConfirmedSignIn,
              session.accountCountryReady, let account = session.accountHash,
              let saved = savedLibrary?.load(accountHash: account, market: session.market,
                                             language: session.language) else { return false }
        snapshot = saved.snapshot()
        snapshotScope = session.accountCatalogScope
        FirstLoadTimeline.mark("savedLibraryShown", "games=\(saved.games.count)")
        logger.notice("Showing the saved library while the account is read again")
        return true
    }
    private var accountAccessIsCurrent: Bool {
        accountReadiness == .ready
    }
    var accountReadiness: PCGamesAccountReadiness {
        if accountDisconnecting || terminating { return .closing }
        if busy || restoringPresence { return .updating }
        if needsKeychainApproval { return .keychainApproval }
        if presenceUnavailable { return .unavailable }
        if !hasSavedSignIn || needsSignIn { return .signIn }
        if error != nil { return .unavailable }
        if usesUnifiedAccount && (unifiedSession?.hasConfirmedSignIn != true
            || unifiedSession?.accountCountryReady != true
            || snapshotScope != unifiedSession?.accountCatalogScope
            || accountHash != unifiedSession?.accountHash) { return .accountMismatch }
        return .ready
    }
    var gamePassCheckNotice: String? {
        accountReadiness.gamePassCheckNotice(libraryIsComplete: snapshot?.isComplete == true)
    }
    func installRecovery(for productID: String) -> PCGamesInstallRecovery {
        switch accountReadiness {
        case .closing, .updating: return .none
        case .keychainApproval, .signIn: return .accountSettings
        case .unavailable: return presenceUnavailable ? .retryLibrary : .refreshLibrary
        case .accountMismatch: return .refreshLibrary
        case .ready:
            return snapshot?.unresolvedIDs.contains(productID) == true ? .refreshLibrary : .accountSettings
        }
    }
    /// A current, same-account licence read reported an active Game Pass plan. Never inferred from Play,
    /// installed files or catalogue membership; a different or unready account reads as no plan.
    var gamePassPlanActive: Bool {
        accountAccessIsCurrent && activeGamePassPlansAccount != nil
            && activeGamePassPlansAccount == accountHash && !activeGamePassPlans.isEmpty
    }

    func accessIsCurrent(for productID: String) -> Bool {
        accountAccessIsCurrent && snapshot?.hasResolvedGame(productID) == true
    }
    func installAccessNotice(for productID: String) -> String? {
        guard !accessIsCurrent(for: productID) else { return nil }
        if let notice = accountReadiness.notice { return notice }
        if snapshot?.unresolvedIDs.contains(productID) == true {
            return "PC game details for this title couldn't be loaded. Refresh your library to try again."
        }
        return "Current ownership or active PC Game Pass access is required to install this game."
    }

    init(store: any PCGamesRefreshStore = PCGamesCredentialStore(), client: PCGamesClient = PCGamesClient(),
         market: String = "US",
         language: String = PCGamesClient.language(Locale.preferredLanguages.first ?? "en-US")) {
        self.store = store
        self.client = client
        self.market = market
        self.language = language
    }

    func restorePresence() async {
        guard !restored, !restoringPresence, !busy, !accountDisconnecting, !terminating else { return }
        if usesUnifiedAccount {
            hasSavedSignIn = unifiedSession?.hasConfirmedSignIn == true
            restored = true
            return
        }
        restoringPresence = true
        defer { restoringPresence = false }
        let token = generation
        do {
            let present = try await store.contains()
            guard generation == token, !terminating else { return }
            let approval = try await store.migrationRequired()
            guard generation == token, !terminating else { return }
            let retained = try await store.legacyRetained()
            guard generation == token, !terminating else { return }
            hasSavedSignIn = present
            needsKeychainApproval = approval
            legacyKeychainRetained = retained
            restored = true
            presenceUnavailable = false
            error = nil
        } catch {
            guard generation == token, !terminating else { return }
            presenceUnavailable = true
            self.error = Self.message(error)
        }

    }

    func loadOnAppear() async {
        if usesUnifiedAccount {
            await refreshInBackground()
            return
        }
        guard !attemptedAutomaticLoad, !accountDisconnecting, !terminating else { return }
        await restorePresence()
        guard restored else { return }
        attemptedAutomaticLoad = true
        guard snapshot == nil, hasSavedSignIn, !needsKeychainApproval, !needsSignIn, !busy, error == nil else { return }
        refresh()
    }

    /// A user, explicit or foreground refresh restarts the bounded silent-retry budget (review M3).
    func resetDetailRetries() {
        cancelDetailRetry()
        detailRetriesLeft = Self.detailRetryDelays.count
    }

    func refreshInBackground(now: Date = Date()) async {
        guard usesUnifiedAccount, !busy, !accountDisconnecting, !terminating,
              let session = unifiedSession, session.hasConfirmedSignIn,
              let account = session.accountHash else { return }
        if let lastAutomaticAttempt, lastAutomaticAttempt.account == account,
           now.timeIntervalSince(lastAutomaticAttempt.date) < 60 { return }
        if accountHash != account { snapshot = nil }
        hasSavedSignIn = true
        needsSignIn = false
        restored = true
        lastAutomaticAttempt = (account, now)
        resetDetailRetries()
        refreshUnifiedAccount()
        await waitForLoad()
    }

    func retryLibraryLoad() async {
        resetDetailRetries()
        guard !busy, !restoringPresence, !accountDisconnecting, !terminating else { return }
        restored = false
        await restorePresence()
        guard restored, hasSavedSignIn, !needsKeychainApproval, !needsSignIn else { return }
        refresh()
    }

    func signIn() {
        if usesUnifiedAccount {
            error = "Use Account to reconnect your Xbox Live sign-in."
            return
        }
        guard !busy, !restoringPresence, !presenceUnavailable, !needsKeychainApproval,
              !accountDisconnecting, !terminating else { return }
        guard MicrosoftSignInGate.shared.acquire(signInOwner) else {
            error = "Finish or cancel the current Microsoft sign-in before starting another."
            return
        }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        deviceCode = nil
        snapshot = nil
        sheetPresented = true
        operation = Task {
            defer { MicrosoftSignInGate.shared.release(signInOwner) }
            defer { finish(token) }
            do {
                let code = try await client.deviceCode()
                try current(token)
                deviceCode = code
                let tokens = try await client.poll(code)
                try current(token)
                try await store.save(tokens.refresh)
                try current(token)
                hasSavedSignIn = true
                needsSignIn = false
                sheetPresented = false
                deviceCode = nil
                let result = try await client.library(accessToken: tokens.access, market: market, language: language) { [weak self] partial in
                    guard let self, self.generation == token, !self.terminating, !self.accountDisconnecting else { return }
                    self.snapshot = partial.retainingUnresolved(from: self.snapshot)
                }
                try current(token)
                snapshot = result.retainingUnresolved(from: snapshot)
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                self.error = Self.message(error)
            }
        }
    }

    func refresh() {
        resetDetailRetries()
        if usesUnifiedAccount {
            refreshUnifiedAccount()
            return
        }
        guard !busy, !restoringPresence, !presenceUnavailable, hasSavedSignIn,
              !needsSignIn, !needsKeychainApproval, !accountDisconnecting, !terminating else { return }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        operation = Task {
            defer { finish(token) }
            do {
                guard let saved = try await store.read() else { throw PCGamesError.signInRequired }
                try current(token)
                let tokens = try await client.refresh(saved)
                try current(token)
                try await store.save(tokens.refresh)
                try current(token)
                let result = try await client.library(accessToken: tokens.access, market: market, language: language,
                                                      expectedAccountID: snapshot?.accountID) { [weak self] partial in
                    guard let self, self.generation == token, !self.terminating, !self.accountDisconnecting else { return }
                    self.snapshot = partial.retainingUnresolved(from: self.snapshot)
                }
                try current(token)
                snapshot = result.retainingUnresolved(from: snapshot)
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                if error as? PCGamesError == .signInRequired || error as? PCGamesError == .identityMismatch {
                    needsSignIn = true
                    snapshot = nil
                }

                if error as? PCGamesError == .keychainApprovalRequired { needsKeychainApproval = true }
                self.error = Self.message(error)
            }
        }
    }

    private func refreshUnifiedAccount() {
        guard !busy, !accountDisconnecting, !terminating, let session = unifiedSession,
              session.hasConfirmedSignIn, let account = session.accountHash else { return }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        operation = Task {
            defer { finish(token) }
            do {
                if !session.accountCountryReady { await session.refreshAccountCountry() }
                try current(token)
                guard session.accountCountryReady else {
                    error = session.accountCountryError ?? "Confirm your account country to load your PC library."
                    return
                }
                let market = session.market, language = session.language
                let scope = session.accountCatalogScope
                if snapshotScope != scope { snapshot = nil }
                snapshotScope = scope
                restoreSavedLibrary()
                // This task has not entered readUnifiedAccount yet, so accountBusy cannot include itself.
                session.beginLibraryReadPriority()
                var prioritized = true
                defer { if prioritized { session.endLibraryReadPriority() } }
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                let admissionStart = ContinuousClock.now
                var heldBy = Set<String>()
                defer {
                    let waited = admissionStart.duration(to: .now).components
                    let ms = waited.seconds * 1000 + waited.attoseconds / 1_000_000_000_000_000
                    // REQ-121: which account operation the collection read waited behind, and for how long.
                    logger.notice("stage=collectionAdmission waitedMs=\(ms) heldBy=\(heldBy.sorted().joined(separator: "+"), privacy: .public)")
                }
                while session.accountBusy {
                    heldBy.formUnion(session.accountBusyReasons)
                    try current(token)
                    guard session.hasConfirmedSignIn, session.accountHash == account else {
                        throw PCGamesError.identityMismatch
                    }
                    guard session.accountCatalogScope == scope else { throw CancellationError() }
                    guard ContinuousClock.now < deadline else {
                        logger.warning("Account collection admission timed out before dispatch")
                        throw PCGamesError.libraryReadBusy
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try current(token)
                guard session.hasConfirmedSignIn, session.accountHash == account else {
                    throw PCGamesError.identityMismatch
                }
                guard session.accountCatalogScope == scope else { throw CancellationError() }
                session.endLibraryReadPriority()
                prioritized = false
                collectionReadStarted = true
                logger.notice("Account collection dispatch")
                FirstLoadTimeline.mark("collectionDispatch")
                let read = try await session.readUnifiedAccount(.library, market: market, language: language)
                let collection = try read.payload.decode(OdeAccountCollection.self)
                try collection.validate()
                try current(token)
                logger.notice("Account collection candidates: \(collection.items.count), purchased: \(collection.items.filter { $0.acquisitionKind == .purchased }.count), subscription: \(collection.items.filter { $0.acquisitionKind == .subscription }.count), unknown: \(collection.items.filter { $0.acquisitionKind == .unknown }.count)")
                FirstLoadTimeline.mark("collectionCandidates", "count=\(collection.items.count)")
                activeGamePassPlans = Set(collection.activeSubscriptions ?? [])
                activeGamePassPlansAccount = read.accountHash
                let kinds = Dictionary(uniqueKeysWithValues: collection.items.map { ($0.productID, $0.acquisitionKind) })
                let result = try await client.resolveCollection(
                    ids: collection.items.map(\.productID), kinds: kinds,
                    candidateCount: collection.items.count, market: market, language: language,
                    accountHash: read.accountHash) { [weak self, weak session] partial in
                        guard let self, let session, self.generation == token,
                              !self.terminating, !self.accountDisconnecting,
                              session.hasConfirmedSignIn, session.accountHash == read.accountHash,
                              session.accountCatalogScope == scope else { return }
                        // A saved library stays whole until the account read completes (no shrinking mid-load).
                        if self.snapshot?.restored != true {
                            self.snapshot = partial.retainingUnresolved(from: self.snapshot)
                        }
                        if !partial.games.isEmpty { FirstLoadTimeline.mark("firstGames", "count=\(partial.games.count)") }
                    }
                try current(token)
                guard session.hasConfirmedSignIn, session.accountHash == read.accountHash else {
                    throw PCGamesError.identityMismatch
                }
                guard session.accountCatalogScope == scope else { throw CancellationError() }
                snapshot = result.retainingUnresolved(from: snapshot)
                if let saved = SavedLibrary(result, accountHash: read.accountHash, market: market,
                                            language: language, savedAt: Date()) {
                    savedLibrary?.save(saved)
                }
                FirstLoadTimeline.mark("libraryResolved", "games=\(result.games.count)")
                logger.notice("Account PC resolution: \(result.games.count) games, \(result.excludedCount) excluded, \(result.unresolvedCount) unresolved")
                if result.detailFailureCount > 0, detailRetriesLeft > 0 {
                    scheduleDetailRetry(account: read.accountHash)
                } else if result.detailFailureCount == 0 {
                    detailRetriesLeft = Self.detailRetryDelays.count
                }
                hasSavedSignIn = true
                needsSignIn = false
            } catch is CancellationError { }
            catch {
                collectionReadStarted = true
                guard generation == token, !terminating else { return }
                if accountHash != session.accountHash || !session.hasConfirmedSignIn { snapshot = nil }
                if error as? PCGamesError == .libraryReadBusy {
                    self.error = PCGamesError.libraryReadBusy.localizedDescription
                } else if error as? ManagementError == .authenticatedReadFailed(.responseInvalid) {
                    self.error = "Your account library couldn't be read completely. Your installed games are still available."
                } else {
                    self.error = "Your PC library couldn't load. \(LiveSession.describe(error))"
                }
                recordThrottle(after: error)
                // Transient read failures also recover silently within the bounded budget; throttling and a
                // rejected sign-in never retry automatically.
                if Self.automaticRetryAllowed(after: error),
                   session.hasConfirmedSignIn, session.accountHash == account, detailRetriesLeft > 0 {
                    scheduleDetailRetry(account: account)
                }
            }
        }
    }

    func waitForLoad() async { await operation?.value }

    func retireUnifiedAccount() async {
        guard usesUnifiedAccount else { return }
        let token = UUID()
        generation = token
        let old = operation
        old?.cancel()
        snapshot = nil
        snapshotScope = nil
        collectionReadStarted = false
        lastAutomaticAttempt = nil
        cancelDetailRetry()
        detailRetriesLeft = Self.detailRetryDelays.count
        hasSavedSignIn = false
        restored = false
        attemptedAutomaticLoad = false
        needsSignIn = false
        error = nil
        await old?.value
        guard generation == token else { return }
        operation = nil
        busy = false
    }

    func approveKeychain() {
        guard !usesUnifiedAccount else { return }
        guard !busy, !restoringPresence, !presenceUnavailable, needsKeychainApproval,
              !accountDisconnecting, !terminating else { return }
        let token = UUID()
        generation = token
        busy = true
        approvingKeychain = true
        error = nil
        operation = Task {
            defer { finish(token) }
            do {
                try await store.migrate()
                try current(token)
                let approval = try await store.migrationRequired()
                let present = try await store.contains()
                let retained = try await store.legacyRetained()
                try current(token)
                needsKeychainApproval = approval
                hasSavedSignIn = present
                legacyKeychainRetained = retained
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                self.error = Self.message(error)
            }
        }
    }

    func cancelKeychainApproval() async {
        guard approvingKeychain else { return }
        let old = operation
        generation = UUID()
        old?.cancel()
        await old?.value
        operation = nil
        busy = false
        approvingKeychain = false
        error = "Keychain approval didn't finish. Your saved sign-in is preserved. Check approval again before loading PC games."
    }

    func cancelSignIn() async {
        guard sheetPresented else { return }
        let old = operation
        generation = UUID()
        old?.cancel()
        sheetPresented = false
        deviceCode = nil
        await old?.value
        operation = nil
        busy = false
        error = nil
    }

    @discardableResult
    func beginAccountDisconnect() -> Bool {
        guard !busy, !restoringPresence, !accountDisconnecting, !terminating else { return false }
        accountDisconnecting = true
        generation = UUID()
        return true
    }

    func finishAccountDisconnect() { accountDisconnecting = false }

    @discardableResult
    func signOut() async -> Bool {
        guard !usesUnifiedAccount else {
            error = "Use Account to sign out of Xbox Live."
            return false
        }
        guard !terminating, !busy, !restoringPresence else { return false }
        let old = operation
        generation = UUID()
        old?.cancel()
        busy = true
        sheetPresented = false
        deviceCode = nil
        await old?.value
        operation = nil
        do {
            try await store.delete()
            hasSavedSignIn = false
            needsSignIn = false
            needsKeychainApproval = false
            legacyKeychainRetained = false
            snapshot = nil
            restored = true
            presenceUnavailable = false
            error = nil
        } catch { self.error = Self.message(error) }
        busy = false
        approvingKeychain = false
        return error == nil
    }

    func openVerification() {
        guard let code = deviceCode else { return }
        if !NSWorkspace.shared.open(code.verificationURL) {
            error = "Couldn't open your browser. Go to microsoft.com/link and enter the code."
        }
    }

    func beginTermination() {
        terminating = true
        generation = UUID()
        operation?.cancel()
        sheetPresented = false
        deviceCode = nil
        busy = false
        approvingKeychain = false
    }

    func resumeAfterTerminationRefusal() { terminating = false }

#if !XODUS_SHIPPING
    func loadReadOnlyLibraryPreview(broker: CredentialBrokerClient) async throws {
        guard !busy, !accountDisconnecting, !terminating else { throw PCGamesError.credentialBrokerUnavailable }
        busy = true
        defer { busy = false }
        let response = try await broker.send(CredentialRequest(operation: .read))
        guard !response.migrationRequired, let saved = response.value else {
            throw PCGamesError.keychainApprovalRequired
        }
        let tokens = try await client.refresh(saved)
        let result = try await client.library(accessToken: tokens.access, market: market, language: language)
        try Task.checkCancellation()
        snapshot = result
        hasSavedSignIn = true
        needsSignIn = false
        // The isolated review never persists refreshed credentials or changes Keychain access.
    }
#endif

    func waitForOperation() async { await operation?.value }

    private func current(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, !terminating else { throw CancellationError() }
    }

    private func finish(_ token: UUID) {
        guard generation == token else { return }
        busy = false
        approvingKeychain = false
        operation = nil
    }

    private static func message(_ error: Error) -> String {
        (error as? PCGamesError)?.localizedDescription ?? PCGamesError.transport.localizedDescription
    }

    static func installedMatch(_ game: PCGame, in installed: [InstalledGame]) -> InstalledGame? {
        installed.first { $0.storeId == game.id }
    }
}
