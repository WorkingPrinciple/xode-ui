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
            VStack(spacing: 24) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Welcome to X Ode").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(session.accountJourneyMessage)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("xodus.welcome.status")
                if session.connectionTransitioning || session.accountBusy {
                    ProgressView("Checking sign-in").controlSize(.small)
                }
                if operations.hasDownloadStatus {
                    Divider()
                    GameOperationProgressView(operations: operations, privacyRestricted: true)
                        .accessibilityIdentifier("xodus.welcome.operation")
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 32)
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
                    Button("Sign out of Xbox account") { interaction.confirmingSignOut = true }
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
        .confirmationDialog("Sign out of Xbox account on this Mac?", isPresented: $interaction.confirmingSignOut) {
            Button("Sign out of Xbox account", role: .destructive) {
                Task { await state.signOut(session: session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LiveSession.signOutConfirmationMessage)
        }
        .accessibilityIdentifier("xodus.welcome")
    }
}
