// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore
import XodusManagement

struct ReadinessLibraryRow: View {
    @ObservedObject var library: PCGamesController

    var statusTitle: String {
        if library.busy || library.restoringPresence { return "Checking your PC library..." }
        let count = library.representedGames.count
        if count == 0 {
            if library.accessIsCurrent { return "No PC games found" }
            return library.accountAccessIsCurrent ? "PC game details unavailable" : "PC library unavailable"
        }
        let noun = count == 1 ? "PC game" : "PC games"
        return library.accountAccessIsCurrent
            ? "\(count.formatted()) \(noun) found"
            : "\(count.formatted()) saved \(noun)"
    }

    var statusDetail: String {
        if library.busy || library.restoringPresence { return "Checking your account's PC games." }
        if library.needsKeychainApproval {
            return "Approve Keychain access in Account settings, then rescan."
        }
        if let error = library.error {
            return library.representedGames.isEmpty
                ? error : "Saved results; current access is not verified. \(error)"
        }
        if !library.hasSavedSignIn || library.needsSignIn {
            return "Check your sign-in in Account settings, then rescan."
        }
        if !library.accountAccessIsCurrent {
            return library.representedGames.isEmpty
                ? "Refresh your PC library to check account access."
                : "Saved results. Current access is not verified."
        }
        if !library.accessIsCurrent {
            return "Some game details are unavailable. Saved items may be included."
        }
        return "Some games may not be included in this library."
    }

    var canRescan: Bool {
        !library.busy && !library.restoringPresence && !library.needsKeychainApproval
            && !library.needsSignIn && !library.accountDisconnecting
    }

    func rescan() {
        Task { await library.retryLibraryLoad() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("xodus.setup.pcLibrary.status")
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()

            Button("Rescan", action: rescan)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRescan)
                .accessibilityIdentifier("xodus.setup.pcLibrary.rescan")
        }
    }
}

struct OdeReadinessSetupView: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var state: AppState
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var gptk: GPTKOnboardingController
    @ObservedObject var calimocho: CalimochoDefaultEngineController
    let onComplete: () -> Void

    private var calimochoVersionLabel: String {
        "Calimocho 0.6 (Wine 11.20)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Apple-style Header
                    HStack(spacing: 16) {
                        OdeMarkTile()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Welcome! Signed In Successfully")
                                .font(.title3.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text("Congratulations, your Xbox® account is connected. Preparing this Mac to work with your games.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                    Divider()

                    // Section 1: Game Library & Storage
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Game Library & Storage")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        ReadinessLibraryRow(library: state.pcGames)

                        // Row 2: Local Scan
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: "internaldrive.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(installed.discoveringMounts
                                     ? "Scanning for Installed Games…"
                                     : "\(installed.games.count) Local Installations Detected")
                                    .font(.body.weight(.medium))
                                Text("Found in your games storage directory.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if !installed.discoveringMounts {
                                Button("Rescan") {
                                    Task {
                                        await installed.discoverNativeInstallations()
                                        await installed.refreshNativeInstallationStatuses()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)

                    Divider()

                    // Section 2: Windows Execution Engines
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Windows Execution Engine")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Ode prepares the published Calimocho engine with its Apple D3DMetal components. CrossOver detection lets you browse and configure external handoffs, but does not enable native Play. Game runtime and account access are checked separately before launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Path 1: CrossOver (Standalone)
                        crossOverCard

                        Divider()

                        // Path 2: Calimocho (Open-Source Engine with Apple D3DMetal subpart)
                        calimochoCard
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Native Pinned Bottom Footer Bar
            HStack(alignment: .center) {
                Text(footerStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Enter Library") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canEnterLibrary)
                .accessibilityIdentifier("xodus.setup.enterLibrary")
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))
            .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await runtime.refreshCrossOverDependency()
            gptk.preflightLocalDetection()
            _ = await session.ensureReady()
            if state.pcGames.representedGames.isEmpty {
                await state.pcGames.loadOnAppear()
            }
            await installed.discoverNativeInstallations()
            await installed.refreshNativeInstallationStatuses()
        }
        .accessibilityIdentifier("xodus.readiness.setup")
    }

    var canEnterLibrary: Bool {
        calimocho.isReady || runtime.crossOverDependency.isVerified || gptk.isInstalled
    }

    var footerStatusText: String {
        if calimocho.isReady {
            return "Calimocho is verified. Game runtime and account access are checked separately."
        } else if gptk.isInstalled {
            return "Apple D3DMetal is detected. You can browse, but Native Play still requires an admitted Calimocho runtime."
        } else if runtime.crossOverDependency.isVerified {
            return "CrossOver is detected. You can browse the Library and configure external handoffs; this does not enable native Play."
        } else {
            return "Complete Calimocho setup below to enter your game library."
        }
    }

    // MARK: - Path 1: CrossOver Card (Standalone)

    @ViewBuilder
    private var crossOverCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: runtime.crossOverDependency.isVerified ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(runtime.crossOverDependency.isVerified ? Color.accentColor : Color.secondary)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("CrossOver 26.3")
                        .font(.body.weight(.medium))
                    Text("Not a native Play provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("CrossOver is a separately installed CodeWeavers app. Detection does not verify its license, enable native Play in Ode to X or satisfy Calimocho setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if runtime.crossOverDependency.isVerified {
                Text("Detected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Link("Get CrossOver", destination: CrossOverDependencyState.trialDownloadURL)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Path 2: Calimocho Card (with Apple Game Porting Toolkit subpart)

    @ViewBuilder
    private var calimochoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Main Calimocho row
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: calimocho.isReady ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(calimocho.isReady ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(calimochoVersionLabel)
                            .font(.body.weight(.medium))
                        Text("Open-source engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("The official release is downloaded separately and verified before use. Game requirements are checked before launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Text(calimocho.isReady ? "Verified" : "Not verified")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            CalimochoPreparationControls(controller: calimocho,
                configuration: session.nativeInstallStatusConfiguration)
                .padding(.leading, 38)

            DisclosureGroup("Separate Apple toolkit setup (optional)") {
                GPTKOnboardingView(controller: gptk, showsHeader: false)
            }
            .padding(.leading, 38)
        }
    }
}
