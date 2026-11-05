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
    @ObservedObject var calimocho: CalimochoEngineController
    let onComplete: () -> Void

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
                            Text("Download, verify and choose your Windows game engine in Settings > Engines. Each game keeps its own engine choice; game qualification is separate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        LabeledContent("Calimocho", value: calimocho.state.label)
                        LabeledContent("CrossOver", value: runtime.crossOverDependency.isVerified ? "Detected" : "Not verified")
                        EngineSettingsButton(state: state)
                            .accessibilityIdentifier("xodus.setup.enginesSettings")
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
        runtime.crossOverDependency.isVerified || calimocho.isVerified
    }

    private var footerStatusText: String {
        if runtime.crossOverDependency.isVerified && calimocho.isVerified {
            return "Calimocho is verified and CrossOver is detected. Choose your default in Settings."
        } else if runtime.crossOverDependency.isVerified {
            return "CrossOver is detected. You can enter your game library now."
        } else if calimocho.isVerified {
            return "Calimocho artifact verified. Game qualification is separate."
        } else {
            return "Set up an engine in Settings to enter your game library."
        }
    }

}
