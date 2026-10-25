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
                    if !session.hasConfirmedSignIn { VStack(spacing: 8) {
                        XOdeLogo().fill(XboxBrand.lightGreen)
                            .frame(width: 48, height: 48).padding(14)
                            .background(Color(red: 12 / 255, green: 40 / 255, blue: 25 / 255),
                                        in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityHidden(true)
                        Text("Ode to X").font(.title2.weight(.medium))
                            .accessibilityLabel("Ode to X")
                            .accessibilityAddTraits(.isHeader)
                    } }
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
            EnginesView()
        }
    }

    private func close() {
        if let onClose { onClose() }
        else { dismiss() }
    }
}

struct LiveSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openWindow) private var openWindow
    @StateObject private var artwork = AccountInteraction()
    @AppStorage("Xodus.heroAnimationsEnabled") private var heroAnimationsEnabled = true

    var body: some View {
        Form {
            Section("Game storage") {
                GameInstallLocationSettings()
            }
            Section("Game runtime") {
                RuntimeInstallationPicker(settings: state.runtimeSettings, backendPath: session.backendPath)
            }

            Section("Account") {
                LabeledContent("Status", value: session.accountJourneyTitle)
                if session.hasConfirmedSignIn { AccountCountrySettings() }
                Button("Open account") { state.openAccount() }
                if session.hasConfirmedSignIn { AccountHubDestinations() }
            }
            if session.hasConfirmedSignIn {
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
            Section("App connection") {
#if XODUS_SHIPPING
                Text("Only this app's approved bundled engine and sign-in helper can be used. Gameplay runtime certification is separate.")
                    .foregroundStyle(.secondary)
#else
                Text("Development integration. Only choose a management engine you trust; signed runtime distribution is not implemented yet.")
                    .foregroundStyle(.secondary)
#endif
                LabeledContent("Build", value: session.backendPath.isEmpty ? "Not selected" : URL(fileURLWithPath: session.backendPath).lastPathComponent)
                HStack {
#if !XODUS_SHIPPING
                    Button("Choose app engine") { session.chooseBackend() }.disabled(session.connectionTransitioning)
#endif
                    Spacer()
                    Button(session.isReady ? "Reconnect" : "Connect") { Task { await session.connect() } }
                        .disabled(session.backendPath.isEmpty || session.connectionTransitioning)
                    if session.isReady {
                        Button("Disconnect") { Task { await session.disconnect() } }
                            .disabled(session.connectionTransitioning)
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
            Section("Engines") {
                Text("Review CrossOver readiness and declared GPTK, Wine and graphics components on the dedicated Engines page.")
                    .foregroundStyle(.secondary)
                Button("Open Engines") { state.openAccount(.engines) }
            }
            Section("Game access") {
                GameServiceAccountView(operations: state.gameOperations, library: state.pcGames)
            }
            Section("Advanced public catalog") {
                Text(session.supports(.query)
                     ? "Discover browses PC Game Pass titles or searches the public Microsoft Store. Neither source is an owned library."
                     : "Discover checks a bounded public PC Game Pass page. This engine searches checked products only, not the whole Store or an owned library.")
                    .foregroundStyle(.secondary)
                if session.hasConfirmedSignIn {
                    LabeledContent("Market", value: session.accountCountryLabel)
                } else {
                    TextField("Market (for example US)", text: $session.market)
                }
                TextField("Language (for example en-US)", text: $session.language)
                Button("Refresh catalog scope") { Task { await session.refreshCatalog(state.query) } }
                    .disabled(!session.isReady || session.searching)
                TextField("Public Store product ID", text: $session.lookupID)
                    .onSubmit { Task { await session.lookupProduct() } }
                HStack {
                    Button("Check public product") { Task { await session.lookupProduct() } }
                        .disabled(!session.supports(.enqueue) || session.lookupBusy)
                    if session.lookupBusy {
                        ProgressView().controlSize(.small).accessibilityLabel("Looking up game details")
                    }
                }
                Text("Checks public metadata only. It does not buy, authorize, download or install a game.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Section("About Ode to X") {
                Button("Licenses") { openWindow(id: "licenses") }
                Button("Acknowledgments") { openWindow(id: "acknowledgments") }
            }
        }
        .formStyle(.grouped).padding()
        .frame(width: 560)
        .task {
            await state.runtimeSettings.refreshCrossOverDependency()
        }
    }
}
