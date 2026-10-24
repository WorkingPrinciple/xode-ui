// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LiveWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 24)
                    VStack(spacing: 16) {
                        XOdeLogo().fill(XboxBrand.green)
                            .frame(width: 112, height: 112).accessibilityHidden(true)
                        Text("Ode to X").font(.largeTitle.weight(.medium))
                            .accessibilityLabel("Ode to X")
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(session.accountJourneyMessage)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("xodus.welcome.status")
                    if session.signInPending {
                        Button("Cancel sign-in") { Task { await state.cancelUnifiedSignIn(session: session) } }
                            .keyboardShortcut(.cancelAction)
                            .disabled(session.accountBusy)
                            .accessibilityIdentifier("xodus.welcome.cancel")
                    } else {
                        Button("Sign in with Xbox Live") {
                            Task {
                                if !session.accountStatusCurrent {
                                    await session.prepareWelcome()
                                }
                                if session.canStartWelcomeSignIn
                                    || (session.needsAccountDisconnect && session.canDisconnectAccount) {
                                    await state.recoverUnifiedSignIn(session: session)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.connectionTransitioning || session.accountBusy || session.hasConfirmedSignIn)
                        .accessibilityIdentifier("xodus.welcome.signIn")
                    }
                    if session.connectionTransitioning || session.accountBusy {
                        OdeLoadingStatus(title: "Checking Xbox Live",
                            message: "If macOS asks for Keychain access, the request is to check or save this Ode to X sign-in.")
                            .frame(maxWidth: 360)
                    }
                    if operations.hasDownloadStatus {
                        GameOperationProgressView(operations: operations, privacyRestricted: true)
                            .accessibilityIdentifier("xodus.welcome.operation")
                    }
                    VStack(spacing: 6) {
                        Text(runtime.crossOverDependency.title)
                            .font(.callout).foregroundStyle(.secondary)
                        if runtime.crossOverDependency.offersTrialDownload {
                            Link("Get the CrossOver trial", destination: CrossOverDependencyState.trialDownloadURL)
                            Text("You can sign in and browse before installing it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 80))
                .padding(40)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 600,
               minHeight: 400, idealHeight: 480, maxHeight: 600)
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .accessibilityIdentifier("xodus.welcome")
    }
}
