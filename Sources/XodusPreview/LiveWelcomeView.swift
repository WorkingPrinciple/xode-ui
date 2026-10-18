// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LiveWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    @StateObject private var interaction = AccountInteraction()
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        AccountSheetLayout(showsHeader: false) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Welcome to X Ode").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(session.welcomeMessage)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.welcome.status")
                Text("Sign out of X Ode removes this app's game-service, PC-library and launcher sign-in only when each step is confirmed. A matching game runtime is required. Other apps and Microsoft browser sessions are unaffected.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if session.connectionTransitioning || session.accountBusy {
                    ProgressView("Checking sign-in").controlSize(.small)
                }
                if operations.hasDownloadStatus {
                    Divider()
                    GameOperationProgressView(operations: operations, privacyRestricted: true)
                        .accessibilityIdentifier("xodus.welcome.operation")
                }
                if runtime.crossOverDependency.offersTrialDownload {
                    Divider()
                    Text("CrossOver runs Windows games on your Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Download the CrossOver trial",
                         destination: CrossOverDependencyState.trialDownloadURL)
                        .accessibilityIdentifier("xodus.welcome.crossover")
                    Text("Download and install it from CodeWeavers. X Ode checks again when you return.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            AccountActionsLayout(layoutDirection: layoutDirection) {
                if session.signInPending {
                    Button("Cancel sign-in") { Task { await session.cancelSignIn() } }
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.accountBusy)
                        .accessibilityIdentifier("xodus.welcome.cancel")
                } else {
                    Button("Try again") { Task { await session.prepareWelcome() } }
                        .disabled(session.connectionTransitioning || session.accountBusy)
                        .accessibilityIdentifier("xodus.welcome.retry")
                    if session.needsAccountDisconnect {
                        Button("Sign out of X Ode") { interaction.confirmingSignOut = true }
                            .disabled(!state.canSignOut(session: session) || !session.nativeSignInHostAdmitted)
                            .accessibilityIdentifier("xodus.welcome.reconnect")
                    } else {
                        Button("Sign in to X Ode") { Task { await session.beginSignIn() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!session.canStartWelcomeSignIn)
                            .accessibilityIdentifier("xodus.welcome.signIn")
                    }
                }
            }
        }
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .confirmationDialog("Sign out of X Ode on this Mac?", isPresented: $interaction.confirmingSignOut) {
            Button("Sign out of X Ode", role: .destructive) {
                Task { await state.signOut(session: session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("X Ode first signs out its game service, then removes its saved PC-library sign-in and disconnects its launcher profile. If any step fails, some sign-in data may remain and X Ode reports where it stopped. Game files, saves, other apps and Microsoft browser sessions are unchanged.")
        }
        .accessibilityIdentifier("xodus.welcome")
    }
}
