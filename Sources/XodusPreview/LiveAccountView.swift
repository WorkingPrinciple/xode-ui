// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

@MainActor
final class AccountInteraction: ObservableObject {
    @Published var confirmingSignOut = false
    @Published var clearingArtwork = false
    @Published var artworkNotice: String?
    @Published var artworkError: String?
}

struct LiveAccountView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var interaction = AccountInteraction()
    @ObservedObject private var companion = XboxCompanionController.shared
    var onClose: (() -> Void)? = nil
#if !XODUS_SHIPPING
    var refreshStatusOnAppear = true
#endif

    var body: some View {
        AccountSheetLayout(showsHeader: false) {
            EmptyView()
        } content: {
            if state.showingSetup {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Game setup").font(.title2.bold())
                    GameSetupView(operations: state.gameOperations)
                }
            } else if state.accountDestination != .account {
                accountDestination
            } else {
                VStack(spacing: 16) {
                    if !session.hasConfirmedSignIn {
                        XOdeLockup(markSize: 48, markStyle: AnyShapeStyle(XboxBrand.lightGreen),
                                   wordmarkFont: .title2.weight(.medium),
                                   markBackground: AnyShapeStyle(Color(red: 12 / 255, green: 40 / 255, blue: 25 / 255)))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if session.hasConfirmedSignIn {
                        XboxAccountSummaryView(companion: companion)
                        if !state.pcGames.usesUnifiedAccount { GroupBox("Xbox access") {
                            GameServiceSignInActions(operations: state.gameOperations,
                                statusText: state.gameOperations.serviceLabel,
                                statusIdentifier: "xodus.account.gameServiceStatus",
                                checkIdentifier: "xodus.account.checkGameService",
                                signInIdentifier: "xodus.account.signInForGames",
                                errorIdentifier: "xodus.account.gameServiceError",
                                logIdentifier: "xodus.account.gameServiceLog",
                                verifyIdentifier: "xodus.account.verifyGameService",
                                setupRepairing: state.gameOperations.setupRepairing)
                        } }
                    } else {
                        VStack(spacing: 8) {
                            Text("Account").font(.title2.bold())
                                .accessibilityIdentifier("xodus.account.status")
                            Text(session.accountJourneyTitle)
                                .font(.headline).foregroundStyle(.secondary)
                        }
                        if session.accountBusy || session.signInPending {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(session.signInPending ? "Sign-in in progress" : "Checking account status")
                        }
                    Text(session.accountJourneyMessage)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
                        .accessibilityIdentifier("xodus.account.statusExplanation")
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        } actions: {
            if state.showingSetup || state.accountDestination != .account {
                AccountActionsLayout(layoutDirection: layoutDirection) {
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                    Button("Back to Account") {
                        state.showingSetup = false
                        state.accountDestination = .account
                    }
                        .accessibilityIdentifier("xodus.setup.back")
                }
            } else {
                AccountActionsLayout(layoutDirection: layoutDirection) {
                    Button(session.signInPending ? "Cancel sign-in" : "Close") {
                        Task {
                            let cancelling = session.signInPending
                            if cancelling { await state.cancelUnifiedSignIn(session: session) }
                            if !session.signInPending,
                               !cancelling || session.authentication?.flow?.state != .completed { close() }
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .modifier(XboxProminentButton(enabled: session.hasConfirmedSignIn))
                    .disabled(session.signInPending && session.accountBusy)
                    .accessibilityLabel(session.signInPending ? "Cancel sign-in" : "Close account")
                    .accessibilityIdentifier(session.signInPending ? "xodus.account.cancelSignIn" : "xodus.account.close")
                    if session.isReady {
                        Button("Check status") { Task {
                            await session.refreshAccount()
                            if state.pcGames.usesUnifiedAccount, session.hasConfirmedSignIn {
                                await state.pcGames.retryLibraryLoad()
                                await state.pcGames.waitForLoad()
                                await companion.refresh(for: nil, force: true)
                                if session.nativeLifecycleConfiguration == nil { await session.prepareUnifiedRuntime() }
                            }
                        } }
                            .disabled(session.accountBusy)
                            .accessibilityLabel("Check account status")
                            .accessibilityIdentifier("xodus.account.checkStatus")
                    } else { Button("Settings", action: openSettings.callAsFunction) }
                    Button("Sign out of Xbox Live") {
                        interaction.confirmingSignOut = true
                    }
                        .disabled(!state.canSignOut(session: session))
                        .help("Finish any running game, installation or account action before signing out.")
                        .accessibilityIdentifier("xodus.account.signOut")
                }
                .controlSize(.regular)
            }
        }
        .task(id: "\(state.showingSetup):\(state.accountDestination.rawValue)") {
            guard !state.showingSetup else { return }
            if state.pcGames.usesUnifiedAccount {
#if !XODUS_SHIPPING
                guard refreshStatusOnAppear else { return }
#endif
                await state.pcGames.waitForLoad()
                await companion.refresh(for: nil)
                return
            }
            if [.profile, .achievements, .consoles].contains(state.accountDestination) {
                state.gameOperations.refreshService()
                await state.gameOperations.waitForService()
                await companion.refresh(for: state.gameOperations.serviceStatus)
                return
            }
            guard state.accountDestination == .account else { return }
#if !XODUS_SHIPPING
            if !refreshStatusOnAppear { return }
#endif
            await session.refreshAccount()
            if session.hasConfirmedSignIn {
                state.gameOperations.refreshService()
                await state.gameOperations.waitForService()
                if state.gameOperations.gamePassStatus == nil { await state.gameOperations.loadGamePassCache() }
                await companion.refresh(for: state.gameOperations.serviceStatus)
            }
        }
        .tint(XboxBrand.green)
        .interactiveDismissDisabled(session.signInPending)
        .confirmationDialog("Sign out of Xbox Live on this Mac?", isPresented: $interaction.confirmingSignOut) {
            Button("Sign out of Xbox Live", role: .destructive) { Task { await state.signOut(session: session) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LiveSession.signOutConfirmationMessage)
        }
    }

    @ViewBuilder private var accountDestination: some View {
        switch state.accountDestination {
        case .account:
            EmptyView()
        case .profile:
            XboxProfileView(companion: companion)
        case .achievements:
            XboxAchievementsView(companion: companion, status: state.gameOperations.serviceStatus)
        case .consoles:
            XboxConsolesView(companion: companion)
        case .engines:
            Button("Open Engines Settings") {
                SettingsPaneSelection.select(.engines)
                state.showingAccount = false
                openSettings()
            }
        }
    }

    private func close() {
        if let onClose { onClose() }
        else { dismiss() }
    }
}

struct LiveSettingsView: View {
    let allowsUpdateChecks: Bool
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openWindow) private var openWindow
    @StateObject private var artwork = AccountInteraction()
    @StateObject private var engineObservation = EngineRegistryObservation()
    @StateObject private var engineModel: UserEngineModel
    @AppStorage("Xodus.heroAnimationsEnabled") private var heroAnimationsEnabled = true
    @AppStorage(SettingsPane.preferenceKey) private var storedSelectedPane = SettingsPane.general.rawValue

    init(engineModel: UserEngineModel? = nil, allowsUpdateChecks: Bool = true) {
        self.allowsUpdateChecks = allowsUpdateChecks
        _engineModel = StateObject(wrappedValue: engineModel ?? UserEngineModel())
    }

    var body: some View {
        // Inside the Settings scene, TabView becomes the standard toolbar-tab preferences window.
        TabView(selection: selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                paneContent(pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
                    .accessibilityIdentifier("xodus.settings.\(pane.rawValue)")
            }
        }
        .accessibilityIdentifier("xodus.settings.pane")
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 640)
        .task {
            await state.runtimeSettings.refreshCrossOverDependency()
        }
    }

    private var selectedPane: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: storedSelectedPane) ?? .general },
            set: { storedSelectedPane = $0.rawValue }
        )
    }

    @ViewBuilder private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: generalPane
        case .engines: enginesPane
        case .account: accountPane
        case .advanced: advancedPane
        }
    }

    private var generalPane: some View {
        Form {
            Section("Game storage") {
                GameInstallLocationSettings()
            }
            PrivacyPermissionsSection()
            Section("Artwork") {
                Toggle("Animate featured game artwork", isOn: $heroAnimationsEnabled)
                Text("Trailers start when you point at the featured artwork and keep playing while it's visible. Use the speaker button to unmute. Reduce Motion and Low Power Mode use the poster instead.")
                    .foregroundStyle(.secondary)
                Button("Clear downloaded artwork") {
                    artwork.clearingArtwork = true
                    artwork.artworkNotice = nil
                    artwork.artworkError = nil
                    TrailerCache.shared.clear()
                    Task {
                        do {
                            try await CatalogArtworkStore.shared.clearCache()
                            artwork.artworkNotice = "Downloaded artwork cleared."
                        } catch {
                            artwork.artworkError = "Artwork couldn't be cleared. Try again."
                        }
                        artwork.clearingArtwork = false
                    }
                }
                .disabled(artwork.clearingArtwork)
                if artwork.clearingArtwork { ProgressView("Clearing downloaded artwork") }
                if let notice = artwork.artworkNotice { Text(notice).foregroundStyle(.secondary) }
                if let error = artwork.artworkError { Text(error).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var enginesPane: some View {
        Form {
            RuntimeInstallationPicker(settings: state.runtimeSettings, backendPath: session.backendPath,
                installed: state.installedGames, embeddedInSettings: true, showsAdvanced: false,
                registryObservation: engineObservation, userEngineModel: engineModel,
                operations: state.gameOperations, calimochoInstaller: state.calimochoInstaller,
                checkUpdatesOnOpen: allowsUpdateChecks && storedSelectedPane == SettingsPane.engines.rawValue)
        }
        .formStyle(.grouped)
    }

    private var accountPane: some View {
        Form {
            Section("\(AppBrand.displayName) account") {
                LabeledContent("Status", value: session.accountJourneyTitle)
                Button("Open account") { state.openAccount() }
                if session.hasConfirmedSignIn { AccountHubDestinations() }
            }
            Section("Account country") {
                AccountCountrySettings()
            }
            Section("Game access") {
                GameServiceAccountView(operations: state.gameOperations, library: state.pcGames,
                                       onOpenOdeAccount: { state.openAccount() })
            }
            Section("Local consoles") {
                LocalConsoleDiscoverySettings()
            }
            Section("Sign-in support") {
                Text(session.accountMessage).foregroundStyle(.secondary)
                if let error = session.accountError {
                    Text(error).textSelection(.enabled)
                        .accessibilityIdentifier("xodus.account.error")
                }
                if let summary = session.accountFailureSummary {
                    Text(summary).textSelection(.enabled)
                        .accessibilityIdentifier("xodus.account.failureSummary")
                }
                if let details = session.accountFailureDetails {
                    Text(details).textSelection(.enabled)
                        .accessibilityIdentifier("xodus.account.failureDetails")
                }
                if let observation = session.accountFailureObservation {
                    Text(observation).textSelection(.enabled)
                        .accessibilityIdentifier("xodus.account.failureObservation")
                }
                Text(session.accountExplanation).foregroundStyle(.secondary)
                Text("If macOS asks for permission to read a saved sign-in, respond in that window. Checking a saved sign-in doesn't start a new Microsoft login.")
                    .foregroundStyle(.secondary)
                Button("Check status") { Task { await session.prepareWelcome() } }
                    .disabled(session.connectionTransitioning || session.accountBusy)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section("App connection") {
#if XODUS_SHIPPING
                Text("Only this app's approved bundled engine and sign-in helper can be used. Gameplay runtime certification is separate.")
                    .foregroundStyle(.secondary)
#else
                Text("Development integration. Only choose a management engine you trust; signed runtime distribution is not implemented yet.")
                    .foregroundStyle(.secondary)
#endif
                LabeledContent("Build", value: session.backendPath.isEmpty ? "Not selected" : URL(fileURLWithPath: session.backendPath).lastPathComponent)
#if !XODUS_SHIPPING
                Button("Choose app engine") { session.chooseBackend() }
                    .disabled(session.connectionTransitioning)
#endif
                HStack {
                    Button(session.isReady ? "Reconnect" : "Connect") { Task { await session.connect() } }
                        .disabled(session.backendPath.isEmpty || session.connectionTransitioning)
                    if session.isReady {
                        Button("Disconnect app connection") { Task { await session.disconnect() } }
                            .disabled(session.connectionTransitioning)
                            .help("Stops the app engine connection and clears current session data. This does not sign out of Microsoft or Xbox.")
                    }
                }
                if let hello = session.hello {
                    LabeledContent("Management", value: "1.0")
                    LabeledContent("Backend", value: hello.backendVersion)
                    LabeledContent("Runtime", value: "Not certified for gameplay")
                }
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            Section("Installation tools") {
                Button("Inspect a game folder") { session.chooseInstallationFolder() }
                    .disabled(!session.isReady || !session.supports(.inspectInstallation) || session.inspectionBusy)
                if session.inspectionBusy { ProgressView("Inspecting installation").controlSize(.small) }
                if let inspection = session.inspection {
                    LabeledContent("Selected folder",
                        value: URL(fileURLWithPath: inspection.directory).lastPathComponent)
                    Text("An installation marker was found. This inspection does not verify ownership, full file integrity or compatibility, and does not import or launch the game.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = session.inspectionError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            Section("Public catalog") {
                Text("Edits apply to the next explicit catalog action; there is no separate Save step.")
                    .font(.callout).foregroundStyle(.secondary)
                if session.hasConfirmedSignIn {
                    LabeledContent("Market", value: session.accountCountryLabel)
                } else {
                    TextField("Market (for example US)", text: $session.market)
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Language (for example en-US)", text: $session.language)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh catalog scope") { Task { await session.refreshCatalog(state.query) } }
                    .disabled(!session.isReady || session.searching)
                TextField("Public Store product ID", text: $session.lookupID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await session.lookupProduct() } }
                HStack {
                    Button("Check public product") { Task { await session.lookupProduct() } }
                        .disabled(!session.supports(.enqueue) || session.lookupBusy)
                    if session.lookupBusy {
                        ProgressView().controlSize(.small).accessibilityLabel("Looking up game details")
                    }
                }
            }
            Section("Engine registry and technical artifacts") {
                NativeEngineSettings(allowsFileReads: !state.runtimeSettings.applicationTerminating,
                    backendPath: session.backendPath, observation: engineObservation)
            }
            Section("Diagnostics") {
                DisclosureGroup("Sign-in and game connection") {
                    LabeledContent("Xbox Live", value: session.hasConfirmedSignIn ? "Signed in" : "Not signed in")
                    LabeledContent("Game connection", value: session.nativeLifecycleConfiguration != nil
                        ? "Private per launch" : session.accountRuntimeReady ? "Connected"
                        : session.accountRuntimeStarting ? "Connecting" : "Not connected")
                    if let error = session.accountRuntimeError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Preview redacted diagnostic summary") { Task { await session.previewDiagnostics() } }
                    .disabled(!session.supports(.diagnostics) || session.diagnosticSaving || session.diagnosticPreviewing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview redacted diagnostic summary")
                    .accessibilityIdentifier("xodus.diagnostics.preview")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { Task { await session.previewDiagnostics() } }
                if let preview = session.diagnosticPreview {
                    Text(preview).font(.callout).textSelection(.enabled)
                    Button("Save reviewed summary...") { session.chooseDiagnosticDestination() }
                        .disabled(session.diagnosticSaving)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Save reviewed diagnostic summary")
                        .accessibilityIdentifier("xodus.diagnostics.save")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { session.chooseDiagnosticDestination() }
                    Text("Only the summary shown above is saved, not raw engine logs or account data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if session.diagnosticPreviewing { ProgressView("Preparing summary") }
                if session.diagnosticSaving { ProgressView("Saving summary") }
                if session.diagnosticSaved {
                    Label("Diagnostic summary saved.", systemImage: "checkmark.circle")
                }
                if let error = session.diagnosticExportError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            Section("About \(AppBrand.displayName)") {
                LabeledContent("Version", value: AppBrand.versionLabel)
                if let build = AppBrand.current.build { LabeledContent("Build", value: build) }
                Text(AppBrand.copyright).foregroundStyle(.secondary)
                Button("Licenses") { openWindow(id: "licenses") }
                Button("Acknowledgments") { openWindow(id: "acknowledgments") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocalConsoleDiscoverySettings: View {
    @ObservedObject private var discovery = LocalNetworkDiscovery.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check for Xbox consoles on your local network. This doesn't confirm account access.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Discovery") {
                Button("Find consoles") { discovery.search() }
                    .accessibilityIdentifier("xodus.localNetwork.discover")
            }
            Text(discovery.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if discovery.denied { OpenPrivacySettingsButton(permission: .localNetwork) }
        }
    }
}
