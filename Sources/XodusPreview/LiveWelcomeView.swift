// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LiveWelcomeView: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
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
                if session.connectionTransitioning || session.accountBusy {
                    ProgressView("Checking sign-in").controlSize(.small)
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
                        Button("Reconnect sign-in") { interaction.confirmingSignOut = true }
                            .disabled(!session.canDisconnectAccount || !session.nativeSignInHostAdmitted)
                            .accessibilityIdentifier("xodus.welcome.reconnect")
                    } else {
                        Button("Sign in with Microsoft") { Task { await session.beginSignIn() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!session.canStartWelcomeSignIn)
                            .accessibilityIdentifier("xodus.welcome.signIn")
                    }
                }
            }
        }
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .confirmationDialog("Reconnect your X Ode sign-in?", isPresented: $interaction.confirmingSignOut) {
            Button("Disconnect saved sign-in", role: .destructive) {
                Task { await session.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this app's launcher sign-in is disconnected. Game files, saves and other accounts are kept. Then choose Sign in with Microsoft.")
        }
        .accessibilityIdentifier("xodus.welcome")
    }
}
