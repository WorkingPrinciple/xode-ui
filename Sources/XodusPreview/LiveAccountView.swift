// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore
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
                        OdeMarkTile()
                            .frame(width: 76, height: 76)
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
        .tint(OdeBrand.accent)
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
    enum SettingsTab: String, Hashable, CaseIterable {
        case general = "General"
        case engines = "Engines"
        case account = "Account"
        case advanced = "Advanced"
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openWindow) private var openWindow
    @StateObject private var artwork = AccountInteraction()
    @AppStorage("Xodus.heroAnimationsEnabled") private var heroAnimationsEnabled = true
    @State private var selectedTab: SettingsTab = .engines

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(artwork: artwork, heroAnimationsEnabled: $heroAnimationsEnabled, openWindow: openWindow)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            EnginesSettingsTab(state: state, session: session, dismiss: { dismiss() })
                .tabItem {
                    Label("Engines", systemImage: "cpu")
                }
                .tag(SettingsTab.engines)

            AccountSettingsTab(state: state, session: session)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(SettingsTab.account)

            AdvancedSettingsTab(session: session)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 540, height: 450)
        .navigationTitle(selectedTab.rawValue)
        .task {
            await state.runtimeSettings.refreshCrossOverDependency()
        }
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var artwork: AccountInteraction
    @Binding var heroAnimationsEnabled: Bool
    let openWindow: OpenWindowAction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Game Storage
                VStack(alignment: .leading, spacing: 6) {
                    Text("Game Storage")
                        .font(.headline)
                    GameInstallLocationSettings()
                }

                Divider()

                // Interface & Artwork
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interface & Artwork")
                        .font(.headline)
                    Toggle("Animate featured game artwork", isOn: $heroAnimationsEnabled)
                    Text("Trailers start when you point at the featured artwork and keep playing while it's visible. Reduce Motion uses the poster instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Clear Downloaded Artwork") {
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
                        if artwork.clearingArtwork { ProgressView().controlSize(.small) }
                        if let notice = artwork.artworkNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if let error = artwork.artworkError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }

                Divider()

                // About Ode to X
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Ode to X")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Text("Version 0.2.0 (Build 745)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Licenses") { openWindow(id: "licenses") }
                            .controlSize(.small)
                        Button("Acknowledgments") { openWindow(id: "acknowledgments") }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}

struct EnginesSettingsTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: LiveSession
    let dismiss: () -> Void

    @AppStorage(EngineDefaults.defaultEngineKey) private var defaultProvider = ""
    @AppStorage("Xodus.lifecycle.engine.calimocho") private var calimochoRecord = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Default Execution Engine
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default Execution Engine")
                        .font(.headline)
                    Text("Select which engine runs Windows games by default. You can also override this per-game from each title's menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Picker("Default Engine:", selection: Binding(
                            get: { RuntimeProviderKind(rawValue: defaultProvider) },
                            set: { defaultProvider = $0?.rawValue ?? "" })) {
                            Text("Calimocho (Wine 11) — Free / Open-source").tag(Optional(RuntimeProviderKind.calimocho))
                            if state.runtimeSettings.crossOverDependency.isVerified {
                                Text("CrossOver — Detected").tag(Optional(RuntimeProviderKind.crossover))
                            }
                            Text("No default (Prompt on launch)").tag(Optional<RuntimeProviderKind>.none)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 320)

                        Button("Refresh") {
                            Task { await state.runtimeSettings.refreshCrossOverDependency() }
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                // 2. Installed Engines Overview
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Engines")
                        .font(.headline)

                    // Calimocho Row
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Calimocho 0.6 (Wine 11.20)")
                                    .font(.body.bold())
                                Spacer()
                                Text(state.gptkOnboarding.isInstalled ? "Ready" : "Installed")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text("Free, open-source Windows translation layer built from LGPL source.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)

                    // CrossOver Row
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "app.badge.checkmark")
                            .font(.title2)
                            .foregroundStyle(Color.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("CrossOver")
                                    .font(.body.bold())
                                if case .installed(let app) = state.runtimeSettings.crossOverDependency {
                                    Text("v\(app.version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(state.runtimeSettings.crossOverDependency.isVerified ? "Detected" : "Not Found")
                                    .font(.caption.bold())
                                    .foregroundStyle(state.runtimeSettings.crossOverDependency.isVerified ? .green : .secondary)
                            }
                            HStack {
                                Text(crossOverDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("Locate…") {
                                    chooseCrossOver()
                                }
                                .controlSize(.small)
                                if EngineDefaults.crossOverApplication() != nil {
                                    Button("Reset") {
                                        EngineDefaults.setCrossOverApplication(nil)
                                        Task { await state.runtimeSettings.refreshCrossOverDependency() }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)

                    // Apple Game Porting Toolkit (D3DMetal) Row
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "gamecontroller")
                            .font(.title2)
                            .foregroundStyle(Color.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Apple Game Porting Toolkit (D3DMetal)")
                                    .font(.body.bold())
                                Spacer()
                                Text(state.gptkOnboarding.isInstalled ? "Ready" : "Setup Required")
                                    .font(.caption.bold())
                                    .foregroundStyle(state.gptkOnboarding.isInstalled ? .green : .secondary)
                            }
                            HStack {
                                Text("Apple's Direct3D 12 Metal translation library.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(state.gptkOnboarding.isInstalled ? "Reinstall…" : "Setup…") {
                                    state.gptkOnboarding.isPresented = true
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)
                }

                Divider()

                // 3. Engine Management Actions
                HStack(spacing: 12) {
                    Button("Readiness Checklist…") {
                        dismiss()
                        state.showingSetup = true
                    }
                    Spacer()
                    Button("Advanced Registry…") {
                        state.openAccount(.engines)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private var crossOverDescription: String {
        if case .installed(let app) = state.runtimeSettings.crossOverDependency {
            return app.location.path
        }
        return "Supported commercial engine by CodeWeavers (optional)."
    }

    private func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.title = "Locate CrossOver"
        panel.prompt = "Select CrossOver.app"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            EngineDefaults.setCrossOverApplication(url.path)
            Task {
                await state.runtimeSettings.refreshCrossOverDependency()
            }
        }
    }
}

struct AccountSettingsTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: LiveSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !session.hasConfirmedSignIn {
                    VStack(spacing: 14) {
                        Spacer(minLength: 24)
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            Text("Not Signed In")
                                .font(.title3.bold())
                            Text("Sign in with your Xbox or Microsoft account from the main window to browse your Game Pass library and sync game progress.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                        }

                        Button("Sign In with Xbox Live…") {
                            NSApp.activate(ignoringOtherApps: true)
                            state.openAccount()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .padding(.top, 4)

                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // Signed In Account Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xbox Live Account")
                            .font(.headline)
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.accountJourneyTitle)
                                    .font(.body.bold())
                                Text("Signed In • Connected")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Sign Out") {
                                Task { await state.signOut(session: session) }
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Country / Region
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Store Country & Region")
                            .font(.headline)
                        AccountCountrySettings()
                    }

                    Divider()

                    // Subscriptions & Library
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subscriptions & Library")
                            .font(.headline)
                        GameServiceAccountView(operations: state.gameOperations, library: state.pcGames)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}

struct AdvancedSettingsTab: View {
    @ObservedObject var session: LiveSession
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // App Connection Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backend Engine Connection")
                        .font(.headline)
                    HStack {
                        Text("CLI Executable:")
                            .foregroundStyle(.secondary)
                        Text(session.backendPath.isEmpty ? "Bundled / Default" : URL(fileURLWithPath: session.backendPath).lastPathComponent)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(session.isReady ? "Reconnect" : "Connect") {
                            Task { await session.connect() }
                        }
                        .disabled(session.backendPath.isEmpty || session.connectionTransitioning)
                        .controlSize(.small)
                        if session.isReady {
                            Button("Disconnect") {
                                Task { await session.disconnect() }
                            }
                            .disabled(session.connectionTransitioning)
                            .controlSize(.small)
                        }
                    }
                    if let hello = session.hello {
                        HStack {
                            Text("Engine: \(hello.backendVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Protocol: v1.0")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                // Installation & Diagnostics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installation & Game Inspection")
                        .font(.headline)
                    HStack {
                        Button("Inspect Game Folder…") {
                            session.chooseInstallationFolder()
                        }
                        .disabled(!session.isReady || !session.supports(.inspectInstallation) || session.inspectionBusy)
                        if session.inspectionBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let inspection = session.inspection {
                        Text("Selected: \(URL(fileURLWithPath: inspection.directory).lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Catalog Scope
                VStack(alignment: .leading, spacing: 8) {
                    Text("Store Catalog Scope")
                        .font(.headline)
                    HStack(spacing: 12) {
                        TextField("Market (e.g. US)", text: $session.market)
                            .frame(width: 140)
                        TextField("Language (e.g. en-US)", text: $session.language)
                            .frame(width: 160)
                        Button("Apply") {
                            Task { await session.refreshCatalog(state.query) }
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                // Diagnostics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagnostics")
                        .font(.headline)
                    HStack {
                        Button("Preview Diagnostic Summary…") {
                            Task { await session.previewDiagnostics() }
                        }
                        .controlSize(.small)
                        .disabled(!session.supports(.diagnostics) || session.diagnosticSaving || session.diagnosticPreviewing)
                        .accessibilityIdentifier("xodus.diagnostics.preview")

                        if session.diagnosticPreview != nil {
                            Button("Save Summary…") {
                                session.chooseDiagnosticDestination()
                            }
                            .controlSize(.small)
                            .disabled(session.diagnosticSaving)
                            .accessibilityIdentifier("xodus.diagnostics.save")
                        }
                    }
                    if session.diagnosticPreviewing { ProgressView("Preparing summary").controlSize(.small) }
                    if session.diagnosticSaving { ProgressView("Saving summary").controlSize(.small) }
                    if session.diagnosticSaved {
                        Label("Diagnostic summary saved.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    }
                    if let error = session.diagnosticExportError {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                    if let preview = session.diagnosticPreview {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}
