// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers
import XodusManagement

enum ConnectionPhase { case disconnected, connecting, disconnecting, ready, failed }
private enum AccountAction { case status, signIn, cancellation, signOut }

@MainActor
final class LiveSession: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .disconnected
    @Published private(set) var connectionTransitioning = false
    var applicationTerminating = false
    @Published private(set) var hello: ManagementHello?
    @Published private(set) var authentication: AuthenticationStatus?
    @Published private(set) var products: [CatalogProduct] = []
    @Published private(set) var activity = ActivityStore()
    @Published private(set) var searching = false
    @Published private var catalogRequestAppends = false
    @Published private(set) var catalogStopped = false
    @Published private var accountOperationBusy = false
    @Published private(set) var recentLibraryBootstrapRunning = false
    @Published private(set) var accountStatusChecking = false
    @Published private(set) var signingOut = false
    @Published private(set) var appSignOutComplete = false
    @Published private(set) var accountStatusCurrent = false
    @Published private(set) var nativeSignInHostAdmitted = false
    @Published private var connectionFailedAfterAdmission = false
    @Published private var managementStateLocked = false
    private var confirmedBeforeStatusRead = false
    @Published private(set) var accountError: String?
    @Published private(set) var accountStatusError: ManagementError?
    @Published private(set) var recentLibrary: RecentLibrarySnapshot?
    @Published private(set) var recentLibraryCurrent = false
    @Published private(set) var recentLibraryLoading = false
    @Published private(set) var recentLibraryError: String?
    @Published private(set) var lastSignInFailure: SignInFailureSnapshot?
    @Published private(set) var activityError: String?
    @Published private(set) var lookupBusy = false
    @Published private(set) var installedSnapshot: InstalledSnapshot?
    @Published private(set) var installedSnapshotCurrent = false
    @Published private(set) var installedRefreshing = false
    @Published private(set) var installedError: String?
    @Published private(set) var inspection: InstallationInspection?
    @Published private(set) var inspectionBusy = false
    @Published private(set) var inspectionError: String?
    @Published private(set) var nextCursor: String?
    @Published private(set) var catalogCorpus = "observedPublicProducts"
    @Published private(set) var discoveryFailures: [DiscoveryFailure] = []
    @Published private(set) var discoveryCheckedAt: String?
    @Published private(set) var gamePassProductIDs = Set<String>()
    // Browse records survive partial refreshes; cover badges require fresh observations.
    @Published private(set) var gamePassBadgeProductIDs = Set<String>()
    @Published private(set) var gamePassProducts: [CatalogProduct] = []
    @Published private(set) var gamePassCatalogLoading = false
    @Published private(set) var gamePassCatalogError: String?
    @Published private(set) var gamePassCatalogCheckedAt: String?
    @Published private(set) var gamePassCatalogPaging = false
    @Published private(set) var gamePassCatalogHasMore = false
    @Published private(set) var gamePassCatalogExhausted = false
    /// When the whole public PC Game Pass list was last loaded cleanly: every page from a fresh
    /// first page to the last had no failures and no error, within one revision. Cleared by any
    /// failure, error, retry of page one, new revision or scope change.
    @Published private(set) var gamePassCatalogCompletedAt: Date?
    private var gamePassPagesClean = false
    static let gamePassCatalogMaximumAge: TimeInterval = 60 * 60

    var gamePassLibraryNotice: String {
        if gamePassCatalogError != nil {
            return "Some PC Game Pass games couldn't load. Saved catalogue entries are retained; refresh to try again. Account and edition access is checked before installation."
        }
        if gamePassProducts.isEmpty {
            return "Load the PC Game Pass catalogue to browse available games. Your account and selected edition are checked before installation."
        }
        return gamePassCatalogHasMore
            ? "More PC Game Pass games are available to load. Catalogue membership is separate from your account's access."
            : "PC Game Pass catalogue. Availability varies by account, edition and region; access and Mac support are checked before installation."
    }
    @Published var selectedProduct: CatalogProduct?
    @Published var errorMessage: String?
    @Published var catalogError: String?
    @Published private(set) var catalogSourceFailure: CatalogQuery.SourceFailure?
    @Published private(set) var backendPath: String
    @Published var market = "US" { didSet { if market != oldValue { invalidateCatalogScope() } } }
    @Published var language = "en-US" { didSet { if language != oldValue { invalidateCatalogScope() } } }
    @Published private(set) var accountCountryChecking = false
    @Published private(set) var accountCountryVerified = false
    @Published private(set) var accountCountryNeedsConfirmation = false
    @Published private(set) var accountCountryError: String?
    private var countryAccountHash: String?
    private var countryCode: String?
    private var countryGeneration = UUID()
    private let countryDefaults: UserDefaults
    @Published var lookupID = ""
    @Published private(set) var diagnosticPreview: String?
    @Published private(set) var diagnosticPreviewing = false
    @Published private(set) var diagnosticSaving = false
    @Published private(set) var diagnosticSaved = false
    @Published private(set) var diagnosticExportError: String?
    private var descriptorMetricBaseline: (counts: ManagementClient.DescriptorMetricCounts, instant: ContinuousClock.Instant)?
    private(set) var descriptorMetricCounts: ManagementClient.DescriptorMetricCounts?
    private(set) var descriptorMetricIntervalCompleted = false
    private let descriptorMetricLogger = Logger(subsystem: "io.github.dragoshont.xodus", category: "descriptor-metrics")
    private var client: ManagementClient?
    private var descriptorsOwner: UUID?
    private var connectedConfiguration: BackendConfiguration?
    private var accountRuntime: OdeRuntimeProcess?
    private var runtimeGeneration = UUID()
    @Published private(set) var accountRuntimeReady = false
    @Published private(set) var accountRuntimeError: String?
    @Published private(set) var accountRuntimeStarting = false
    private var failedAccountAction: AccountAction?
    private var lifecycleRevision = 0
    private var connectOperationID: UUID?
    private var disconnectWaiters = 0
    private var closingOperation: ClosingOperation?
    private let shutdownClient: @Sendable (ManagementClient) async -> Bool
    private var eventTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var generation = 0
    private var queryGeneration = 0
    private var authenticationGeneration = 0
    private var recentLibraryGeneration = 0
    private var recentLibraryEntryGeneration: Int?
    private var recentLibraryBootstrap: RecentLibraryBootstrap?
    private let recentLibraryLogger = Logger(subsystem: "io.github.dragoshont.xodus", category: "recent-library")
    private var currentQuery = ""
    private var cacheRevision: UInt64?
    private var discoveryRevision: String?
    private var gamePassRevision: String?
    private var gamePassPagingID: UUID?
    private let configuration: BackendConfiguration?
    private let signInPollingBudget: Duration
    private var signInDeadline: ContinuousClock.Instant?
    private let signInOwner = UUID()
    private var catalogTask: Task<Void, Never>?
    private var catalogWorkerID: UUID?
    private var queuedCatalog: CatalogRequest?
    private var queryResults = CatalogQueryResultCache()

    struct SignInFailureSnapshot: Equatable {
        enum Code: String {
            case invalid = "AUTH_INVALID", cancelled = "AUTH_CANCELLED"
            case expired = "AUTH_EXPIRED", networkUnavailable = "NETWORK_UNAVAILABLE"
        }

        let code: Code?
        let diagnostic: NativeConsentFailure?
        let observation: String?

        init(_ failure: WireFailure?) {
            code = failure.flatMap { Code(rawValue: $0.code) }
            diagnostic = failure?.nativeConsentFailure
            observation = failure.flatMap(LiveSession.validatedNativeSignInObservation)
        }

        init(requestError: Error) {
            if case let ManagementError.backendError(value, _) = requestError {
                code = Code(rawValue: value)
            } else { code = nil }
            diagnostic = nil
            observation = nil
        }
    }

    private struct CatalogRequest {
        let command: ManagementCommand
        let query: String
        let market: String
        let language: String
        let cursor: String?
        let more: Bool
        let generation: Int
        let queryGeneration: Int
    }

    struct CatalogQuerySnapshot {
        let products: [CatalogProduct]
        let failures: [DiscoveryFailure]
        let nextCursor: String?
        let sourceFailure: CatalogQuery.SourceFailure?
        let checkedAt: String?
        let corpus: String
        let storedAt: ContinuousClock.Instant
    }

    /// Bounded, scope-keyed results of completed public store queries so a repeated query
    /// publishes immediately instead of waiting behind the single producer slot again.
    struct CatalogQueryResultCache {
        static let capacity = 24
        static let lifetime = Duration.seconds(600)
        private var entries: [String: CatalogQuerySnapshot] = [:]
        private var order: [String] = []

        static func key(account: String?, market: String, language: String, query: String) -> String {
            "\(account ?? ""):\(market):\(language):\(query)"
        }

        func fresh(_ key: String, now: ContinuousClock.Instant = .now) -> CatalogQuerySnapshot? {
            guard let entry = entries[key], now - entry.storedAt < Self.lifetime else { return nil }
            return entry
        }

        mutating func store(_ snapshot: CatalogQuerySnapshot, for key: String) {
            entries[key] = snapshot
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }

        mutating func removeAll() {
            entries = [:]
            order = []
        }

        var count: Int { entries.count }
    }

    private struct ClosingOperation {
        let id: UUID
        let client: ManagementClient
        let task: Task<Bool, Never>
    }

    private struct RecentLibraryBootstrap {
        let id: UUID
        let task: Task<Void, Never>
    }

    init(configuration: BackendConfiguration? = nil,
         signInPollingBudget: Duration = .seconds(600),
         countryDefaults: UserDefaults = .standard,
         shutdownClient: @escaping @Sendable (ManagementClient) async -> Bool = { await $0.close() }) {
        self.countryDefaults = countryDefaults
        self.shutdownClient = shutdownClient
        self.signInPollingBudget = signInPollingBudget
#if XODUS_SHIPPING
        self.configuration = nil
        backendPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/XodusEngine/xodus-cli").path
        let scope = CatalogLocale.preferred(region: nil, languages: Locale.preferredLanguages)
        market = ""
        language = scope.language
        if ShippingPairPins.approved == nil {
            errorMessage = ManagementError.pairedEngineUnavailable.localizedDescription
        }
        return
#else
        self.configuration = configuration
        if let configuration {
            backendPath = configuration.executable.path
            return
        }
        let embedded = Bundle.main.resourceURL?.appendingPathComponent("XodusEngine/xodus-cli")
        let bundledPath = embedded.flatMap {
            FileManager.default.isExecutableFile(atPath: $0.path) ? $0.path : nil
        }
        if let override = ProcessInfo.processInfo.environment["XODUS_BACKEND_PATH"], !override.isEmpty {
            backendPath = override
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            backendPath = bundledPath ?? ""
            if bundledPath == nil {
                errorMessage = "This app's included engine is missing or not executable. Rebuild or reinstall the matching development app; Advanced Settings can explicitly select a trusted development engine."
            }
        } else {
            backendPath = bundledPath ?? UserDefaults.standard.string(forKey: "Xodus.developerBackendPath") ?? ""
        }
        let scope = CatalogLocale.preferred(region: nil, languages: Locale.preferredLanguages)
        market = ""
        language = scope.language
#endif
    }

    var isReady: Bool { phase == .ready }
    var accountCountryReady: Bool {
        hasConfirmedSignIn && countryAccountHash == accountHash && countryCode == market && !market.isEmpty
    }
    var accountCatalogScope: String {
        "\(accountHash ?? ""):\(accountCountryReady):\(market):\(language)"
    }
    var accountCountryLabel: String {
        guard accountCountryReady else {
            return accountCountryChecking ? "Checking Xbox account" : "Not confirmed"
        }
        let name = Locale.current.localizedString(forRegionCode: market) ?? market
        return "\(name) (\(market)) — \(Self.countrySource(verified: accountCountryVerified, provisional: accountCountryProvisional))"
    }
    static func countrySource(verified: Bool, provisional: Bool) -> String {
        verified ? "verified by Xbox" : provisional ? "last confirmed by Xbox" : "confirmed by you"
    }

    func refreshAccountCountry() async {
        guard hasConfirmedSignIn, !accountCountryChecking, let account = accountHash else { return }
        let token = countryGeneration
        accountCountryChecking = true
        defer { if token == countryGeneration { accountCountryChecking = false } }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while accountBusy {
                try Task.checkCancellation()
                guard token == countryGeneration, accountHash == account else { return }
                guard ContinuousClock.now < deadline else { throw ManagementError.disconnected }
                try await Task.sleep(for: .milliseconds(50))
            }
            _ = try await readUnifiedAccount(.profile)
        } catch is CancellationError { }
        catch {
            guard token == countryGeneration, accountHash == account else { return }
            accountCountryError = "Xbox account country couldn't be checked. \(Self.describe(error))"
        }
    }

    /// REQ-121: the last Xbox-verified country for an account, as a bare country code keyed by the
    /// account hash. Applied provisionally at launch so artwork draws at once; re-confirmed in the
    /// background; removed on sign-out.
    static func lastVerifiedCountryKey(_ account: String) -> String { "Xodus.accountCountry.lastVerified.\(account)" }
    @Published private(set) var accountCountryProvisional = false
    /// d270a2c5: the Mac-level Microsoft read gate; it outlives management connections.
    let readGate = MicrosoftReadGate()
    /// REQ-121: after a confirmed sign-out, saved artwork and saved public descriptors (whose product IDs
    /// reflect the library and whose market reflects the country) are removed. Injectable for checks.
    var signOutCleanup: @MainActor () async -> Void = {
        LibrarySnapshotStore.production?.clear()
        try? await CatalogArtworkStore.shared.clearForSignOut()
    }

    /// Uses the last verified country for this account until the profile read confirms it.
    func applyProvisionalAccountCountry() {
        guard hasConfirmedSignIn, let account = accountHash, countryAccountHash != account,
              let code = countryDefaults.string(forKey: Self.lastVerifiedCountryKey(account))
                .flatMap(XboxAccountCountry.normalized) else { return }
        countryAccountHash = account
        countryCode = code
        market = code
        accountCountryVerified = false
        accountCountryNeedsConfirmation = false
        accountCountryError = nil
        accountCountryProvisional = true
        let token = countryGeneration
        MicrosoftReadContext.automatic { Task { [weak self] in
            // Behind the library read; a different country re-scopes and refetches the library.
            guard let self, token == self.countryGeneration else { return }
            for _ in 0..<300 where self.yieldsToLibraryRead || self.accountBusy {
                try? await Task.sleep(for: .milliseconds(100))
                guard token == self.countryGeneration else { return }
            }
            // d270a2c5: both automatic re-checks wait for the gate.
            if self.readGate.allowsAutomaticRead(account: self.accountHash) { await self.refreshAccountCountry() }
            // One later retry if the re-check failed and the country is still provisional.
            guard token == self.countryGeneration, self.accountCountryProvisional else { return }
            try? await Task.sleep(for: .seconds(self.provisionalCountryRetryDelay))
            guard token == self.countryGeneration, self.accountCountryProvisional, !self.accountBusy,
                  self.readGate.allowsAutomaticRead(account: self.accountHash) else { return }
            await self.refreshAccountCountry()
        } }
    }
    static let provisionalCountryRetry: TimeInterval = 60
    /// Injectable for checks.
    var provisionalCountryRetryDelay: TimeInterval = LiveSession.provisionalCountryRetry

    /// Forgets the saved countries for an account; part of signing out.
    func forgetAccountCountry(_ account: String) {
        countryDefaults.removeObject(forKey: Self.lastVerifiedCountryKey(account))
        countryDefaults.removeObject(forKey: "Xodus.accountCountry.\(account)")
    }

    func applyAccountCountry(_ value: XboxAccountCountry?, account: String) {
        guard hasConfirmedSignIn, accountHash == account else { return }
        accountCountryProvisional = false
        if let verified = value?.countryCode.flatMap(XboxAccountCountry.normalized) {
            countryDefaults.set(verified, forKey: Self.lastVerifiedCountryKey(account))
        }
        countryAccountHash = account
        accountCountryVerified = value?.countryCode != nil
        accountCountryNeedsConfirmation = !accountCountryVerified
        accountCountryError = accountCountryVerified ? nil : "Xbox hasn't confirmed an account country."
        let saved = countryDefaults.string(forKey: "Xodus.accountCountry.\(account)")
        countryCode = value?.countryCode ?? saved.flatMap(XboxAccountCountry.normalized)
        market = countryCode ?? ""
    }

    func confirmAccountCountry(_ code: String) {
        guard hasConfirmedSignIn, accountCountryNeedsConfirmation,
              let account = accountHash, let code = XboxAccountCountry.normalized(code),
              Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else { return }
        countryDefaults.set(code, forKey: "Xodus.accountCountry.\(account)")
        countryAccountHash = account
        countryCode = code
        market = code
    }

    private func retireAccountCountry() {
        countryGeneration = UUID()
        accountCountryProvisional = false
        countryAccountHash = nil
        countryCode = nil
        accountCountryChecking = false
        accountCountryVerified = false
        accountCountryNeedsConfirmation = false
        accountCountryError = nil
        market = ""
    }
    private var licenseReadGeneration: Int?
    private var licenseReadInFlight: Bool { licenseReadGeneration == generation }
    private var waitingInteractiveAccountReads = 0
    /// The first status read on this connection finished, successfully or not.
    @Published private(set) var initialStatusSettled = false
    @Published private(set) var unverifiedCredentialSince: Date?
    /// Set when a launch connect will read the saved sign-in; a plain reconnect never enters restoring.
    @Published private(set) var restoreExpectedSince: Date?
    @Published private var restoreTick = 0
    private var restoreRereadDone = false
    /// REQ-119: a library collection read waiting to dispatch. License and recent-activity reads hold
    /// back for it, so the cold library isn't queued behind background reads.
    @Published private(set) var libraryReadsWaiting = 0
    var yieldsToLibraryRead: Bool { libraryReadsWaiting > 0 }
    func beginLibraryReadPriority() { libraryReadsWaiting += 1 }
    func endLibraryReadPriority() { libraryReadsWaiting = max(0, libraryReadsWaiting - 1) }
    /// Names of what makes `accountBusy` true, for load-latency logs.
    var accountBusyReasons: [String] {
        var reasons: [String] = []
        if accountOperationBusy { reasons.append(accountStatusChecking ? "statusRead" : "accountRead") }
        if recentLibraryBootstrapRunning { reasons.append("recentLibrary") }
        if accountRuntimeStarting { reasons.append("runtimePrepare") }
        if waitingInteractiveAccountReads > 0 { reasons.append("interactiveRead") }
        return reasons
    }
    var accountBusy: Bool {
        accountOperationBusy || recentLibraryBootstrapRunning || accountRuntimeStarting
            || waitingInteractiveAccountReads > 0
    }
    var signInPending: Bool { authentication?.flow?.state == .pending }
    var canSignIn: Bool {
        isReady && supports(.authBegin) && supports(.authCancel) && supports(.authStatus)
            && accountStatusCurrent && authentication?.state == .signedOut && !accountBusy && !signInPending
    }
    var hasConfirmedSignIn: Bool {
        isReady && !signInPending && authentication?.state == .credentialPresent
            && authentication?.accountHash.map(XboxAccountBinding.valid) == true
            && (accountStatusCurrent || (accountStatusChecking && confirmedBeforeStatusRead))
    }
    var accountHash: String? {
        authentication?.accountHash.flatMap { XboxAccountBinding.valid($0) ? $0 : nil }
    }
    var nativeLifecycleConfiguration: BackendConfiguration? {
        guard hasConfirmedSignIn, !connectionTransitioning, !signingOut, !applicationTerminating,
              supports(.odeAccountRead), let configuration = connectedConfiguration,
              configuration.executableIdentity?.sha256 == NativeLifecyclePins.cliSHA256,
              configuration.executableIdentity?.executable == configuration.executable else { return nil }
        return configuration
    }
    var nativeInstallStatusConfiguration: BackendConfiguration? {
        guard !applicationTerminating, let configuration = connectedConfiguration,
              configuration.executableIdentity?.sha256 == NativeLifecyclePins.cliSHA256,
              configuration.executableIdentity?.executable == configuration.executable else { return nil }
        return configuration
    }
    var canStartWelcomeSignIn: Bool { nativeSignInHostAdmitted && canSignIn }
    var accountJourneyTitle: String {
        if signingOut { return "Signing out of \(AppBrand.displayName)" }
        if connectionTransitioning || accountStatusChecking { return "Checking your sign-in" }
        if signInPending { return "Finish signing in" }
        if accountError != nil { return "Your account needs attention" }
        if hasConfirmedSignIn { return "Signed in with Xbox Live" }
        if currentCredentialState == .signedOut {
            return appSignOutComplete ? "Signed out of Xbox Live" : "Not signed in to Xbox Live"
        }
        if needsAccountDisconnect { return "Sign-in needs reconnecting" }
        return "Sign-in hasn't been checked"
    }
    var accountJourneyMessage: String {
        if signingOut { return "Removing \(AppBrand.displayName)'s saved sign-ins from this Mac. Please wait." }
        if connectionTransitioning || accountStatusChecking { return "Checking whether your Microsoft sign-in is saved." }
        if failedAccountAction == .signOut, accountError != nil {
            return "Sign-out didn't finish. Some Xbox Live details may remain on this Mac. Choose Sign in with Microsoft to try again."
        }
        if !isReady {
            return welcomeMessage
        }
        if signInPending { return "Continue in the Microsoft window, or choose Cancel sign-in." }
        if accountError != nil {
            return accountStatusError == .credentialStoreUnavailable
                ? "Your saved Xbox Live sign-in couldn't be read. Respond to the macOS Keychain prompt, then sign in again."
                : "Your Xbox Live sign-in couldn't be confirmed. Choose Sign in with Microsoft to try again."
        }
        if hasConfirmedSignIn {
            return "Your Xbox Live sign-in is saved."
        }
        if needsAccountDisconnect {
            return "Your saved Xbox Live sign-in needs to be refreshed. Choose Sign in with Microsoft."
        }
        if appSignOutComplete, currentCredentialState == .signedOut {
            return "You're signed out of Xbox Live on this Mac. Your installed games and saves remain."
        }
        if canStartWelcomeSignIn {
            return "Sign in with your Microsoft account to see your games."
        }
        return "Choose Sign in with Microsoft to check your saved sign-in or connect your account."
    }
    static let signOutConfirmationMessage = "Remove this Xbox account from \(AppBrand.displayName) on this Mac? Your games, saves, other apps and Microsoft browser sessions stay unchanged. If sign-out doesn't finish, \(AppBrand.displayName) will tell you which step failed."
    var welcomeNotice: String? {
        if signingOut || connectionTransitioning || accountStatusChecking || managementStateLocked
            || connectionFailedAfterAdmission
            || !isReady || !nativeSignInHostAdmitted || !supports(.authBegin)
            || !supports(.authCancel) || !supports(.authStatus) || signInPending
            || accountError != nil || needsAccountDisconnect || restoringSignIn
            || authentication?.flow?.state == .failed || authentication?.flow?.state == .cancelled
            || (appSignOutComplete && authentication?.state == .signedOut && accountStatusCurrent) {
            return welcomeMessage
        }
        return nil
    }
    var welcomeMessage: String {
        if signingOut { return "Signing out of \(AppBrand.displayName). Waiting for saved sign-in removal to finish." }
        if failedAccountAction == .signOut, let accountError { return accountError }
        if connectionTransitioning || accountStatusChecking { return "Checking your sign-in…" }
        if managementStateLocked { return ManagementError.stateLocked.localizedDescription }
        if connectionFailedAfterAdmission {
            return "\(AppBrand.displayName) couldn't connect to its sign-in service. Choose Sign in with Microsoft to reconnect."
        }
        guard isReady, nativeSignInHostAdmitted, supports(.authBegin),
              supports(.authCancel), supports(.authStatus) else {
            return "Sign-in is unavailable in this copy of \(AppBrand.displayName). A matching app and sign-in service are required."
        }
        if signInPending { return "Finish signing in in Microsoft's window, or cancel to try later." }
        if accountError != nil {
            return "Your sign-in couldn't be confirmed. Try again. If macOS asks for Keychain access, respond in its permission window."
        }
        if restoringSignIn { return WelcomeCopy.restoring }
        if needsAccountDisconnect { return "Your saved sign-in needs to be reconnected." }
        if authentication?.flow?.state == .failed { return "Sign-in didn't finish. Try again when you're ready." }
        if authentication?.flow?.state == .cancelled { return "Sign-in was cancelled. Your games stay hidden until you sign in." }
        if authentication?.state == .signedOut, accountStatusCurrent {
            return appSignOutComplete
                ? "You're signed out of Xbox Live on this Mac. Sign in when you're ready. Other apps and Microsoft browser sessions weren't changed."
                : "Xbox Live sign-out hasn't been confirmed. Sign in again when you're ready."
        }
        if supports(.odeAccountRead) { return "Use your Microsoft account for your PC library and Xbox profile." }
        return "This signs you in to \(AppBrand.displayName). Game downloads and Xbox features may ask for a separate Microsoft sign-in when you use them."
    }

    func prepareWelcome() async {
        guard !connectionTransitioning, !accountBusy, !signInPending else { return }
        if !isReady {
            await connect(readingAccountFirst: true)
            if isReady, initialStatusSettled { return }
        }
        if isReady { await refreshAccount() }
    }
    func revalidateAccountOnForeground() async {
        guard isReady, !connectionTransitioning, !accountBusy, !signInPending else { return }
        await refreshAccount()
    }
    /// REQ-121: the scene-activation caller skips the re-read when the saved sign-in was read moments ago (at
    /// launch), so that duplicate can't hold the account channel ahead of the collection read. Explicit callers
    /// of revalidateAccountOnForeground always read.
    static let foregroundRevalidationInterval: TimeInterval = 30
    static func foregroundRevalidationDue(lastStatusRead: Date?, now: Date) -> Bool {
        guard let lastStatusRead else { return true }
        let age = now.timeIntervalSince(lastStatusRead)
        return age < 0 || age >= foregroundRevalidationInterval
    }
    private(set) var accountStatusReadAt: Date?
    var accountNoticeTitle: String {
        if accountStatusChecking { return "Checking saved sign-in" }
        guard isReady, accountStatusCurrent else { return accountLabel }
        if authentication?.flow?.state == .failed { return "Sign-in failed" }
        if authentication?.flow?.state == .cancelled { return "Sign-in cancelled" }
        return accountLabel
    }
    var accountMessage: String {
        if phase == .connecting { return "Connecting to \(AppBrand.displayName)." }
        guard isReady else { return "\(AppBrand.displayName) couldn't connect. Open Settings to reconnect." }
        if accountStatusChecking {
            return "If macOS asks for Keychain access, respond in its permission window. Your saved sign-in is not being replaced."
        }
        if accountError != nil {
            if failedAccountAction == .status && accountStatusError == .credentialStoreUnavailable {
                return "Your saved sign-in couldn't be checked because \(AppBrand.displayName) cannot access Keychain. Sign-in stays disabled until access is confirmed. After resolving Keychain access, choose Check status."
            }
            switch failedAccountAction {
            case .status: return "Account status couldn't be checked. Choose Check status to try again."
            case .signIn: return "Sign-in couldn't be confirmed. Check status before trying again."
            case .cancellation: return "Cancellation couldn't be confirmed. Check status before trying again."
            case .signOut: return "Sign-out couldn't be confirmed. Check status before trying again."
            case nil: return "The account action couldn't be confirmed. Check status before trying again."
            }
        }
        if signInPending {
            return accountStatusCurrent
                ? "Continue in Microsoft's window if it opened, or cancel sign-in."
                : "Sign-in's current result is unknown. Check status before trying again."
        }
        guard accountStatusCurrent else { return "Check status to see whether you're signed in." }
        if authentication?.flow?.state == .failed {
            return "This sign-in didn't finish. Check Account info or try again when you're ready. You can still browse games."
        }
        if authentication?.flow?.state == .cancelled { return "You can sign in whenever you're ready." }
        switch currentCredentialState {
        case .credentialPresent: return supports(.libraryRecent)
            ? "Your saved sign-in is available."
            : "Your game library isn't available yet."
        case .expired, .invalid: return "Disconnect this sign-in, then sign in again."
        case .signedOut: return "You are signed out of Xbox in \(AppBrand.displayName). Sign in with your Microsoft account to see your games."
        case nil: return "Check status to see whether you're signed in."
        }
    }
    var libraryTitle: String {
        "Your PC library isn't available yet"
    }
    var libraryMessage: String {
        "\(AppBrand.displayName) can't yet verify which PC games you own."
    }
    var canRefreshRecentLibrary: Bool {
        recentLibraryReadAllowed && !recentLibraryBootstrapRunning
    }
    private var recentLibraryReadAllowed: Bool {
        isReady && supports(.libraryRecent) && accountStatusCurrent
            && currentCredentialState == .credentialPresent && !signInPending && !accountOperationBusy
            && !recentLibraryLoading
    }
    var canLoadRecentLibrary: Bool {
        isReady && !connectionTransitioning && supports(.libraryRecent)
            && (accountStatusCurrent || supports(.authStatus))
            && (!accountStatusCurrent || currentCredentialState == .credentialPresent)
            && !signInPending && !accountBusy && !recentLibraryLoading && !yieldsToLibraryRead
    }
    var recentLibraryLoadingTitle: String {
        accountStatusChecking || (recentLibraryBootstrapRunning && !accountStatusCurrent)
            ? "Checking saved sign-in" : "Loading recently played"
    }
    var recentLibraryMessage: String {
        if let error = recentLibraryError ?? accountError { return error }
        if accountStatusChecking || (recentLibraryBootstrapRunning && !accountStatusCurrent) {
            return "Respond in macOS's Keychain permission window if it appears."
        }
        if recentLibraryLoading || recentLibraryBootstrapRunning { return "Getting your recent activity from Microsoft." }
        guard accountStatusCurrent else { return "Your saved sign-in hasn't been confirmed. Try loading again." }
        switch currentCredentialState {
        case .credentialPresent: return "Load your recent activity from Microsoft."
        case .signedOut: return "Sign in with Microsoft in Account to see recently played games."
        case .expired: return "Your saved Microsoft sign-in has expired. Open Account to review it."
        case .invalid: return "Your saved Microsoft sign-in couldn't be validated. Open Account to review it."
        case nil: return "Open Account to check your saved Microsoft sign-in."
        }
    }
    var recentLibraryNotice: String? {
        if let error = recentLibraryError {
            return recentLibrary == nil ? error : error + " Showing previously checked activity."
        }
        if recentLibrary != nil, !recentLibraryCurrent {
            return recentLibraryLoading ? "Showing previously checked activity while updating."
                : "Previously checked activity. Refresh for the latest result."
        }
        return nil
    }

    func refreshRecentLibrary() async {
        guard !recentLibraryBootstrapRunning else { return }
        await readRecentLibrary()
    }

    func loadRecentLibraryOnEntry() async {
        await loadRecentLibrary(automatically: true)
    }

    func reloadRecentLibrary() async {
        await MicrosoftReadContext.explicit { await loadRecentLibrary(automatically: false) }
    }

    private func loadRecentLibrary(automatically: Bool) async {
        if let operation = recentLibraryBootstrap {
            await operation.task.value
            return
        }
        // REQ-119: queued, not skipped, while the library's collection read goes first.
        let generationAtEntry = generation
        for _ in 0..<300 where yieldsToLibraryRead {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard generation == generationAtEntry else { return }
        }
        guard !applicationTerminating, canLoadRecentLibrary,
              !automatically || recentLibraryEntryGeneration != generation else { return }
        // d270a2c5: an automatic entry read waits for the gate; the entry stays unread so it loads afterwards.
        if automatically, !readGate.allowsAutomaticRead(account: accountHash) { return }
        let token = generation
        let id = UUID()
        recentLibraryEntryGeneration = token
        recentLibraryBootstrapRunning = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recentLibraryBootstrap?.id == id {
                    self.recentLibraryBootstrap = nil
                    self.recentLibraryBootstrapRunning = false
                }
            }
            if !self.accountStatusCurrent { await self.refreshAccountState() }
            guard !Task.isCancelled, token == self.generation, self.isReady,
                  !self.connectionTransitioning, !self.applicationTerminating,
                  self.accountStatusCurrent, self.currentCredentialState == .credentialPresent,
                  !self.signInPending else { return }
            await self.readRecentLibrary()
        }
        recentLibraryBootstrap = RecentLibraryBootstrap(id: id, task: task)
        await task.value
    }

    private func readRecentLibrary() async {
        guard recentLibraryReadAllowed, let client else { return }
        if let account = accountHash {
            do { try readGate.admit(account: account) } catch {
                recentLibraryError = Self.describe(error)
                return
            }
        }
        let gateAccount = accountHash
        let token = generation
        let authToken = authenticationGeneration
        recentLibraryGeneration += 1
        let recentToken = recentLibraryGeneration
        recentLibraryLoading = true
        recentLibraryCurrent = false
        recentLibraryError = nil
        accountOperationBusy = true
        defer {
            if token == generation, recentToken == recentLibraryGeneration {
                recentLibraryLoading = false
                accountOperationBusy = false
            }
        }
        do {
            let result: RecentLibrarySnapshot
            do {
                result = try await client.request(.libraryRecent, params: ["limit": .integer(20)])
                    .decode(RecentLibrarySnapshot.self)
                if let gateAccount { readGate.recordSuccess(account: gateAccount) }
            } catch {
                if let gateAccount { readGate.record(error, account: gateAccount) }
                throw error
            }
            guard token == generation, authToken == authenticationGeneration,
                  recentToken == recentLibraryGeneration else { return }
            try result.validate(limit: 20)
            recentLibrary = result
            recentLibraryCurrent = true
            recentLibraryLogger.notice("stage=recentlyPlayed count=\(result.titles.count, privacy: .public)")
        } catch {
            guard token == generation, authToken == authenticationGeneration,
                  recentToken == recentLibraryGeneration else { return }
            if case let ManagementError.recentLibraryFailed(stage) = error {
                if [.credentialUnavailable, .profileChanged, .authRejected].contains(stage) {
                    recentLibrary = nil
                    accountStatusCurrent = false
                }
                switch stage {
                case .credentialUnavailable:
                    recentLibraryError = "Saved sign-in couldn't be read for recent activity. Try loading again or review Account."
                case .profileChanged:
                    recentLibraryError = "The account changed while recent activity was checked. Try loading again."
                case .authRejected:
                    recentLibraryError = "Microsoft rejected access to recent activity. Review your saved sign-in in Account."
                case .authExchangeFailed:
                    recentLibraryError = LiveSession.signInRejectedMessage
                case .transportFailed:
                    recentLibraryError = "Recent activity couldn't connect. Try again."
                case .responseInvalid:
                    recentLibraryError = "Microsoft's recent activity couldn't be read safely. No empty result was assumed."
                case .throttled:
                    recentLibraryError = Self.throttledMessage(retryAfterSeconds: nil)
                }
            } else if case let ManagementError.recentLibraryThrottled(seconds) = error {
                // bc33adf2 B-new: rate-limited history keeps the connection and says when to try again.
                recentLibraryError = Self.throttledMessage(retryAfterSeconds: seconds)
            } else { recentLibraryError = Self.describe(error) }
        }
    }

    private func clearRecentLibrary() {
        recentLibraryGeneration += 1
        recentLibrary = nil
        recentLibraryCurrent = false
        recentLibraryError = nil
        recentLibraryLoading = false
    }
    var activityNotice: String? {
        guard activityError != nil else { return nil }
        return "Activity couldn't be updated. Choose Refresh activity to check the latest result."
    }
    func productSummary(_ product: CatalogProduct) -> String {
        guard !product.editions.isEmpty else { return "Game information hasn't been resolved." }
        let access = Set(product.editions.map(\.entitlement.kind))
        let compatibility = Set(product.editions.map(\.compatibility.kind))
        if access == [.unknown] && compatibility == [.unknown] {
            return "Catalog metadata doesn't verify access or Mac compatibility. Use Library or Discover for Install and Play."
        }
        let accessLabel = access.count == 1 ? product.editions[0].entitlement.kind.label : "Varies by edition"
        let compatibilityLabel = compatibility.count == 1 ? product.editions[0].compatibility.kind.label : "Varies by edition"
        return "Catalog access: \(accessLabel). Catalog Mac compatibility: \(compatibilityLabel). Use Library or Discover for Install and Play."
    }
    var catalogNotice: String? {
        if catalogStopped { return "Search stopped." }
        if catalogError != nil { return "Games couldn't be loaded. Choose Refresh to try again." }
        if !discoveryFailures.isEmpty { return "Some results couldn't be checked." }
        return nil
    }
    var catalogTitle: String {
        catalogCorpus == "publicMicrosoftStoreSearch" ? "Search results"
            : catalogCorpus == "pcGamePassDiscovery" ? "Explore PC games" : "PC games"
    }
    func catalogMessage(query: String, canRefresh: Bool) -> String {
        if searching { return "Looking for games. Results aren't ready yet." }
        if !isReady { return "Reconnect in Settings to browse games." }
        if !canRefresh { return "This catalog isn't available in this build." }
        if catalogStopped { return "Start a new search when you're ready." }
        if catalogError != nil || !discoveryFailures.isEmpty || catalogSourceFailure != nil {
            return "Try another search or refresh the results."
        }
        if query.isEmpty { return "Find your next game with Discover or search." }
        return "Try a different title or a shorter search."
    }
    /// REQ-119: a stored sign-in is still being restored — the launch's first status read hasn't
    /// settled, or the saved credential's identity isn't verified yet. Neutral, never "reconnect".
    static let restoreGrace: TimeInterval = 15
    /// Bounded: an expected first read that hasn't settled, or an unverified credential, for at most
    /// `restoreGrace`. A plain reconnect that reads nothing is never "restoring".
    static func signInRestoring(statusSettled: Bool, restoreExpected: Bool, restoringFor: TimeInterval?,
                                state: CredentialState?, hashValid: Bool, unverifiedFor: TimeInterval?) -> Bool {
        guard statusSettled else { return restoreExpected && (restoringFor ?? 0) < restoreGrace }
        return state == .credentialPresent && !hashValid && (unverifiedFor ?? 0) < restoreGrace
    }
    /// At the end of the wait, read status once more before showing reconnect copy.
    static func rereadsStatusAtGrace(state: CredentialState?, hashValid: Bool, alreadyReread: Bool) -> Bool {
        state == .credentialPresent && !hashValid && !alreadyReread
    }
    var restoringSignIn: Bool {
        guard isReady, supports(.authStatus), !signInPending, !signingOut, accountError == nil,
              !hasConfirmedSignIn else { return false }
        _ = restoreTick
        return Self.signInRestoring(statusSettled: initialStatusSettled, restoreExpected: restoreExpectedSince != nil,
            restoringFor: restoreExpectedSince.map { Date().timeIntervalSince($0) },
            state: authentication?.state,
            hashValid: authentication?.accountHash.map(XboxAccountBinding.valid) == true,
            unverifiedFor: unverifiedCredentialSince.map { Date().timeIntervalSince($0) })
    }
    private func scheduleRestoreBound() {
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restoreGrace))
            guard let self, token == self.generation else { return }
            if Self.rereadsStatusAtGrace(state: self.authentication?.state,
                    hashValid: self.authentication?.accountHash.map(XboxAccountBinding.valid) == true,
                    alreadyReread: self.restoreRereadDone), !self.accountBusy, !self.signInPending {
                self.restoreRereadDone = true
                await self.refreshAccount()
            }
            guard token == self.generation else { return }
            self.restoreTick &+= 1
        }
    }
    var needsAccountDisconnect: Bool {
        guard let state = authentication?.state else { return false }
        return [.credentialPresent, .expired, .invalid].contains(state)
    }
    var canDisconnectAccount: Bool {
        isReady && accountStatusCurrent && !accountBusy && !signInPending
            && (authentication?.state == .signedOut || (supports(.authLogout) && needsAccountDisconnect))
    }
    var catalogAtLimit: Bool { Set(products.map(\.id) + discoveryFailures.map(\.id)).count >= 512 }
    var catalogHasQueryWarning: Bool {
        catalogSourceFailure != nil || discoveryFailures.contains {
            $0.error.code != "PACKAGE_UNAVAILABLE" || $0.error.retryable
        }
    }
    var catalogCanRetryQueryWarning: Bool {
        catalogSourceFailure?.retryable == true || discoveryFailures.contains(where: \.error.retryable)
    }
    var catalogRequestVersion: Int { queryGeneration }
    var canLoadMoreCatalog: Bool { nextCursor != nil && !searching && !catalogAtLimit }
    var catalogEmptyTitle: String {
        if searching { return "Finding games" }
        if catalogStopped { return "Search stopped" }
        if catalogCorpus == "publicMicrosoftStoreSearch", catalogError == nil,
           discoveryFailures.isEmpty, catalogSourceFailure == nil, discoveryCheckedAt != nil { return "No Store matches" }
        return "No games to show"
    }
    func catalogEmptyExplanation(query: String, canRefresh: Bool) -> String {
        if searching { return "Checking public products in this scope. Results are not available yet." }
        if !isReady { return "Connect \(AppBrand.displayName) in Settings to load public product metadata." }
        if !canRefresh { return "This engine does not provide this catalog operation. Update the paired app build." }
        if catalogStopped { return "Run a new search or refresh this scope when you are ready." }
        if catalogError != nil || !discoveryFailures.isEmpty || catalogSourceFailure != nil {
            return "The public catalog could not be fully checked. Refresh to try again; no empty owned library is inferred."
        }
        if query.isEmpty { return "Request public catalog data in this scope. Catalog results do not establish ownership or installation access." }
        if catalogCorpus == "publicMicrosoftStoreSearch", discoveryCheckedAt != nil {
            return "The public Store returned no matching games in this scope. This does not establish availability in other regions or your ownership."
        }
        return "No matching product in this partial catalog. This does not mean the game is unavailable or unowned."
    }

    var currentCredentialState: CredentialState? {
        guard isReady, accountStatusCurrent, !signInPending else { return nil }
        return authentication?.state
    }

    var accountSymbol: String {
        currentCredentialState == .credentialPresent ? "person.crop.circle.fill" : "person.crop.circle"
    }

    var accountLabel: String {
        if phase == .connecting { return "Connecting to \(AppBrand.displayName)" }
        if phase == .disconnecting { return "Disconnecting from \(AppBrand.displayName)" }
        guard isReady else { return "Connect \(AppBrand.displayName)" }
        if signInPending {
            return accountStatusCurrent ? "Sign-in pending" : "Sign-in status needs checking"
        }
        guard accountStatusCurrent else {
            return authentication == nil ? "Account status not checked" : "Account status needs checking"
        }
        switch currentCredentialState {
        case .credentialPresent: return "Microsoft sign-in saved"
        case .expired: return "Sign-in expired"
        case .invalid: return "Sign-in needs attention"
        case .signedOut: return "Sign in with Microsoft"
        case nil: return "Account status not checked"
        }
    }

    var accountExplanation: String {
        guard isReady else {
            return "Connect a trusted development engine in Settings before checking account status. Engine connection is not proof of sign-in."
        }
        if signInPending {
            if !accountStatusCurrent {
                return "The last sign-in result was pending, but its current outcome could not be confirmed. Check status or request cancellation; no completion or cancellation is assumed."
            }
            return "\(AppBrand.displayName) reports a pending sign-in, not a completed account connection. If Microsoft has opened a sign-in window, continue there yourself or use Cancel sign-in."
        }
        guard accountStatusCurrent else {
            return authentication == nil
                ? "The engine is connected, but account status has not been checked. Status checks don't open Microsoft sign-in or approve Keychain access. Public browsing does not read your Keychain."
                : "Current account status could not be confirmed. Check status before another sign-in or sign-out action; the earlier result is not current account evidence."
        }
        switch currentCredentialState {
        case .credentialPresent:
            return "Saved Microsoft sign-in is not proof of PC ownership, package access or gameplay compatibility."
        case .expired, .invalid:
            return "Disconnect this saved launcher sign-in first, then connect again. Other apps' accounts are not changed."
        case .signedOut:
            return "\(AppBrand.displayName) reports no saved launcher sign-in. Advertised sign-in support does not verify a paired engine and helper, PC ownership or permission to play."
        case nil:
            return "Account status has not been checked. No saved sign-in or PC access is assumed."
        }
    }

    var accountLibraryTitle: String {
        guard isReady else { return "Connect the app engine" }
        if signInPending { return accountLabel }
        guard accountStatusCurrent else { return accountLabel }
        return currentCredentialState == .credentialPresent
            ? "PC library access is not available yet" : "Your library starts with sign-in"
    }

    var accountLibraryExplanation: String {
        if currentCredentialState == .credentialPresent {
            return "Your Microsoft sign-in is saved, but this engine has not established authoritative PC ownership. No catalog result or play history is shown as an owned game."
        }
        return accountExplanation + " This build cannot yet prove a complete owned-PC library."
    }

    var accountFailureSummary: String? {
        guard let failure = lastSignInFailure else { return nil }
        if let diagnostic = failure.diagnostic {
            switch diagnostic {
            case .bootstrapInvalid, .clientUnavailable:
                return "Microsoft sign-in couldn't start. Check account status before trying again."
            case .credentialStorageUnavailable:
                return "macOS couldn't access the sign-in Keychain. Unlock it or review its permission window, then check account status."
            case .storedCredentialInvalid:
                return "Saved sign-in data couldn't be validated. Check account status before trying again; don't remove credentials."
            case .providerRequestFailed:
                return "Microsoft couldn't be reached while preparing sign-in. Check your connection and account status."
            case .workerOutcomeUnavailable:
                return "The sign-in attempt ended without a confirmed result. Check account status before trying again."
            case .pipelineFailed:
                return "Microsoft sign-in couldn't finish. Check account status before trying again."
            default:
                return "Microsoft's sign-in response couldn't be verified. Check account status; sign-in details are available below."
            }
        }
        guard let code = failure.code?.rawValue else {
            return "The last sign-in attempt couldn't be confirmed. Check account status before trying again."
        }
        return Self.describeSignInFailure(code: code)
    }

    var accountFailureDetails: String? {
        guard let failure = lastSignInFailure else { return nil }
        let code = failure.code?.rawValue ?? "Not reported"
        if let diagnostic = failure.diagnostic {
            return "Code: \(code). Stage: \(diagnostic.stage). Reason: \(diagnostic.rawValue). "
                + Self.describeConsentFailure(diagnostic)
        }
        return "Code: \(code). Stage: Not reported."
    }

    var accountFailureObservation: String? {
        lastSignInFailure?.observation
    }

    nonisolated static func validatedNativeSignInObservation(_ failure: WireFailure) -> String? {
        guard failure.code == "AUTH_INVALID", failure.nativeConsentFailure == .pipelineFailed else { return nil }
        let reasons = ["helper.invalidFrame", "helper.invalidNavigation", "helper.navigationFailed",
                       "helper.popupUnsupported", "helper.contentTerminated", "helper.javaScriptFailed",
                       "helper.bridgeInvalid", "helper.deadlineExpired", "helper.parentUnavailable",
                       "channelEOF", "unclassified", "tokenExchangeFailed", "helperCompletionFailed",
                       "tokenExchange.requestBuild", "tokenExchange.requestSerialization",
                       "tokenExchange.requestTransport", "tokenExchange.requestTimeout",
                       "tokenExchange.httpClientError", "tokenExchange.httpServerError",
                       "tokenExchange.httpStatusRejected", "tokenExchange.responseParsing",
                       "tokenExchange.responseSignature", "tokenExchange.responseCryptography",
                       "tokenExchange.responseEncoding", "tokenExchange.continuationRequired",
                       "tokenExchange.faultWithoutContinuation", "tokenExchange.continuationRejected",
                       "exchangeRetentionFailed"]
        return reasons.map { "Native sign-in failed: \($0)." }.first { $0 == failure.message }
    }

    var accountFailureTitle: String {
        if lastSignInFailure?.diagnostic?.stage == "devicePreparation" {
            return "Microsoft sign-in could not start."
        }
        return "Sign-in did not complete. Try again when you are ready."
    }

    private static func describeSignInFailure(code: String) -> String {
        let reason: String
        switch code {
        case "AUTH_CANCELLED":
            reason = "Sign-in was cancelled. Check account status before starting again."
        case "AUTH_EXPIRED":
            reason = "The sign-in request expired. Check account status, then try again."
        case "AUTH_INVALID":
            reason = "The sign-in session couldn't be verified. Check account status before trying again."
        case "NETWORK_UNAVAILABLE":
            reason = "Microsoft sign-in couldn't reach a required service. Check your connection and account status."
        default:
            reason = "The sign-in result couldn't be confirmed. Check account status before trying again."
        }
        return reason
    }

    private static func describeConsentFailure(_ failure: NativeConsentFailure) -> String {
        switch failure {
        case .bootstrapInvalid:
            "The authentication worker could not initialize safely. Keep the current app and report this diagnostic before another attempt."
        case .clientUnavailable:
            "The native sign-in client could not initialize. Keep the current app and report this diagnostic before another attempt."
        case .credentialStorageUnavailable:
            "Device credentials could not be prepared in Keychain. Personally review its native permission or unlock state before any later attempt."
        case .storedCredentialInvalid:
            "Stored launcher device material could not be validated. No credential deletion or replacement is advised; report this diagnostic."
        case .providerRequestFailed:
            "A provider request during device preparation failed. Its network or service cause is not established; report this diagnostic."
        case .providerProofInvalid:
            "The device-preparation response did not provide a valid sign-in proof. Report this diagnostic before another attempt."
        case .registrationProofInvalid:
            "Microsoft device registration did not provide a valid sign-in proof. Report this diagnostic before another attempt."
        case .tokenResponseInvalid:
            "The device sign-in response did not contain one supported result. Report this diagnostic before another attempt."
        case .tokenProofInvalid:
            "The device sign-in result lacked a valid token proof. Report this diagnostic before another attempt."
        case .tokenStructureInvalid:
            "The device sign-in proof did not have the required supported structure. Report this diagnostic before another attempt."
        case .tokenKindInvalid:
            "The device sign-in token uses a format this launcher cannot accept. Report this diagnostic before another attempt."
        case .tokenAudienceInvalid:
            "The device sign-in token did not match the required context. Report this diagnostic before another attempt."
        case .tokenCipherInvalid:
            "The device sign-in token payload could not be processed. Report this diagnostic before another attempt."
        case .tokenSecretInvalid:
            "The device sign-in proof was missing or invalid. Report this diagnostic before another attempt."
        case .tokenXmlBoundInvalid:
            "The device sign-in payload exceeded the supported processing limit. Report this diagnostic before another attempt."
        case .tokenXmlParseInvalid:
            "The device sign-in payload could not be read in the required format. Report this diagnostic before another attempt."
        case .tokenCipherEncodingInvalid:
            "The device sign-in payload encoding could not be processed. Report this diagnostic before another attempt."
        case .proofUnavailable:
            "Device proof was unavailable. No validated sign-in or package access was established; report this diagnostic."
        case .pipelineFailed:
            "Native sign-in or token exchange failed. This does not establish that a browser appeared or consent completed; report this diagnostic."
        case .proofInvalid:
            "The returned Store proof did not pass validation. No credential commit or package access was established; report this diagnostic."
        case .workerOutcomeUnavailable:
            "Failure stage is unavailable. The worker supplied no usable stage evidence; keep the current app and report the failure code."
        }
    }

    func supports(_ command: ManagementCommand) -> Bool { hello?.supports(command) == true }

    func readUnifiedAccount(_ section: OdeAccountSection, titleID: String? = nil,
                            market: String? = nil, language: String? = nil,
                            productID: String? = nil) async throws -> OdeAccountRead {
        guard (section == .license && productID.map(PCGamesClient.validProductID) == true && titleID == nil)
            || (section != .license && productID == nil) else { throw ManagementError.invalidPayload }
        guard section != .library || (accountCountryReady && (market == nil || market == self.market)) else {
            throw ManagementError.invalidPayload
        }
        let admissionGeneration = generation
        let admissionAuthentication = authenticationGeneration
        if section != .license {
            waitingInteractiveAccountReads += 1
            defer { waitingInteractiveAccountReads -= 1 }
            while licenseReadInFlight {
                try await Task.sleep(for: .milliseconds(50))
                guard generation == admissionGeneration, authenticationGeneration == admissionAuthentication else {
                    throw ManagementError.notSent
                }
            }
        }
        // f51e60fe B1: these refusals happen before anything leaves this Mac.
        guard hasConfirmedSignIn, !accountOperationBusy, !recentLibraryBootstrapRunning,
              section == .runtime || !accountRuntimeStarting, !applicationTerminating, let client,
              let account = accountHash else { throw ManagementError.notSent }
        let command: ManagementCommand = section == .runtime ? .odeRuntimeVerify : .odeAccountRead
        guard supports(command) else {
            throw ManagementError.capabilityMissing(command.rawValue)
        }
        let token = generation
        let authToken = authenticationGeneration
        accountOperationBusy = true
        if section == .license { licenseReadGeneration = token }
        defer {
            if token == generation {
                accountOperationBusy = false
                if section == .license { licenseReadGeneration = nil }
            }
        }
        // The country-independent profile endpoint still requires a syntactic wire market.
        // This bootstrap value is never used for a catalogue or owned-library request.
        let requestMarket = section == .profile && !accountCountryReady ? "US" : (market ?? self.market)
        var params: [String: JSONValue] = [
            "section": .string(section.rawValue), "accountHash": .string(account),
            "market": .string(requestMarket), "language": .string(language ?? self.language),
            "titleID": titleID.map(JSONValue.string) ?? .null
        ]
        if let productID { params["productID"] = .string(productID) }
        try DebugFaultInjection.check(.account)
        // d270a2c5: no automatic Microsoft read leaves this Mac while the gate is held; every answer feeds it.
        try readGate.admit(account: account)
        let result: OdeAccountRead
        do {
            result = try await client.request(command, params: params).decode(OdeAccountRead.self)
            readGate.recordSuccess(account: account)
        } catch {
            readGate.record(error, account: account)
            throw error
        }
        try Task.checkCancellation()
        guard token == generation, authToken == authenticationGeneration,
              accountHash == account, hasConfirmedSignIn else { throw ManagementError.disconnected }
        try result.validate(section: section, accountHash: account)
        if section == .profile {
            let profile = try result.payload.decode(XboxProfile.self)
            applyAccountCountry(profile.accountCountry, account: account)
        }
        return result
    }

    func prepareUnifiedRuntime() async {
        guard hasConfirmedSignIn, !accountBusy, !accountRuntimeStarting,
              !applicationTerminating, !accountRuntimeReady else { return }
        // d270a2c5: runtime verify is an RPS exchange with Microsoft; automatic starts wait for the gate.
        guard MicrosoftReadContext.explicit || readGate.allowsAutomaticRead(account: accountHash) else { return }
        guard supports(.odeRuntimeVerify), let configuration = connectedConfiguration else {
            accountRuntimeError = "This engine doesn't include the single-account game connection."
            return
        }
        let epoch = generation
        let authEpoch = authenticationGeneration
        let account = accountHash
        accountRuntimeStarting = true
        accountRuntimeError = nil
        defer { accountRuntimeStarting = false }
        do {
            guard await stopUnifiedRuntime() else { throw ManagementError.shutdownFailed }
            let proof = try await readUnifiedAccount(.runtime)
            guard proof.payload["authorized"]?.boolean == true else { throw ManagementError.invalidPayload }
            guard generation == epoch, authenticationGeneration == authEpoch,
                  hasConfirmedSignIn, accountHash == account, !applicationTerminating else { throw CancellationError() }
            let id = UUID()
            runtimeGeneration = id
            let runtime = OdeRuntimeProcess { [weak self] in
                guard let self, self.runtimeGeneration == id else { return }
                self.accountRuntimeReady = false
                self.accountRuntimeError = "The game connection stopped. Check Account to reconnect it."
            }
            accountRuntime = runtime
            try await runtime.start(configuration)
            guard generation == epoch, authenticationGeneration == authEpoch,
                  hasConfirmedSignIn, accountHash == account, !applicationTerminating else { throw CancellationError() }
            accountRuntimeReady = true
        } catch {
            guard await stopUnifiedRuntime() else {
                accountRuntimeError = "The game connection hasn't finished stopping. Wait before reconnecting."
                return
            }
            if generation == epoch, !(error is CancellationError) {
                accountRuntimeError = "The game connection couldn't be prepared. \(Self.describe(error))"
            }
        }
    }

    @discardableResult
    func stopUnifiedRuntime() async -> Bool {
        runtimeGeneration = UUID()
        accountRuntimeReady = false
        guard let accountRuntime else { return true }
        guard await accountRuntime.shutdown() else { return false }
        self.accountRuntime = nil
        return true
    }

#if !XODUS_SHIPPING
    var retiringDisconnectWaiterCount: Int { disconnectWaiters }

    func chooseBackend() {
        guard !connectionTransitioning else {
            errorMessage = "Wait for the current connection transition to finish before choosing another engine."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a trusted app engine"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            errorMessage = "That file is not executable. Choose the app engine."
            return
        }
        backendPath = url.path
        UserDefaults.standard.set(url.path, forKey: "Xodus.developerBackendPath")
    }
#endif

    func connect(readingAccountFirst: Bool = false) async {
        guard !applicationTerminating else { return }
        guard !connectionTransitioning, !backendPath.isEmpty else {
            if backendPath.isEmpty { errorMessage = "Choose your trusted app engine in Settings first." }
            return
        }
        let operationID = UUID()
        connectOperationID = operationID
        lifecycleRevision += 1
        let revision = lifecycleRevision
        updateConnectionTransition()
        defer {
            if connectOperationID == operationID { connectOperationID = nil }
            updateConnectionTransition()
        }
        let state = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Xodus/Management", isDirectory: true)
        guard await retireClient(), revision == lifecycleRevision else { return }
        phase = .connecting
        errorMessage = nil
        let token = generation
        do {
#if XODUS_SHIPPING
            let target = try ShippingPairAdmission.configuration(
                bundle: .main, stateDirectory: state, pins: ShippingPairPins.approved)
            let admittedTarget = target
#else
            let admittedTarget = try configuration ?? BackendConfiguration(
                executable: URL(fileURLWithPath: backendPath), stateDirectory: state,
                nativeAuthHost: NativeAuthHostBinding.bundled(in: .main))
#endif
            let connection = try ManagementClient()
            client = connection
            let negotiated = try await connection.connect(admittedTarget)
            guard token == generation, revision == lifecycleRevision, client === connection else { return }
            hello = negotiated
            let descriptorOwner = UUID()
            descriptorsOwner = descriptorOwner
            await PublicCatalogDescriptors.shared.bind(
                negotiated.supports(.descriptors) ? connection : nil, owner: descriptorOwner)
            guard token == generation, revision == lifecycleRevision, client === connection else { return }
            connectedConfiguration = admittedTarget
            nativeSignInHostAdmitted = admittedTarget.nativeAuthHost != nil
            let startupQueryRevision = queryGeneration
            phase = .ready
            if supports(.jobs) { try await reconcileActivity() }
            guard token == generation, revision == lifecycleRevision, client === connection else { return }
            eventTask = Task { [weak self] in
                do {
                    for try await event in connection.events {
                        guard let self, token == self.generation else { return }
                        try self.activity.apply(event)
                        if self.activity.needsSnapshot && !self.activity.isReconciling {
                            try await self.reconcileActivity()
                        }
                        if event.data.state == .completed,
                           !["pcGamePassDiscovery", "publicMicrosoftStoreSearch"].contains(self.catalogCorpus) {
                            await self.search(self.currentQuery)
                        }
                    }
                } catch {
                    guard let self, token == self.generation else { return }
                    await self.connectionFailed(error)
                }
            }
            // REQ-119: the launch's sign-in check runs before installed and catalogue reads, so the
            // welcome screen resolves first. Plain reconnects stay anonymous.
            if readingAccountFirst {
                restoreExpectedSince = Date()
                scheduleRestoreBound()
                await refreshAccount()
                guard token == generation, revision == lifecycleRevision, client === connection else { return }
            }
            await refreshInstalled()
            guard token == generation, revision == lifecycleRevision, client === connection else { return }
            if queryGeneration == startupQueryRevision { await search("") }
        } catch {
            guard token == generation, revision == lifecycleRevision else { return }
            await connectionFailed(error)
        }
    }

    @discardableResult
    func disconnect() async -> Bool {
        lifecycleRevision += 1
        disconnectWaiters += 1
        updateConnectionTransition()
        defer {
            disconnectWaiters -= 1
            updateConnectionTransition()
        }
        return await retireClient()
    }

    private func updateConnectionTransition() {
        connectionTransitioning = connectOperationID != nil || closingOperation != nil || disconnectWaiters > 0
    }

    private func retireClient() async -> Bool {
        descriptorMetricBaseline = nil
        descriptorMetricCounts = nil
        descriptorMetricIntervalCompleted = false
        guard await stopUnifiedRuntime() else {
            errorMessage = ManagementError.shutdownFailed.localizedDescription
            return false
        }
        connectedConfiguration = nil
        if let operation = closingOperation { return await finishRetirement(operation) }
        generation += 1
        recentLibraryBootstrap?.task.cancel()
        recentLibraryBootstrap = nil
        recentLibraryBootstrapRunning = false
        recentLibraryEntryGeneration = nil
        authenticationGeneration += 1
        queryGeneration += 1
        clearRecentLibrary()
        eventTask?.cancel()
        authTask?.cancel()
        catalogTask?.cancel()
        catalogTask = nil
        catalogWorkerID = nil
        queuedCatalog = nil
        queryResults.removeAll()
        eventTask = nil
        authTask = nil
        hello = nil
        if authentication != nil || countryAccountHash != nil { retireAccountCountry() }
        authentication = nil
        initialStatusSettled = false
        unverifiedCredentialSince = nil
        restoreExpectedSince = nil
        restoreRereadDone = false
        accountStatusCurrent = false
        nativeSignInHostAdmitted = false
        connectionFailedAfterAdmission = false
        managementStateLocked = false
        confirmedBeforeStatusRead = false
        accountError = nil
        accountStatusError = nil
        failedAccountAction = nil
        activityError = nil
        signInDeadline = nil
        installedSnapshot = nil
        installedSnapshotCurrent = false
        installedError = nil
        installedRefreshing = false
        inspection = nil
        inspectionBusy = false
        inspectionError = nil
        products = []
        selectedProduct = nil
        activity = ActivityStore()
        nextCursor = nil
        cacheRevision = nil
        catalogCorpus = "observedPublicProducts"
        catalogSourceFailure = nil
        discoveryFailures = []
        discoveryCheckedAt = nil
        discoveryRevision = nil
        gamePassProductIDs = []
        gamePassBadgeProductIDs = []
        gamePassProducts = []
        gamePassRevision = nil
        gamePassCatalogLoading = false
        gamePassCatalogError = nil
        gamePassCatalogCheckedAt = nil
        gamePassCatalogPaging = false
        gamePassPagingID = nil
        gamePassCatalogHasMore = false
        gamePassCatalogExhausted = false
        gamePassCatalogCompletedAt = nil
        gamePassPagesClean = false
        diagnosticPreview = nil
        diagnosticPreviewing = false
        diagnosticSaved = false
        diagnosticExportError = nil
        phase = .disconnecting
        searching = false
        catalogStopped = false
        lookupBusy = false
        accountOperationBusy = false
        signingOut = false
        accountStatusChecking = false
        if let owner = descriptorsOwner {
            descriptorsOwner = nil
            await PublicCatalogDescriptors.shared.unbind(owner: owner)
        }
        guard let previous = client else {
            phase = .disconnected
            return true
        }
        let shutdown = shutdownClient
        let operation = ClosingOperation(id: UUID(), client: previous,
                                         task: Task { await shutdown(previous) })
        closingOperation = operation
        updateConnectionTransition()
        return await finishRetirement(operation)
    }

    private func finishRetirement(_ operation: ClosingOperation) async -> Bool {
        let closed = await operation.task.value
        if closingOperation?.id == operation.id {
            closingOperation = nil
            if closed {
                MicrosoftSignInGate.shared.release(signInOwner)
                client = nil
                phase = .disconnected
            } else {
                // Keep the retiring client owned; no replacement can start without observing its exit.
                phase = .failed
                errorMessage = Self.describe(ManagementError.shutdownFailed)
            }
            updateConnectionTransition()
        }
        return closed
    }

    private func connectionFailed(_ error: Error) async {
        let failedClient = client
        let observedRevision = lifecycleRevision
        let helperValidated = await failedClient?.nativeAuthHostValidated == true
        guard observedRevision == lifecycleRevision, client === failedClient else { return }
        let pairingRejected = error as? ManagementError == .nativeAuthHostUnavailable
            || error as? ManagementError == .pairedEngineUnavailable
        let revision = observedRevision + 1
        guard await disconnect(), revision == lifecycleRevision else { return }
        phase = .failed
        managementStateLocked = error as? ManagementError == .stateLocked
        connectionFailedAfterAdmission = helperValidated && !pairingRejected
        errorMessage = Self.describe(error)
    }

    func refreshAccount() async {
        guard !recentLibraryBootstrapRunning else { return }
        await refreshAccountState()
    }

    private func refreshAccountState() async {
        guard isReady, supports(.authStatus), let client, !accountOperationBusy else { return }
        let firstCheck = !initialStatusSettled
        if firstCheck { FirstLoadTimeline.launchMark("signInCheckStart") }
        defer { if firstCheck, initialStatusSettled { FirstLoadTimeline.launchMark("signInCheckDone") } }
        let token = generation
        clearRecentLibrary()
        authenticationGeneration += 1
        let authToken = authenticationGeneration
        do {
            let status = try await readAccountStatus(using: client, generation: token)
            guard token == generation, authToken == authenticationGeneration else { return }
            acceptAccountStatus(status)
            accountError = nil
            failedAccountAction = nil
            errorMessage = nil
            initialStatusSettled = true
            applyProvisionalAccountCountry()
            restoreExpectedSince = nil
        } catch {
            guard token == generation, authToken == authenticationGeneration else { return }
            initialStatusSettled = true
            restoreExpectedSince = nil
            clearRecentLibrary()
            accountStatusCurrent = false
            accountStatusError = error as? ManagementError
            accountError = Self.describe(error)
            failedAccountAction = .status
            errorMessage = Self.describe(error)
        }
    }

    private func readAccountStatus(using client: ManagementClient, generation token: Int) async throws -> AuthenticationStatus {
        confirmedBeforeStatusRead = accountStatusCurrent && authentication?.state == .credentialPresent
        accountOperationBusy = true
        accountStatusChecking = true
        accountStatusCurrent = false
        defer {
            if token == generation {
                accountOperationBusy = false
                accountStatusChecking = false
                confirmedBeforeStatusRead = false
            }
        }
        return try await client.request(.authStatus).decode(AuthenticationStatus.self)
    }

    private func acceptAccountStatus(_ status: AuthenticationStatus) {
        if let currentFlow = authentication?.flow, let incomingFlow = status.flow,
           currentFlow.flowID == incomingFlow.flowID,
           currentFlow.state != .pending, incomingFlow.state == .pending { return }
        if status.state != .credentialPresent { clearRecentLibrary() }
        if let flow = status.flow, flow.state == .failed {
            lastSignInFailure = SignInFailureSnapshot(flow.error)
        } else if status.flow?.state == .completed {
            lastSignInFailure = nil
        }
        if (authentication != nil && authentication?.accountHash != status.accountHash)
            || (status.state != .credentialPresent && countryAccountHash != nil) {
            retireAccountCountry()
        }
        authentication = status
        if status.state == .credentialPresent, status.accountHash.map(XboxAccountBinding.valid) != true {
            if unverifiedCredentialSince == nil {
                unverifiedCredentialSince = Date()
                scheduleRestoreBound()
            }
        } else {
            unverifiedCredentialSince = nil
        }
        if status.state != .signedOut { appSignOutComplete = false }
        if status.flow?.state != .pending {
            MicrosoftSignInGate.shared.release(signInOwner)
        }
        accountStatusCurrent = true
        accountStatusError = nil
        accountStatusReadAt = Date()
    }

    func refreshInstalled() async {
        guard isReady, supports(.installed), let client, !installedRefreshing else { return }
        let token = generation
        installedRefreshing = true
        installedSnapshotCurrent = false
        installedError = nil
        defer { if token == generation { installedRefreshing = false } }
        do {
            let snapshot = try await client.request(.installed).decode(InstalledSnapshot.self)
            guard token == generation else { return }
            guard snapshot.scope == "managementRegistryOnly", snapshot.completeness == "complete",
                  Set(snapshot.installations.map(\.id)).count == snapshot.installations.count,
                  installedSnapshot.map({ snapshot.watermark >= $0.watermark }) ?? true else {
                throw ManagementError.invalidPayload
            }
            installedSnapshot = snapshot
            installedSnapshotCurrent = true
        } catch {
            guard token == generation else { return }
            installedError = Self.describe(error)
        }
    }

    func activityTitle(_ job: CatalogJob) -> String {
        products.first { $0.id == job.product.productID }?.title ?? "Game details check"
    }

    func chooseInstallationFolder() {
        guard isReady, supports(.inspectInstallation), !inspectionBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Inspect a game folder"
        panel.message = "Choose one exact folder. \(AppBrand.displayName) reads only its streaming marker metadata; it will not scan, register, modify or launch the game."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await inspectInstallation(at: url) }
    }

    func inspectInstallation(at directory: URL) async {
        guard isReady, supports(.inspectInstallation), let client, !inspectionBusy else { return }
        guard directory.isFileURL, directory.host == nil || directory.host == "",
              directory.path.hasPrefix("/") else {
            inspectionError = "Choose one local game folder. No files were inspected or changed."
            return
        }
        inspectionBusy = true
        inspection = nil
        inspectionError = nil
        let token = generation
        defer { if token == generation { inspectionBusy = false } }
        do {
            let result = try await client.request(.inspectInstallation, params: ["directory": .string(directory.path)])
                .decode(InstallationInspection.self)
            guard token == generation else { return }
            try result.validateSelection(directory: directory.path)
            inspection = result
        } catch {
            guard token == generation else { return }
            switch error {
            case ManagementError.backendError("NOT_FOUND", _):
                inspectionError = "This folder has no supported streaming marker. Nothing was added to your Library."
            case ManagementError.backendError("INTEGRITY_FAILED", _):
                inspectionError = "The marker could not be safely interpreted. No files were changed."
            case ManagementError.backendError("UNSUPPORTED_CONFIGURATION", _):
                inspectionError = "This folder cannot be safely inspected. Choose a direct local folder without aliases or linked files."
            default: inspectionError = Self.describe(error)
            }
        }
    }

    func beginSignIn() async {
        guard canSignIn, let client else { return }
        guard MicrosoftSignInGate.shared.acquire(signInOwner) else {
            accountError = "Finish or cancel the current Microsoft sign-in before starting another."
            return
        }
        clearRecentLibrary()
        authenticationGeneration += 1
        accountOperationBusy = true
        accountError = nil
        failedAccountAction = nil
        errorMessage = nil
        let token = generation
        do {
            let status = try await client.request(.authBegin, params: ["accountScope": .string("default")])
                .decode(AuthenticationStatus.self)
            guard token == generation else { return }
            guard let flow = status.flow else { throw ManagementError.invalidPayload }
            acceptAccountStatus(status)
            signInDeadline = ContinuousClock.now.advanced(by: signInPollingBudget)
            accountOperationBusy = false
            if flow.state == .pending { pollSignIn(flowID: flow.flowID, generation: token) }
        } catch {
            guard token == generation else { return }
            lastSignInFailure = SignInFailureSnapshot(requestError: error)
            accountOperationBusy = false
            accountStatusCurrent = false
            if case let ManagementError.backendError(code, _) = error {
                errorMessage = "Microsoft sign-in could not start. " + Self.describeSignInFailure(code: code)
            } else { errorMessage = Self.describe(error) }
            accountError = errorMessage
            failedAccountAction = .signIn
        }
    }

    private func pollSignIn(flowID: String, generation token: Int) {
        authTask?.cancel()
        authTask = Task { [weak self] in
            let deadline = self?.signInDeadline ?? ContinuousClock.now.advanced(by: self?.signInPollingBudget ?? .seconds(600))
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, token == self.generation, let client = self.client else { return }
                    if self.accountBusy { continue }
                    let finalCheck = ContinuousClock.now >= deadline
                    self.authenticationGeneration += 1
                    let authToken = self.authenticationGeneration
                    let status: AuthenticationStatus
                    do { status = try await self.readAccountStatus(using: client, generation: token) }
                    catch {
                        guard token == self.generation, authToken == self.authenticationGeneration,
                              !Task.isCancelled else { return }
                        self.accountStatusCurrent = false
                        self.accountStatusError = error as? ManagementError
                        self.errorMessage = Self.describe(error)
                        self.accountError = self.errorMessage
                        self.failedAccountAction = .status
                        if error as? ManagementError == .credentialStoreUnavailable { return }
                        if case ManagementError.backendError(_, retryable: true) = error, !finalCheck { continue }
                        return
                    }
                    guard token == self.generation, authToken == self.authenticationGeneration, !Task.isCancelled,
                          self.authentication?.flow?.flowID == flowID,
                          self.authentication?.flow?.state == .pending else { return }
                    guard status.flow?.flowID == flowID else { throw ManagementError.invalidPayload }
                    self.acceptAccountStatus(status)
                    self.accountError = nil
                    self.failedAccountAction = nil
                    if status.flow?.state != .pending {
                        if status.flow?.state == .completed {
                            self.errorMessage = nil
                            if let account = status.accountHash { self.readGate.signedIn(account: account) }
                        }
                        return
                    }
                    if finalCheck || ContinuousClock.now >= deadline {
                        self.accountStatusCurrent = false
                        self.errorMessage = "Sign-in is still pending. Check status before retrying or closing; no cancellation was assumed."
                        self.accountError = self.errorMessage
                        self.failedAccountAction = .status
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, token == self.generation else { return }
                self.errorMessage = Self.describe(error)
                self.accountError = self.errorMessage
                self.failedAccountAction = .status
            }
        }
    }

    func cancelSignIn() async {
        guard let flow = authentication?.flow, flow.state == .pending, let client,
              supports(.authCancel), !accountBusy else { return }
        authenticationGeneration += 1
        accountOperationBusy = true
        accountError = nil
        failedAccountAction = nil
        authTask?.cancel()
        let token = generation
        do {
            let status = try await client.request(.authCancel, params: ["flowID": .string(flow.flowID)])
                .decode(AuthenticationStatus.self)
            guard token == generation else { return }
            guard status.flow?.flowID == flow.flowID, status.flow?.state != .pending else {
                throw ManagementError.invalidPayload
            }
            acceptAccountStatus(status)
            if status.flow?.state == .completed {
                errorMessage = "Sign-in finished before cancellation. Your sign-in is saved; use Sign out to remove it."
            }
        } catch {
            guard token == generation else { return }
            if case ManagementError.backendError("INVALID_TRANSITION", _) = error {
                errorMessage = "Sign-in is finishing. Checking the saved result before closing."
            } else { errorMessage = Self.describe(error) }
            accountError = errorMessage
            failedAccountAction = .cancellation
            if authentication?.flow?.flowID == flow.flowID, signInPending {
                pollSignIn(flowID: flow.flowID, generation: token)
            }
        }
        if token == generation { accountOperationBusy = false }
    }

    @discardableResult
    func signOut(beforeDisconnect: @MainActor () async -> String? = { nil }) async -> Bool {
        guard !signingOut else { return false }
        let signedOutAccount = accountHash
        guard let client, canDisconnectAccount else {
            errorMessage = "Check the current saved sign-in before disconnecting. No credentials were removed."
            accountError = errorMessage
            failedAccountAction = .signOut
            return false
        }
        let signOutOwner = UUID()
        guard MicrosoftSignInGate.shared.acquire(signOutOwner) else {
            accountError = "Finish or cancel the current Microsoft sign-in before signing out of \(AppBrand.displayName)."
            return false
        }
        defer { MicrosoftSignInGate.shared.release(signOutOwner) }
        let launcherAlreadySignedOut = authentication?.state == .signedOut
        clearRecentLibrary()
        invalidateCatalogScope()
        authenticationGeneration += 1
        accountOperationBusy = true
        signingOut = true
        appSignOutComplete = false
        accountError = nil
        failedAccountAction = nil
        authTask?.cancel()
        accountStatusCurrent = false
        let token = generation
        defer {
            if token == generation {
                accountOperationBusy = false
                signingOut = false
            }
        }
        if let preparationError = await beforeDisconnect() {
            guard token == generation else { return false }
            errorMessage = preparationError
            accountError = errorMessage
            failedAccountAction = .signOut
            return false
        }
        guard token == generation else { return false }
        do {
            if !launcherAlreadySignedOut {
                let status = try await client.request(.authLogout).decode(AuthenticationStatus.self)
                guard token == generation else { return false }
                guard status.state == .signedOut else { throw ManagementError.invalidPayload }
                authentication = status
            }
            accountStatusCurrent = true
            diagnosticPreview = nil
            readGate.signedOut()
            if let signedOutAccount { forgetAccountCountry(signedOutAccount) }
            await signOutCleanup()
            return true
        } catch {
            guard token == generation else { return false }
            errorMessage = "\(AppBrand.displayName) couldn't confirm launcher sign-out. Some app sign-in data may already have been removed. Check account status before retrying. " + Self.describe(error)
            accountError = errorMessage
            failedAccountAction = .signOut
            return false
        }
    }

    func confirmAppSignOut() {
        guard !signingOut, accountStatusCurrent, authentication?.state == .signedOut else { return }
        appSignOutComplete = true
    }

    func search(_ query: String, more: Bool = false) async {
        await queueCatalog(query, command: .search, more: more)
    }

    private var catalogRequestScope: String?

    private func queueCatalog(_ query: String, command: ManagementCommand, more: Bool) async {
        guard isReady, supports(command) else { return }
        guard validScope else { catalogError = "Use a two-letter market and a language such as en-US."; return }
        let corpus = command == .query ? "publicMicrosoftStoreSearch"
            : command == .discover ? "pcGamePassDiscovery" : "observedPublicProducts"
        if more && (!canLoadMoreCatalog || catalogCorpus != corpus || currentQuery != query) { return }
        let retainsProducts = currentQuery == query && catalogCorpus == corpus
            && catalogRequestScope == "\(market):\(language)"
        queryGeneration += 1
        queuedCatalog = CatalogRequest(command: command, query: query, market: market, language: language,
            cursor: more ? nextCursor : nil, more: more, generation: generation, queryGeneration: queryGeneration)
        currentQuery = query
        catalogRequestScope = "\(market):\(language)"
        if !more && !retainsProducts {
            catalogSourceFailure = nil
            products = []
            nextCursor = nil
            cacheRevision = nil
            discoveryFailures = []
            discoveryCheckedAt = nil
            discoveryRevision = nil
        }
        catalogCorpus = corpus
        catalogRequestAppends = more
        searching = true
        catalogStopped = false
        catalogError = nil
        if catalogTask == nil {
            let workerID = UUID()
            catalogWorkerID = workerID
            catalogTask = Task { [weak self] in
                guard let self else { return }
                // Cancelling a view task does not release a producer HTTP operation.
                while !Task.isCancelled, self.catalogWorkerID == workerID,
                      let request = self.queuedCatalog {
                    self.queuedCatalog = nil
                    switch request.command {
                    case .query: await self.queryStore(request)
                    case .discover: await self.browseDiscovery(request)
                    default: await self.searchCache(request)
                    }
                }
                if self.catalogWorkerID == workerID {
                    self.catalogTask = nil
                    self.catalogWorkerID = nil
                }
            }
        }
        await catalogTask?.value
    }

    private func isCurrent(_ request: CatalogRequest) -> Bool {
        request.generation == generation && request.queryGeneration == queryGeneration && !Task.isCancelled
    }

    private func searchCache(_ request: CatalogRequest) async {
        guard let client, request.generation == generation else { return }
        defer { if isCurrent(request) { searching = false } }
        do {
            try DebugFaultInjection.check(.catalog)
            let result = try await client.request(.search, params: [
                "query": .string(request.query), "market": .string(request.market), "language": .string(request.language),
                "platform": .string("pc"), "limit": .integer(100), "cursor": request.cursor.map(JSONValue.string) ?? .null
            ]).decode(CatalogSearch.self)
            guard isCurrent(request) else { return }
            guard Set(result.products.map(\.id)).count == result.products.count else {
                throw ManagementError.invalidPayload
            }
            for product in result.products {
                try product.validatePublicScope(market: request.market, language: request.language)
            }
            if request.more {
                guard result.cacheRevision == cacheRevision,
                      Set(products.map(\.id)).isDisjoint(with: Set(result.products.map(\.id))),
                      products.count + result.products.count <= 512 else {
                    throw ManagementError.backendError("REVISION_CONFLICT", retryable: true)
                }
                products += result.products
            } else { products = result.products }
            cacheRevision = result.cacheRevision
            nextCursor = result.nextCursor
            catalogCorpus = result.corpus
            discoveryFailures = []
            discoveryCheckedAt = nil
            discoveryRevision = nil
        } catch {
            guard isCurrent(request) else { return }
            catalogError = Self.describe(error)
        }
    }

    private func queryResultKey(_ query: String, market: String, language: String) -> String {
        CatalogQueryResultCache.key(account: accountHash, market: market, language: language, query: query)
    }

    private func rememberQueryResult(_ request: CatalogRequest) {
        guard catalogError == nil, currentQuery == request.query,
              catalogRequestScope == "\(request.market):\(request.language)" else { return }
        queryResults.store(CatalogQuerySnapshot(products: products, failures: discoveryFailures,
            nextCursor: nextCursor, sourceFailure: catalogSourceFailure, checkedAt: discoveryCheckedAt,
            corpus: catalogCorpus, storedAt: .now),
            for: queryResultKey(request.query, market: request.market, language: request.language))
    }

    func hasRecentQueryResult(_ query: String) -> Bool {
        let scopedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopedQuery.isEmpty, supports(.query) else { return false }
        return queryResults.fresh(queryResultKey(scopedQuery, market: market, language: language)) != nil
    }

    var recentQueryResultCount: Int { queryResults.count }

    /// Publishes a remembered query page set in the current scope. Any in-flight read is
    /// fenced from publication and a queued older read is dropped; the producer slot itself
    /// is released when its bounded read returns.
    private func publishRecentQueryResult(_ query: String) -> Bool {
        guard isReady, validScope, supports(.query), !query.isEmpty,
              let snapshot = queryResults.fresh(queryResultKey(query, market: market, language: language))
        else { return false }
        queryGeneration += 1
        queuedCatalog = nil
        currentQuery = query
        catalogRequestScope = "\(market):\(language)"
        catalogCorpus = snapshot.corpus
        catalogRequestAppends = false
        products = snapshot.products
        discoveryFailures = snapshot.failures
        nextCursor = snapshot.nextCursor
        catalogSourceFailure = snapshot.sourceFailure
        discoveryCheckedAt = snapshot.checkedAt
        cacheRevision = nil
        catalogError = nil
        catalogStopped = false
        searching = false
        return true
    }

    /// Typed-input entry point: debounces edits unless the query already has a remembered
    /// result, then loads it. Cancelling the caller (a newer edit) skips the stale read.
    func loadCatalogAfterInput(_ query: String) async {
        let scopedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scopedQuery.isEmpty, !hasRecentQueryResult(scopedQuery) {
            do { try await Task.sleep(for: CatalogSearchTiming.debounce) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        await loadCatalogOnEntry(scopedQuery)
    }

    func loadCatalogOnEntry(_ query: String) async {
        let scopedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let corpus = scopedQuery.isEmpty && supports(.discover) ? "pcGamePassDiscovery"
            : !scopedQuery.isEmpty && supports(.query) ? "publicMicrosoftStoreSearch" : "observedPublicProducts"
        if currentQuery == scopedQuery, catalogCorpus == corpus,
           catalogRequestScope == "\(market):\(language)",
           !catalogStopped, catalogError == nil,
           searching || discoveryCheckedAt != nil || cacheRevision != nil { return }
        if corpus == "publicMicrosoftStoreSearch", publishRecentQueryResult(scopedQuery) { return }
        await refreshCatalog(scopedQuery)
    }

    func refreshCatalog(_ query: String, more: Bool = false) async {
        let scopedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if scopedQuery.isEmpty, supports(.discover) {
            await queueCatalog(scopedQuery, command: .discover, more: more)
        } else if !scopedQuery.isEmpty, supports(.query) {
            await queueCatalog(scopedQuery, command: .query, more: more)
        } else { await search(scopedQuery, more: more) }
    }

    func loadGamePassCatalog(refresh: Bool = false) async {
        guard isReady, supports(.discover), validScope, !gamePassCatalogPaging,
              !Task.isCancelled else { return }
        let owner = UUID(), token = generation, scopeMarket = market, scopeLanguage = language
        gamePassPagingID = owner
        gamePassCatalogPaging = true
        defer {
            if gamePassPagingID == owner {
                gamePassPagingID = nil
                gamePassCatalogPaging = false
            }
        }
        func current() -> Bool {
            !Task.isCancelled && generation == token && gamePassPagingID == owner &&
                market == scopeMarket && language == scopeLanguage && isReady
        }
        if searching { await catalogTask?.value }
        guard current() else { return }
        if refresh || catalogCorpus != "pcGamePassDiscovery" || !currentQuery.isEmpty ||
            discoveryCheckedAt == nil {
            gamePassCatalogExhausted = false
        gamePassCatalogCompletedAt = nil
        gamePassPagesClean = false
            await refreshCatalog("")
            return
        } else if gamePassCatalogExhausted && nextCursor == nil {
            return
        }
        guard current(), catalogCorpus == "pcGamePassDiscovery", currentQuery.isEmpty,
              catalogError == nil, !catalogStopped else { return }
        guard nextCursor != nil else { return }
        guard !catalogAtLimit else {
            gamePassCatalogError = "The catalogue reached this build's limit. Some games remain unloaded."
            gamePassCatalogHasMore = false
            return
        }
        await refreshCatalog("", more: true)
    }

    /// True only for a clean, complete and recent public PC Game Pass list.
    func gamePassCatalogComplete(now: Date = Date()) -> Bool {
        guard let completed = gamePassCatalogCompletedAt, gamePassCatalogError == nil, catalogError == nil,
              discoveryFailures.isEmpty, gamePassCatalogExhausted else { return false }
        let age = now.timeIntervalSince(completed)
        return age >= 0 && age < Self.gamePassCatalogMaximumAge
    }

    func catalogMatches(query: String) -> Bool {
        currentQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func retainedPublicIDs(query: String, pending: Bool) -> Set<String> {
        GameSearchPresentation.retainedPublicIDs(pending: pending, searching: searching && !catalogRequestAppends,
            matchesQuery: catalogMatches(query: query), products: products)
    }

    func stopCatalogSearch() {
        guard searching else { return }
        queryGeneration += 1
        queuedCatalog = nil
        searching = false
        catalogStopped = true
        catalogError = nil
        gamePassCatalogLoading = false
        gamePassCatalogError = "Catalog refresh stopped"
        gamePassPagingID = nil
        gamePassCatalogPaging = false
    }

    private func queryStore(_ request: CatalogRequest) async {
        guard let client, request.generation == generation else { return }
        defer { if isCurrent(request) { searching = false } }
        do {
            try DebugFaultInjection.check(.catalog)
            let page = try await client.request(.query, params: [
                "query": .string(request.query), "market": .string(request.market), "language": .string(request.language),
                "limit": .integer(8), "cursor": request.cursor.map(JSONValue.string) ?? .null
            ], timeout: .seconds(45)).decode(CatalogQuery.self)
            guard isCurrent(request) else { return }
            try applyQueryPage(page, request: request)
            rememberQueryResult(request)
        } catch {
            guard isCurrent(request) else { return }
            if case let ManagementError.queryFailed(page) = error {
                do { try applyQueryPage(page, request: request) }
                catch { catalogError = Self.describe(error); return }
                if !products.isEmpty || page.nextCursor != nil {
                    catalogError = nil
                    return
                }
            }
            catalogError = Self.describe(error)
        }
    }

    private func applyQueryPage(_ page: CatalogQuery, request: CatalogRequest) throws {
        try page.validatePublicScope(query: request.query, market: request.market, language: request.language, limit: 8)
        let existingIDs = Set(products.map(\.id) + discoveryFailures.map(\.id))
        let incomingIDs = Set(page.products.map(\.id) + page.failures.map(\.id))
        if request.more {
            guard existingIDs.isDisjoint(with: incomingIDs), existingIDs.count + incomingIDs.count <= 512,
                  page.nextCursor != request.cursor else {
                throw ManagementError.backendError("REVISION_CONFLICT", retryable: true)
            }
            products += page.products
            discoveryFailures += page.failures
        } else {
            products = refreshedProducts(page.products, failures: page.failures.map(\.productID))
            discoveryFailures = page.failures
        }
        nextCursor = page.nextCursor
        catalogSourceFailure = request.more ? (page.sourceFailure ?? catalogSourceFailure) : page.sourceFailure
        discoveryCheckedAt = page.checkedAt
        catalogCorpus = page.corpus
    }

    private func refreshedProducts(_ incoming: [CatalogProduct], failures: [String]) -> [CatalogProduct] {
        if incoming.isEmpty, !failures.isEmpty { return products }
        let failed = Set(failures)
        let successful = Set(incoming.map(\.id))
        return incoming + products.filter { failed.contains($0.id) && !successful.contains($0.id) }
    }

    private func browseDiscovery(_ request: CatalogRequest) async {
        guard let client, request.generation == generation else { return }
        catalogSourceFailure = nil
        if !request.more { gamePassBadgeProductIDs = [] }
        gamePassCatalogCompletedAt = nil
        gamePassCatalogLoading = true
        gamePassCatalogError = nil
        defer {
            gamePassCatalogLoading = false
            if isCurrent(request) { searching = false }
        }
        do {
            try DebugFaultInjection.check(.catalog)
            let page = try await client.request(.discover, params: [
                "market": .string(request.market), "language": .string(request.language), "limit": .integer(16),
                "cursor": request.cursor.map(JSONValue.string) ?? .null
            ], timeout: .seconds(45)).decode(CatalogDiscovery.self)
            guard isCurrent(request) else { return }
            try applyDiscoveryPage(page, request: request)
            if !page.failures.isEmpty { gamePassCatalogError = "Partial catalog refresh" }
        } catch {
            guard isCurrent(request) else { return }
            defer {
                gamePassPagesClean = false
                gamePassCatalogCompletedAt = nil
            }
            if case let ManagementError.discoveryFailed(page) = error {
                do { try applyDiscoveryPage(page, request: request) }
                catch {
                    catalogError = Self.describe(error)
                    gamePassCatalogError = catalogError
                    return
                }
            }
            catalogError = Self.describe(error)
            gamePassCatalogError = catalogError
        }
    }

    private func applyDiscoveryPage(_ page: CatalogDiscovery, request: CatalogRequest) throws {
        try page.validatePublicScope(market: request.market, language: request.language, limit: 16)
        let pcProducts = page.products.filter(\.pcCatalogCandidate)
        guard gamePassProductIDs.union(pcProducts.map(\.id)).count <= 512 else {
            throw ManagementError.backendError("REVISION_CONFLICT", retryable: true)
        }
        if !pcProducts.isEmpty { gamePassCatalogCheckedAt = page.checkedAt }
        let existingIDs = Set(products.map(\.id) + discoveryFailures.map(\.id))
        let incomingIDs = Set(page.products.map(\.id) + page.failures.map(\.id))
        if request.more {
            guard page.corpusRevision == discoveryRevision,
                  existingIDs.union(incomingIDs).count <= 512, page.nextCursor != request.cursor else {
                throw ManagementError.backendError("REVISION_CONFLICT", retryable: true)
            }
        }
        if gamePassRevision != page.corpusRevision { gamePassBadgeProductIDs = [] }
        gamePassBadgeProductIDs.subtract(incomingIDs)
        gamePassBadgeProductIDs.formUnion(pcProducts.filter { $0.freshness == "live" }.map(\.id))
        // A first page cannot revoke successful records from later pages.
        let incoming = Dictionary(uniqueKeysWithValues: page.products.map { ($0.id, $0) })
        let successful = Set(page.products.map(\.id))
        let priorProducts = Set(products.map(\.id))
        products = products.map { incoming[$0.id] ?? $0 }
            + page.products.filter { !priorProducts.contains($0.id) }
        discoveryFailures = request.more
            ? discoveryFailures.filter { !successful.contains($0.id) && !incomingIDs.contains($0.id) } + page.failures
            : page.failures
        nextCursor = page.nextCursor
        gamePassCatalogHasMore = page.nextCursor != nil
        gamePassCatalogExhausted = page.nextCursor == nil
        let revisionUnchanged = !request.more || page.corpusRevision == gamePassRevision
        gamePassPagesClean = (request.more ? gamePassPagesClean : true) && revisionUnchanged
            && page.failures.isEmpty
        gamePassCatalogCompletedAt = gamePassPagesClean && page.nextCursor == nil && discoveryFailures.isEmpty
            && !catalogAtLimit ? Date() : nil
        discoveryRevision = page.corpusRevision
        discoveryCheckedAt = page.checkedAt
        catalogCorpus = page.corpus
        cacheRevision = nil
        if gamePassRevision != page.corpusRevision {
            // A partial revision's omissions cannot revoke prior membership metadata.
            // Retain bounded public records, with the explicit unconfirmed/partial notice.
            gamePassRevision = page.corpusRevision
        }
        let incomingPC = Dictionary(uniqueKeysWithValues: pcProducts.map { ($0.id, $0) })
        gamePassProducts = gamePassProducts.map { incomingPC[$0.id] ?? $0 }
            + pcProducts.filter { !gamePassProductIDs.contains($0.id) }
        gamePassProductIDs.formUnion(pcProducts.map(\.id))
        if catalogAtLimit, nextCursor != nil {
            gamePassCatalogHasMore = false
            gamePassCatalogError = "The catalogue reached this build's limit. Some games remain unloaded."
        }
    }

#if !XODUS_SHIPPING
    func loadReadOnlyCatalogPreview(_ snapshot: CatalogReviewSnapshot, query: String) throws {
        guard LibraryPreviewExporter.requested, phase == .disconnected,
              query.utf8.count <= 128,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ManagementError.invalidPayload
        }
        let checked = try snapshot.pcProducts(market: market, language: language)
        invalidateCatalogScope()
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        products = checked.filter {
            currentQuery.isEmpty || $0.title.range(of: currentQuery, options: .caseInsensitive) != nil
        }
        catalogCorpus = "observedPublicProducts"
    }
#endif

    private func invalidateCatalogScope() {
        lookupBusy = false
        LibraryCatalogArtwork.shared.retireScope()
        // Retire publication now, but keep the producer slot until its actual read finishes.
        catalogSourceFailure = nil
        queryGeneration += 1
        queuedCatalog = nil
        queryResults.removeAll()
        products = []
        selectedProduct = nil
        nextCursor = nil
        cacheRevision = nil
        discoveryRevision = nil
        gamePassProductIDs = []
        gamePassBadgeProductIDs = []
        gamePassProducts = []
        gamePassRevision = nil
        gamePassCatalogLoading = false
        gamePassCatalogError = nil
        gamePassCatalogCheckedAt = nil
        gamePassPagingID = nil
        gamePassCatalogPaging = false
        gamePassCatalogHasMore = false
        gamePassCatalogExhausted = false
        gamePassCatalogCompletedAt = nil
        gamePassPagesClean = false
        discoveryFailures = []
        discoveryCheckedAt = nil
        catalogCorpus = "observedPublicProducts"
        catalogError = nil
        searching = false
        catalogStopped = false
    }

    func lookupProduct() async {
        guard isReady, let client, supports(.enqueue), !lookupBusy else { return }
        guard validScope else {
            errorMessage = "Use a two-letter market and a language such as en-US."
            return
        }
        let id = lookupID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard id.range(of: "^[A-Z0-9]{12}$", options: .regularExpression) != nil else {
            errorMessage = "Enter a 12-character public Microsoft Store product ID."
            return
        }
        lookupBusy = true
        errorMessage = nil
        let token = generation
        let scope = queryGeneration
        do {
            let result = try await client.request(.enqueue, params: [
                "kind": .string("catalogRefresh"), "idempotencyKey": .string(UUID().uuidString),
                "product": .object(["productID": .string(id), "market": .string(market),
                                    "language": .string(language), "refresh": .string("network")])
            ]).decode(JobResult.self)
            guard token == generation, scope == queryGeneration else { return }
            guard result.job.product.productID == id else { throw ManagementError.invalidPayload }
            try await reconcileActivity()
        } catch {
            guard token == generation, scope == queryGeneration else { return }
            errorMessage = Self.describe(error)
        }
        if token == generation, scope == queryGeneration { lookupBusy = false }
    }

    func changeJob(_ job: CatalogJob, command: ManagementCommand) async {
        guard isReady, let client, supports(command), !activity.needsSnapshot, !activity.isReconciling else { return }
        let token = generation
        activityError = nil
        do {
            _ = try await client.request(command, params: [
                "jobID": .string(job.id), "expectedRevision": .unsigned(job.revision)
            ]).decode(JobResult.self)
            guard token == generation else { return }
            try await reconcileActivity()
        } catch {
            guard token == generation else { return }
            errorMessage = Self.describe(error)
            activityError = Self.describe(error)
        }
    }

    func refreshActivity() async {
        guard isReady, supports(.jobs), !activity.isReconciling else { return }
        let token = generation
        activityError = nil
        do { try await reconcileActivity() }
        catch {
            guard token == generation else { return }
            activityError = Self.describe(error)
        }
    }

    func reconcileActivity() async throws {
        guard supports(.jobs), let client, !activity.isReconciling else { return }
        let token = generation
        for _ in 0..<3 {
            try activity.beginSnapshot()
            do {
                let snapshot = try await client.request(.jobs).decode(JobsSnapshot.self)
                guard token == generation else { return }
                guard snapshot.sessionID == hello?.sessionID else { throw ManagementError.invalidEvent }
                try activity.apply(snapshot)
                if !activity.needsSnapshot { return }
            } catch {
                guard token == generation else { return }
                // A failed fence must not leave the UI waiting indefinitely for a snapshot.
                activity.abortSnapshot()
                throw error
            }
        }
        throw ManagementError.invalidEvent
    }

    func previewDiagnostics() async {
        guard supports(.diagnostics), let client, !diagnosticSaving, !diagnosticPreviewing else { return }
        diagnosticPreviewing = true
        diagnosticPreview = nil
        diagnosticSaved = false
        diagnosticExportError = nil
        let token = generation
        defer { if token == generation { diagnosticPreviewing = false } }
        do {
            let value: JSONValue
            if await client.descriptorMetricsOptedIn {
                let checkpoint = try await client.descriptorMetricsDiagnosticCheckpoint()
                guard token == generation else { return }
                value = checkpoint.data
                if let counts = checkpoint.counts {
                    recordDescriptorMetrics(counts)
                } else {
                    incompleteDescriptorMetrics()
                }
            } else {
                value = try await client.request(.diagnostics)
            }
            guard token == generation else { return }
            guard let jobs = value["jobCount"]?.uint64, let products = value["cachedProductCount"]?.uint64,
                  value["redacted"] == .bool(true) else { throw ManagementError.invalidPayload }
            diagnosticPreview = "Management protocol 1.0\nCatalog checks: \(jobs)\nCached public products: \(products)\nRuntime certified: no\nOwned-PC inventory authorized: no\nNo account identifiers, tokens, URLs or raw engine logs included."
        } catch {
            guard token == generation else { return }
            if await client.descriptorMetricsOptedIn {
                incompleteDescriptorMetrics()
            }
            errorMessage = Self.describe(error)
        }
    }

    private func incompleteDescriptorMetrics() {
        descriptorMetricBaseline = nil
        descriptorMetricCounts = nil
        descriptorMetricIntervalCompleted = false
        descriptorMetricLogger.notice("Descriptor interval incomplete.")
    }

    private func recordDescriptorMetrics(_ counts: ManagementClient.DescriptorMetricCounts) {
        let now = ContinuousClock.now
        descriptorMetricCounts = counts
        descriptorMetricIntervalCompleted = false
        guard let baseline = descriptorMetricBaseline else {
            descriptorMetricBaseline = (counts, now)
            descriptorMetricLogger.notice("Descriptor interval baseline checkpoint=\(counts.checkpoint, privacy: .public).")
            return
        }
        descriptorMetricBaseline = nil
        let elapsed = baseline.instant.duration(to: now)
        guard elapsed <= .seconds(180) else {
            descriptorMetricLogger.notice("Descriptor interval incomplete: boundary exceeds 180 seconds.")
            return
        }
        let milliseconds = elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        descriptorMetricIntervalCompleted = true
        descriptorMetricLogger.notice("""
            Descriptor interval complete start=\(baseline.counts.checkpoint, privacy: .public) \
            end=\(counts.checkpoint, privacy: .public) elapsedMilliseconds=\(milliseconds, privacy: .public) \
            lookups=\(counts.lookups - baseline.counts.lookups, privacy: .public) \
            hits=\(counts.hits - baseline.counts.hits, privacy: .public) \
            forced=\(counts.forced - baseline.counts.forced, privacy: .public) \
            coalesced=\(counts.coalesced - baseline.counts.coalesced, privacy: .public) \
            attempts=\(counts.attempts - baseline.counts.attempts, privacy: .public) \
            terminals=\(counts.terminals - baseline.counts.terminals, privacy: .public) \
            successes=\(counts.successes - baseline.counts.successes, privacy: .public).
            """)
    }

    func chooseDiagnosticDestination() {
        guard diagnosticPreview != nil, !diagnosticSaving, !diagnosticPreviewing else {
            diagnosticExportError = "Preview the current diagnostic summary before saving."
            return
        }
        diagnosticSaved = false
        diagnosticExportError = nil
        let panel = NSSavePanel()
        panel.title = "Save reviewed diagnostic summary"
        panel.nameFieldStringValue = "\(AppBrand.displayName)-diagnostics.txt"
        panel.message = PermissionPrompt.saveMessage
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await saveDiagnosticSummary(to: url) }
    }

    func saveDiagnosticSummary(to destination: URL) async {
        guard let preview = diagnosticPreview, !diagnosticSaving, !diagnosticPreviewing else {
            diagnosticExportError = "Preview the current diagnostic summary before saving."
            return
        }
        diagnosticSaved = false
        diagnosticExportError = nil
        guard destination.isFileURL, destination.host == nil || destination.host == "",
              destination.path.hasPrefix("/"), !destination.hasDirectoryPath else {
            diagnosticExportError = "Choose a local text file for this diagnostic summary."
            return
        }
        diagnosticSaving = true
        defer { diagnosticSaving = false }
        let data = Data(preview.utf8)
        do {
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: destination, options: .atomic)
            }.value
            diagnosticSaved = true
        } catch {
            diagnosticExportError = "The summary could not be saved. Choose a writable destination and try again."
        }
    }

    private var validScope: Bool {
        market.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            && language.range(of: "^[a-z]{2,3}(-[A-Z]{2})?$", options: .regularExpression) != nil
    }

    /// REQ-160: truthful copy for Microsoft rate-limiting this device; never "check your network".
    static func throttledMessage(retryAfterSeconds: Int?) -> String {
        let minutes = max(1, Int((Double(retryAfterSeconds ?? 600) / 60).rounded(.up)))
        return "Microsoft is limiting requests from this Mac. Try again in \(minutes) min."
    }

    /// L15 #12: Xbox sign-in rejected the saved ticket (authExchangeFailed). Retrying won't help; signing in again will.
    static let signInRejectedMessage = "Microsoft didn't accept your saved sign-in. Sign out and sign in again in Account."

    static func describe(_ error: Error) -> String {
        if let paused = error as? MicrosoftReadsPaused { return paused.message }
        if case let ManagementError.authenticatedReadFailed(failure) = error {
            switch failure {
            case .credentialUnavailable: return "Your saved sign-in couldn't be read. Check account status."
            case .profileChanged: return "The account changed while loading. Reload to try again."
            case .authExchangeFailed: return signInRejectedMessage
            case .authRejected: return "Microsoft rejected access to this feature. Check account status before reconnecting."
            case .transportFailed: return "The connection didn't finish. Check your network and try again."
            case .responseInvalid: return "Microsoft returned details that couldn't be read safely. Reload to try again."
            case .packageUnavailable: return "The requested content isn't available."
            case .throttled: return throttledMessage(retryAfterSeconds: nil)
            }
        }
        if case let ManagementError.authenticatedReadThrottled(seconds) = error {
            return throttledMessage(retryAfterSeconds: seconds)
        }
        if case let ManagementError.backendError(code, _) = error {
            switch code {
            case "AUTH_INVALID": return "The saved sign-in could not be validated. Check status before disconnecting and reconnecting it."
            case "AUTH_REQUIRED": return "Sign in with Microsoft before continuing."
            case "AUTH_EXPIRED": return "Your saved sign-in expired. Check status, then disconnect it before signing in again."
            case "CURSOR_INVALID", "REVISION_CONFLICT":
                return "The catalog changed while browsing. Refresh this scope before loading more."
            default: break
            }
        }
        return (error as? ManagementError)?.localizedDescription ?? "The connection could not complete. Reconnect to try again."
    }
}
