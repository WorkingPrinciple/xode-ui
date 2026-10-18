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
                Text(session.accountJourneyMessage)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.welcome.status")
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
                DisclosureGroup("Technical details") {
                    Text(session.welcomeMessage)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sign-out removes X Ode's game, library and app sign-ins only after each removal is confirmed. It requires a compatible game runtime.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        } actions: {
            AccountActionsLayout(layoutDirection: layoutDirection) {
                if session.signInPending {
                    Button("Cancel sign-in") { Task { await session.cancelSignIn() } }
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.accountBusy)
                        .accessibilityIdentifier("xodus.welcome.cancel")
                } else {
                    Button("Check status") { Task { await session.prepareWelcome() } }
                        .disabled(session.connectionTransitioning || session.accountBusy)
                        .accessibilityIdentifier("xodus.welcome.retry")
                    Button("Sign out of X Ode") { interaction.confirmingSignOut = true }
                        .disabled(!state.canSignOut(session: session))
                        .accessibilityIdentifier("xodus.welcome.reconnect")
                    if !session.needsAccountDisconnect {
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
            Text(LiveSession.signOutConfirmationMessage)
        }
        .accessibilityIdentifier("xodus.welcome")
    }
}
