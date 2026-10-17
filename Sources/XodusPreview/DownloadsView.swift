// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

struct DownloadsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Downloads").font(.largeTitle.bold())
                Text("Simulated queue. Progress changes only when you advance a step; nothing is downloaded.")
                    .foregroundStyle(.secondary)
                if state.jobs.isEmpty {
                    ContentUnavailableView("Your demo queue is clear", systemImage: "arrow.down.circle",
                                           description: Text("Review a fixture installation from the Library to add a simulated job."))
                        .frame(minHeight: 320)
                }
                ForEach(state.jobs) { job in
                    if let game = Fixtures.games.first(where: { $0.id == job.gameID }) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 18) {
                                GameArtwork(kind: game.art)
                                    .frame(width: 96, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(game.title).font(.title3.bold())
                                    Text("\(job.phase.label) - simulated").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Int(job.phase.progress * 100))%").monospacedDigit()
                            }
                            ProgressView(value: job.phase.progress)
                                .accessibilityLabel("\(game.title) simulated progress")
                            if job.phase == .failed {
                                Label("Simulated NETWORK_UNAVAILABLE. Retry is safe; no files exist.",
                                      systemImage: "exclamationmark.triangle")
                            }
                            HStack {
                                if !job.phase.isTerminal {
                                    Button("Simulate next step") { state.updateJob(job.id) { $0.advance() } }
                                        .disabled(job.phase == .paused)
                                    if job.phase == .downloading || job.phase == .paused {
                                        Button(job.phase == .paused ? "Simulate resume" : "Simulate pause") {
                                            state.updateJob(job.id) { $0.togglePause() }
                                        }
                                    }
                                    Button("Simulate cancel", role: .destructive) {
                                        state.updateJob(job.id) { $0.cancel() }
                                    }
                                    Button("Simulate error") { state.updateJob(job.id) { $0.fail() } }
                                } else if job.phase == .failed {
                                    Button("Simulate retry") { state.updateJob(job.id) { $0.retry() } }
                                } else if job.phase == .completed {
                                    Button("Simulate play") { state.simulateLaunch(game) }
                                } else {
                                    Text("Cancelled fixture. No game or save files were changed.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .controlSize(.small)
                            Divider().padding(.top, 12)
                        }
                    }
                }
                Text("Demo queue resets on relaunch. Durable recovery belongs to the future backend contract.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var interaction = SheetInteraction()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FixtureNotice()
            GameArtwork(kind: "harbor").frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Your games. A more native way home.").font(.title.bold())
            Text("The proposed app connects legitimate PC access to a carefully paired Xodus runtime. This preview uses invented games and never opens Microsoft sign-in.")
                .foregroundStyle(.secondary)
            if interaction.cancelled {
                Label("Simulated sign-in cancelled. No credentials were created.",
                      systemImage: "person.crop.circle.badge.xmark")
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Simulate auth cancellation") {
                    state.connected = false
                    interaction.cancelled = true
                }
                Spacer()
                Button("Simulate connection") {
                    state.connected = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 650)
    }
}

struct PreviewSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Fixture mode") {
                Text("English-only, offline preview. No account, game files or runtime are connected.")
                    .foregroundStyle(.secondary)
                Picker("Inventory scenario", selection: $state.inventory) {
                    ForEach(InventoryState.allCases, id: \.self) { state in
                        Text(state.label).tag(state)
                    }
                }
                Toggle("Connected fixture account", isOn: $state.connected)
                Toggle("Simulate insufficient space", isOn: $state.lowSpace)
                Button("Reset fixture state") { state.reset() }
            }
            RuntimeProviderSection(settings: state.runtimeSettings, backendPath: "", allowsInstallationCheck: false)
            Section("Storage and runtime") {
                Text("Demo storage / Games (not written)")
                Text("Runtime pair: fixture-xodus-pair-1 (not downloaded)")
                    .foregroundStyle(.secondary)
            }
            Section("Advanced diagnostics") {
                Text("No real diagnostics are collected. Future exports require redaction and preview before sharing.")
                    .foregroundStyle(.secondary)
                Button("Show fixture diagnostic") {
                    state.message = "FIXTURE_MODE: no network, tokens, package IO, registry or runtime process."
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Fixture diagnostic", isPresented: Binding(
            get: { state.message != nil }, set: { if !$0 { state.message = nil } }
        )) {
            Button("OK") { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
}
