// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import XodusCredentials

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
    private let store: any PCGamesRefreshStore
    private let client: PCGamesClient
    private let market: String
    private let language: String
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var restored = false
    private var terminating = false
    private var attemptedAutomaticLoad = false

    var representedGames: [PCGame] { needsSignIn ? [] : snapshot?.games ?? [] }
    var accessIsCurrent: Bool {
        snapshot != nil && hasSavedSignIn && !needsSignIn && !busy && !restoringPresence
            && !presenceUnavailable && error == nil && !needsKeychainApproval
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
        guard !restored, !restoringPresence, !busy, !terminating else { return }
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
        guard !attemptedAutomaticLoad, !terminating else { return }
        await restorePresence()
        guard restored else { return }
        attemptedAutomaticLoad = true
        guard snapshot == nil, hasSavedSignIn, !needsKeychainApproval, !needsSignIn, !busy, error == nil else { return }
        refresh()
    }

    func retryLibraryLoad() async {
        guard !busy, !restoringPresence, !terminating else { return }
        restored = false
        await restorePresence()
        guard restored, hasSavedSignIn, !needsKeychainApproval, !needsSignIn else { return }
        refresh()
    }

    func signIn() {
        guard !busy, !restoringPresence, !presenceUnavailable, !needsKeychainApproval, !terminating else { return }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        deviceCode = nil
        snapshot = nil
        sheetPresented = true
        operation = Task {
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
                let result = try await client.library(accessToken: tokens.access, market: market, language: language)
                try current(token)
                snapshot = result
            } catch is CancellationError { }
            catch {
                guard generation == token, !terminating else { return }
                self.error = Self.message(error)
            }
        }
    }

    func refresh() {
        guard !busy, !restoringPresence, !presenceUnavailable, hasSavedSignIn,
              !needsSignIn, !needsKeychainApproval, !terminating else { return }
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
                                                      expectedAccountID: snapshot?.accountID)
                try current(token)
                snapshot = result
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

    func approveKeychain() {
        guard !busy, !restoringPresence, !presenceUnavailable, needsKeychainApproval, !terminating else { return }
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

    func signOut() async {
        guard !terminating else { return }
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
        guard !busy, !terminating else { throw PCGamesError.credentialBrokerUnavailable }
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
