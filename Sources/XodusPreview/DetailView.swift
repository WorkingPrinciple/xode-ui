// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

struct GameDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var interaction = SheetInteraction()
    let game: Game

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    GameArtwork(kind: game.art)
                    LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(game.title).font(.largeTitle.bold())
                        .foregroundStyle(.white).padding(24)
                }
                .frame(height: 300).clipped()
                .overlay(alignment: .top) {
                    Text("Fixture preview - invented game and evidence")
                        .font(.caption).padding(12).modifier(NativeGlass()).padding(.top, 16)
                        .foregroundStyle(.white).environment(\.colorScheme, .dark)
                }
                VStack(alignment: .leading, spacing: 22) {
                Text(game.summary).foregroundStyle(.secondary)
                Text("Standard edition (fixture)").font(.headline)
                VStack(spacing: 0) {
                    facet("Access", value: game.entitlement.label, symbol: "person.badge.key")
                    Divider()
                    facet("Downloadability", value: game.installability.label, symbol: "arrow.down.circle")
                    Divider()
                    facet("Compatibility", value: "\(game.compatibility.label) (invented evidence)", symbol: "checkmark.shield")
                    Divider()
                    facet("This Mac", value: state.installed.contains(game.id)
                          ? "Installed fixture - no files" : "Not installed", symbol: "desktopcomputer")
                }
                if let reason = state.decision(for: game).reason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Evidence and identities") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.accessEvidence.source)
                        Text("Checked: \(game.accessEvidence.checkedAt.formatted(date: .abbreviated, time: .shortened)) (fixed fixture time)")
                        Text(game.compatibilityEvidence.source)
                        Text("Fingerprint: \(Fixtures.fingerprint.os) / arm64 / \(Fixtures.fingerprint.runtime)")
                        Text("Product: \(game.id)\nEdition: \(game.editionID)\nPackage: \(game.package?.id ?? "Unavailable")")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                HStack {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if state.installed.contains(game.id) {
                        Button("Simulate play") { state.simulateLaunch(game) }
                            .disabled(state.decision(for: game) != .allowed)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Review fixture install") { interaction.showInstall = true }
                            .disabled(state.decision(for: game) != .allowed)
                            .buttonStyle(.borderedProminent)
                    }
                }
                }
                .padding(26)
            }
        }
        .frame(width: 660, height: 760)
        .sheet(isPresented: $interaction.showInstall) { InstallSheet(game: game) }
        .alert("Fixture preview", isPresented: Binding(
            get: { state.message != nil }, set: { if !$0 { state.message = nil } }
        )) {
            Button("OK") { state.message = nil }
        } message: { Text(state.message ?? "") }
    }

    private func facet(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).frame(width: 170, alignment: .leading)
            Text(value).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct InstallSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var interaction = SheetInteraction()
    let game: Game

    private var plan: InstallPlan? {
        game.package.map { InstallPlan(game: game, package: $0, availableBytes: state.availableBytes) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FixtureNotice()
            Text("Review fixture install").font(.title.bold())
            Text("\(game.title) - Standard edition").font(.headline)
            if let plan {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    row("Download", DisplayFormat.bytes(plan.downloadBytes))
                    row("Expanded game", DisplayFormat.bytes(plan.expandedBytes))
                    row("Staging", DisplayFormat.bytes(plan.stagingBytes))
                    row("Safety reserve", DisplayFormat.bytes(plan.reserveBytes))
                    row("Required free", DisplayFormat.bytes(plan.requiredFreeBytes))
                    row("Available (simulated)", DisplayFormat.bytes(plan.availableBytes))
                    row("Destination", plan.destination)
                    row("Language", plan.package.language)
                    row("Runtime pair", plan.runtime.runtime)
                }
                Toggle("Simulate insufficient space", isOn: $state.lowSpace)
                if !plan.hasEnoughSpace {
                    Label("Not enough simulated space. No job will be created.",
                          systemImage: "exclamationmark.triangle")
                }
                if game.compatibility == .experimental {
                    Toggle("I understand this is an experimental fixture, not verified gameplay.",
                           isOn: $interaction.acceptsExperimental)
                }
                Text("No bytes will be downloaded or written. Advance the demo queue manually.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Simulate install") {
                        dismiss()
                        state.enqueue(game)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.hasEnoughSpace || state.decision(for: game) != .allowed
                              || (game.compatibility == .experimental && !interaction.acceptsExperimental))
                }
            } else {
                Label("Fixture package unavailable. No installation plan can be created.",
                      systemImage: "exclamationmark.triangle")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 610)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
