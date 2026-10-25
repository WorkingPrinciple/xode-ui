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

    var representedGames: [PCGame] {
        guard !needsSignIn else { return [] }
        if usesUnifiedAccount {
            guard unifiedSession?.hasConfirmedSignIn == true,
                  unifiedSession?.accountCountryReady == true,
                  snapshotScope == unifiedSession?.accountCatalogScope,
                  accountHash == unifiedSession?.accountHash else { return [] }
        }
        return snapshot?.games ?? []
    }
    var accountHash: String? { snapshot?.boundAccountHash ?? snapshot?.accountID.flatMap(XboxAccountBinding.hash) }
    var resolutionNotice: String? {
        guard !busy, let snapshot, snapshot.detailFailureCount > 0 else { return nil }
        return "Some game details are unavailable. Your available games are still here."
    }
    var retainedLibraryNotice: String? {
        guard error != nil, let snapshot else { return nil }
        return snapshot.isComplete ? "Showing the last complete library."
            : "Showing available details from an incomplete library."
    }
    var accessIsCurrent: Bool {
        snapshot?.isComplete == true && accountAccessIsCurrent
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
        refreshUnifiedAccount()
        await waitForLoad()
    }

    func retryLibraryLoad() async {
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
                // This task has not entered readUnifiedAccount yet, so accountBusy cannot include itself.
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while session.accountBusy {
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
                logger.notice("Account collection dispatch")
                let read = try await session.readUnifiedAccount(.library, market: market, language: language)
                let collection = try read.payload.decode(OdeAccountCollection.self)
                try collection.validate()
                try current(token)
                logger.notice("Account collection candidates: \(collection.items.count), purchased: \(collection.items.filter { $0.acquisitionKind == .purchased }.count), subscription: \(collection.items.filter { $0.acquisitionKind == .subscription }.count), unknown: \(collection.items.filter { $0.acquisitionKind == .unknown }.count)")
                let kinds = Dictionary(uniqueKeysWithValues: collection.items.map { ($0.productID, $0.acquisitionKind) })
                let result = try await client.resolveCollection(
                    ids: collection.items.map(\.productID), kinds: kinds,
                    candidateCount: collection.items.count, market: market, language: language,
                    accountHash: read.accountHash) { [weak self, weak session] partial in
                        guard let self, let session, self.generation == token,
                              !self.terminating, !self.accountDisconnecting,
                              session.hasConfirmedSignIn, session.accountHash == read.accountHash,
                              session.accountCatalogScope == scope else { return }
                        self.snapshot = partial.retainingUnresolved(from: self.snapshot)
                    }
                try current(token)
                guard session.hasConfirmedSignIn, session.accountHash == read.accountHash else {
                    throw PCGamesError.identityMismatch
                }
                guard session.accountCatalogScope == scope else { throw CancellationError() }
                snapshot = result.retainingUnresolved(from: snapshot)
                logger.notice("Account PC resolution: \(result.games.count) games, \(result.excludedCount) excluded, \(result.unresolvedCount) unresolved")
                hasSavedSignIn = true
                needsSignIn = false
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                if accountHash != session.accountHash || !session.hasConfirmedSignIn { snapshot = nil }
                if error as? PCGamesError == .libraryReadBusy {
                    self.error = PCGamesError.libraryReadBusy.localizedDescription
                } else if error as? ManagementError == .authenticatedReadFailed(.responseInvalid) {
                    self.error = "Your account library couldn't be read completely. Your installed games are still available."
                } else {
                    self.error = "Your PC library couldn't load. \(LiveSession.describe(error))"
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
        lastAutomaticAttempt = nil
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
