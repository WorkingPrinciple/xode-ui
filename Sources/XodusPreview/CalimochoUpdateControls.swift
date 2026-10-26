// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct CalimochoUpdateControls: View {
    @ObservedObject var installer: CalimochoReleaseInstallController
    let isBusy: @MainActor @Sendable () -> Bool
    let beginUpdate: @MainActor (LocalCalimochoRelease) -> Void
    let removeOld: @MainActor () -> Void
    @State private var confirmingOldRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let installed = installer.installedReleases.first {
                    Text("Installed Calimocho \(installed.version)")
                } else {
                    Text("Calimocho updates")
                }
                Spacer()
                if installer.checkingUpdates {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking for Calimocho updates")
                }
                Button("Check for Updates") {
                    Task { await installer.checkForUpdates(automatic: false) }
                }
                .disabled(installer.checkingUpdates || installer.isWorking || isBusy())
                .accessibilityIdentifier("xodus.engines.calimocho.checkUpdates")
            }
            if let message = installer.updateMessage {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.engines.calimocho.updateMessage")
            }
            if case .pinnedUpdate(let old) = installer.updateOutcome, !installer.hasEngineFolder {
                Button("Update Calimocho") { beginUpdate(old) }
                    .disabled(installer.isWorking || installer.checkingUpdates || isBusy())
                    .accessibilityIdentifier("xodus.engines.calimocho.update")
            }
            if case .finishUpdate(let old) = installer.updateOutcome {
                Button("Finish Update") { beginUpdate(old) }
                    .disabled(installer.isWorking || installer.checkingUpdates || isBusy())
                    .accessibilityIdentifier("xodus.engines.calimocho.finishUpdate")
            }
            if let url = installer.updateOutcome?.releaseNotes {
                Link("Release Notes", destination: url)
                    .accessibilityIdentifier("xodus.engines.calimocho.releaseNotes")
            }
            if let old = installer.removableOldRelease {
                Button("Move Calimocho \(old.version) to the Trash…", role: .destructive) {
                    confirmingOldRemoval = true
                }
                .disabled(installer.isWorking || isBusy())
                .confirmationDialog("Move the previous Calimocho engine to the Trash?",
                                    isPresented: $confirmingOldRemoval) {
                    Button("Move to Trash", role: .destructive, action: removeOld)
                } message: {
                    Text("Only Calimocho \(old.version) will be removed. Game prefixes and saves won't change.")
                }
            }
        }
    }
}
