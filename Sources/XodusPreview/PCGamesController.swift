// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import OSLog
import XodusCredentials
import XodusManagement

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
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")

    func useUnifiedAccount(_ session: LiveSession) {
        guard !busy, !restoringPresence else { return }
        unifiedSession = session
        usesUnifiedAccount = true
    }

    var representedGames: [PCGame] {
        guard !needsSignIn else { return [] }
        if usesUnifiedAccount {
            guard unifiedSession?.hasConfirmedSignIn == true,
                  accountHash == unifiedSession?.accountHash else { return [] }
        }
        return snapshot?.games ?? []
    }
    var accountHash: String? { snapshot?.boundAccountHash ?? snapshot?.accountID.flatMap(XboxAccountBinding.hash) }
    var resolutionNotice: String? {
        guard let snapshot, snapshot.unresolvedCount > 0 else { return nil }
        return "\(snapshot.unresolvedCount) game details haven't finished loading. PC availability is not established for unresolved games."
    }
    var accessIsCurrent: Bool {
        snapshot?.isComplete == true && hasSavedSignIn && !needsSignIn && !busy && !restoringPresence
            && !presenceUnavailable && error == nil && !needsKeychainApproval
            && (!usesUnifiedAccount || (unifiedSession?.hasConfirmedSignIn == true
                && accountHash == unifiedSession?.accountHash))
    }

    init(store: any PCGamesRefreshStore = PCGamesCredentialStore(), client: PCGamesClient = PCGamesClient(),
         market: String = PCGamesClient.market(Locale.current.region?.identifier),
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
              session.hasConfirmedSignIn else { return }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        operation = Task {
            defer { finish(token) }
            do {
                let read = try await session.readUnifiedAccount(.library, market: market, language: language)
                let collection = try read.payload.decode(OdeAccountCollection.self)
                try collection.validate()
                try current(token)
                logger.notice("Account collection candidates: \(collection.items.count)")
                let kinds = Dictionary(uniqueKeysWithValues: collection.items.map { ($0.productID, $0.acquisitionKind) })
                let result = try await client.resolveCollection(
                    ids: collection.items.map(\.productID), kinds: kinds,
                    candidateCount: collection.items.count, market: market, language: language,
                    accountHash: read.accountHash) { [weak self, weak session] partial in
                        guard let self, let session, self.generation == token,
                              !self.terminating, !self.accountDisconnecting,
                              session.hasConfirmedSignIn, session.accountHash == read.accountHash else { return }
                        self.snapshot = partial.retainingUnresolved(from: self.snapshot)
                    }
                try current(token)
                guard session.hasConfirmedSignIn, session.accountHash == read.accountHash else {
                    throw PCGamesError.identityMismatch
                }
                snapshot = result.retainingUnresolved(from: snapshot)
                logger.notice("Account PC resolution: \(result.games.count) games, \(result.excludedCount) excluded")
                hasSavedSignIn = true
                needsSignIn = false
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                if accountHash != session.accountHash || !session.hasConfirmedSignIn { snapshot = nil }
                if error as? ManagementError == .authenticatedReadFailed(.responseInvalid) {
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
        generation = UUID()
        let old = operation
        old?.cancel()
        snapshot = nil
        hasSavedSignIn = false
        restored = false
        attemptedAutomaticLoad = false
        lastAutomaticAttempt = nil
        needsSignIn = false
        error = nil
        await old?.value
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
