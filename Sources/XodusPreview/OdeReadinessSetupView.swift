// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore
import XodusManagement

struct OdeReadinessSetupView: View {
    @ObservedObject var session: LiveSession
    @ObservedObject var state: AppState
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var gptk: GPTKOnboardingController
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

                        // Row 1: Xbox Live Library
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: "books.vertical.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.pcGames.busy
                                     ? "Loading Xbox® Live Library…"
                                     : "\(state.pcGames.representedGames.count) Games in Xbox® Library")
                                    .font(.body.weight(.medium))
                                Text("Discovered from your Microsoft Store account and Game Pass.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if !state.pcGames.busy {
                                Button("Rescan") {
                                    Task { await state.pcGames.loadOnAppear() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

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
                            Text("You need access to an engine for Windows games to run. You can set up multiple engines, but each game runs on one engine at a time (configurable in Settings). Set up at least one engine below to proceed:")
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
                .disabled(!hasAtLeastOneEngine)
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

    private var hasAtLeastOneEngine: Bool {
        runtime.crossOverDependency.isVerified || gptk.isInstalled
    }

    private var footerStatusText: String {
        if runtime.crossOverDependency.isVerified && gptk.isInstalled {
            return "CrossOver and Calimocho are ready. You can choose either in Settings."
        } else if runtime.crossOverDependency.isVerified {
            return "CrossOver 26.3 is ready. You can enter your game library now."
        } else if gptk.isInstalled {
            return "Calimocho is ready with Apple D3DMetal. You can enter your game library now."
        } else {
            return "Set up at least one engine above to enter your game library."
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
                    Text("Third-party paid engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("A popular, well-trusted paid third-party engine by CodeWeavers. Completely standalone with built-in Windows translation and DirectX 12 support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if runtime.crossOverDependency.isVerified {
                Text("Verified")
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
                Image(systemName: gptk.isInstalled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(gptk.isInstalled ? Color.accentColor : Color.secondary)
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
                    Text("Free Wine 11 runtime built from source, included with Ode to X.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Text(gptk.isInstalled ? "Verified" : "Setup Required")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            // Subpart: Apple Game Porting Toolkit (One more remaining step)
            GPTKOnboardingView(controller: gptk, showsHeader: false)
                .padding(.leading, 38)
        }
    }
}
