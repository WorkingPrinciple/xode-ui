// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LiveWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            VStack(spacing: 16) {
                XOdeLoginLogo().fill(XboxBrand.green)
                    .frame(width: 112, height: 112).accessibilityHidden(true)
                Text("Ode").font(.largeTitle.weight(.medium))
                    .accessibilityLabel("X Ode")
                    .accessibilityAddTraits(.isHeader)
            }
            if session.phase == .failed || session.accountError != nil
                || session.needsAccountDisconnect || session.signInPending {
                Text(session.accountJourneyMessage)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("xodus.welcome.status")
            }
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
                ProgressView("Checking Xbox Live").controlSize(.small)
            }
            if operations.hasDownloadStatus {
                GameOperationProgressView(operations: operations, privacyRestricted: true)
                    .accessibilityIdentifier("xodus.welcome.operation")
            }
            Spacer(minLength: 24)
        }
        .padding(40)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 600,
               minHeight: 400, idealHeight: 480, maxHeight: 600)
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .accessibilityIdentifier("xodus.welcome")
    }
}

// Vector rendering of the standalone X in the original sphereless logo proposal.
private struct XOdeLoginLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var mark = Path()
        mark.move(to: CGPoint(x: 7, y: 7))
        mark.addCurve(to: CGPoint(x: 106, y: 65), control1: CGPoint(x: 0, y: -4),
                      control2: CGPoint(x: 80, y: 20))
        mark.addCurve(to: CGPoint(x: 150, y: 100), control1: CGPoint(x: 117, y: 85),
                      control2: CGPoint(x: 131, y: 93))
        mark.addLine(to: CGPoint(x: 211, y: 189))
        mark.addQuadCurve(to: CGPoint(x: 199, y: 197), control: CGPoint(x: 222, y: 207))
        mark.addLine(to: CGPoint(x: 109, y: 130))
        mark.addLine(to: CGPoint(x: 18, y: 196))
        mark.addQuadCurve(to: CGPoint(x: 9, y: 190), control: CGPoint(x: 0, y: 208))
        mark.addLine(to: CGPoint(x: 61, y: 111))
        mark.addCurve(to: CGPoint(x: 59, y: 77), control1: CGPoint(x: 76, y: 91),
                      control2: CGPoint(x: 64, y: 88))
        mark.addLine(to: CGPoint(x: 7, y: 7))
        mark.closeSubpath()
        mark.move(to: CGPoint(x: 114, y: 52))
        mark.addCurve(to: CGPoint(x: 201, y: 8), control1: CGPoint(x: 139, y: 31),
                      control2: CGPoint(x: 171, y: 13))
        mark.addQuadCurve(to: CGPoint(x: 210, y: 15), control: CGPoint(x: 217, y: 2))
        mark.addLine(to: CGPoint(x: 152, y: 92))
        mark.addCurve(to: CGPoint(x: 114, y: 52), control1: CGPoint(x: 132, y: 86),
                      control2: CGPoint(x: 120, y: 71))
        mark.closeSubpath()
        let scale = min(rect.width / 220, rect.height / 210)
        return mark.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 110 * scale,
                                           y: rect.midY - 105 * scale)))
    }
}
