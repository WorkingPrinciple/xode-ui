// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct GameSetupBannerView: View {
    @ObservedObject var operations: GameOperationsController
    let openSetup: () -> Void

    var body: some View {
        if operations.setupNeedsAttention {
            HStack(spacing: 14) {
                Label("Xodus needs setup", systemImage: "wrench.and.screwdriver")
                Spacer()
                Button("Setup", action: openSetup)
                    .accessibilityLabel("Open Xodus setup")
                    .accessibilityIdentifier("xodus.setup.open")
            }
        }
    }
}

struct GameSetupView: View {
    @ObservedObject var operations: GameOperationsController
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle { Text("Setup").font(.headline) }
            if operations.setupBusy {
                ProgressView(operations.setupRepairing ? "Repairing Xodus" : "Checking Xodus setup")
                    .controlSize(.small)
            }
            if let result = operations.setupResult {
                ForEach(result.orderedItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.ready ? "Ready" : item.fix ?? "Needs attention")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if !operations.setupBusy && operations.setupError == nil {
                Text("Setup hasn't been checked.").foregroundStyle(.secondary)
            }
            if let error = operations.setupError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.setup.error")
                if operations.setupLog != nil {
                    Button("Show log") { operations.showSetupLog() }
                        .accessibilityIdentifier("xodus.setup.showLog")
                }
            }
            Button("Repair Xodus") { operations.repairSetup() }
                .disabled(!operations.canRepairSetup)
                .accessibilityIdentifier("xodus.setup.repair")
            if operations.setupResult?.needsSignIn == true {
                Button("Sign in for games") { operations.signInForGames() }
                    .disabled(!operations.canSignIn)
                    .accessibilityIdentifier("xodus.setup.signIn")
            }
        }
    }
}
