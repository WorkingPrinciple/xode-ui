// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LiveWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
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
                    ProgressView("Checking Xbox Live").controlSize(.small)
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
                    Button("Cancel sign-in") { Task { await state.cancelUnifiedSignIn(session: session) } }
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.accountBusy)
                        .accessibilityIdentifier("xodus.welcome.cancel")
                } else if session.connectionTransitioning || session.accountBusy {
                    Button("Checking Xbox Live") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .accessibilityIdentifier("xodus.welcome.checking")
                } else if session.needsAccountDisconnect || session.canStartWelcomeSignIn {
                    Button("Sign in with Xbox Live") {
                        Task { await state.recoverUnifiedSignIn(session: session) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("xodus.welcome.signIn")
                } else {
                    Button("Try again") { Task { await session.prepareWelcome() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("xodus.welcome.retry")
                }
            }
        }
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .accessibilityIdentifier("xodus.welcome")
    }
}
