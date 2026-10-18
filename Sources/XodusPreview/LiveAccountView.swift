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
#if !XODUS_SHIPPING
    var refreshStatusOnAppear = true
#endif

    var body: some View {
        AccountSheetLayout(showsHeader: false) {
            EmptyView()
        } content: {
            if state.showingSetup {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Xodus setup").font(.title2.bold())
                    GameSetupView(operations: state.gameOperations)
                }
            } else if state.accountDestination != .account {
                accountDestination
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle").font(.largeTitle).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("X Ode account").font(.title2.bold())
                                .accessibilityIdentifier("xodus.account.status")
                            Text(session.hasConfirmedSignIn ? "Signed in to X Ode" : session.accountNoticeTitle)
                                .font(.headline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.accountBusy || session.signInPending {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(session.signInPending ? "Sign-in in progress" : "Checking account status")
                        }
                    }
                    Text(session.accountMessage)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("xodus.account.statusExplanation")
                    GroupBox("Xbox game-service account") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(state.gameOperations.serviceLabel,
                                  systemImage: state.gameOperations.serviceAccountSymbol)
                            Text("Gameplay, Profile, Achievements and My Consoles use this Xbox account. \(XboxCompanionCopy.accountScope)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    AccountHubDestinations()
                    GameServiceAccountView(operations: state.gameOperations, library: state.pcGames)
                    GroupBox("Downloaded artwork") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Xodus keeps a bounded cache of public covers, screenshots and the last \(TrailerCache.limit) trailers you've watched.")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Clear artwork cache") {
                                    interaction.clearingArtwork = true
                                    interaction.artworkNotice = nil
                                    interaction.artworkError = nil
                                    TrailerCache.shared.clear()
                                    Task {
                                        do {
                                            try await CatalogArtworkStore.shared.clearCache()
                                            interaction.artworkNotice = "Downloaded artwork cleared."
                                        } catch {
                                            interaction.artworkError = "Artwork couldn't be cleared. Try again."
                                        }
                                        interaction.clearingArtwork = false
                                    }
                                }
                                .disabled(interaction.clearingArtwork)
                                if interaction.clearingArtwork {
                                    ProgressView().controlSize(.small).accessibilityLabel("Clearing downloaded artwork")
                                }
                            }
                            if let notice = interaction.artworkNotice {
                                Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            }
                            if let error = interaction.artworkError {
                                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                    Divider()
                    if let error = session.accountError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("xodus.account.error")
                    }
                    if let summary = session.accountFailureSummary {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Last sign-in error").font(.headline)
                            Text(summary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("xodus.account.failureSummary")
                        }
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let details = session.accountFailureDetails {
                        DisclosureGroup("Sign-in details") {
                            Text(details).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("xodus.account.failureDetails")
                            if let observation = session.accountFailureObservation {
                                Text(observation).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("xodus.account.failureObservation")
                            }
                        }
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if session.isReady && !session.supports(.authBegin) {
                        Text("Sign-in isn't available in this build.").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Account info") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(session.accountExplanation)
                            Text("Credentials stay in the native Keychain.")
                            Text("macOS may ask for Keychain access again after an app update. Respond in its permission window; a new Microsoft sign-in is not required to check saved sign-in.")
                        }
                        .foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } actions: {
            if state.showingSetup || state.accountDestination != .account {
                AccountActionsLayout(layoutDirection: layoutDirection) {
                    Button("Close", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
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
                            if cancelling { await session.cancelSignIn() }
                            if !session.signInPending,
                               !cancelling || session.authentication?.flow?.state != .completed { dismiss() }
                        }
                    }
                    .keyboardShortcut(.cancelAction).disabled(session.accountBusy)
                    .accessibilityLabel(session.signInPending ? "Cancel sign-in" : "Close account")
                    .accessibilityIdentifier(session.signInPending ? "xodus.account.cancelSignIn" : "xodus.account.close")
                    if session.isReady {
                        Button("Check status") { Task { await session.refreshAccount() } }
                            .disabled(session.accountBusy)
                            .accessibilityLabel("Check account status")
                            .accessibilityIdentifier("xodus.account.checkStatus")
                    } else { Button("Settings", action: openSettings.callAsFunction) }
                    if session.needsAccountDisconnect {
                        Button("Sign out of X Ode") {
                            interaction.confirmingSignOut = true
                        }
                            .disabled(!state.canSignOut(session: session))
                            .help("Finish any running game, installation or account action before signing out.")
                            .accessibilityIdentifier("xodus.account.signOut")
                    } else {
                        Button("Sign in to X Ode") { Task { await session.beginSignIn() } }
                            .disabled(!session.canSignIn)
                            .accessibilityIdentifier("xodus.account.signIn")
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.regular)
            }
        }
        .task(id: "\(state.showingSetup):\(state.accountDestination.rawValue)") {
            guard !state.showingSetup else { return }
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
        }
        .interactiveDismissDisabled(session.accountBusy || session.signInPending)
        .confirmationDialog("Sign out of X Ode on this Mac?", isPresented: $interaction.confirmingSignOut) {
            Button("Sign out of X Ode", role: .destructive) { Task { await state.signOut(session: session) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("X Ode first signs out its game service, then removes its saved PC-library sign-in and disconnects its launcher profile. If any step fails, some sign-in data may remain and X Ode reports where it stopped. Game files, saves, other apps and Microsoft browser sessions are unchanged.")
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
}

struct LiveSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @AppStorage("Xodus.heroAnimationsEnabled") private var heroAnimationsEnabled = true

    var body: some View {
        Form {
            Section("Artwork") {
                Toggle("Animate featured game artwork", isOn: $heroAnimationsEnabled)
                Text("Trailers start when you point at the featured artwork and keep playing while it's visible. Use the speaker button to unmute. Reduce Motion and Low Power Mode use the poster instead.")
                    .foregroundStyle(.secondary)
            }
            Section("Xodus engine") {
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
                    Button("Choose Xodus build") { session.chooseBackend() }.disabled(session.connectionTransitioning)
#endif
                    Spacer()
                    Button(session.isReady ? "Reconnect" : "Connect") { Task { await session.connect() } }
                        .disabled(session.backendPath.isEmpty || session.connectionTransitioning)
                    if session.isReady {
                        Button("Disconnect") { Task { await session.disconnect() } }
                            .disabled(session.connectionTransitioning)
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
            Section("Account") {
                GameServiceAccountView(operations: state.gameOperations, library: state.pcGames)
                LabeledContent("Status", value: session.accountLabel)
                Button("Open account") { state.showingAccount = true }
                DisclosureGroup("Account info") { Text(session.accountExplanation).foregroundStyle(.secondary) }
            }
            Section("Advanced public catalog") {
                Text(session.supports(.query)
                     ? "Discover browses PC Game Pass titles or searches the public Microsoft Store. Neither source is an owned library."
                     : "Discover checks a bounded public PC Game Pass page. This engine searches checked products only, not the whole Store or an owned library.")
                    .foregroundStyle(.secondary)
                TextField("Market (for example US)", text: $session.market)
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
        .formStyle(.grouped).padding()
        .frame(width: 560)
        .task { await state.runtimeSettings.refreshCrossOverDependency() }
    }
}
