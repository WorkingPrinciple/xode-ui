// SPDX-License-Identifier: GPL-3.0-only
import Network
import SwiftUI
import XodusManagement

/// Network and power conditions for the quiet once-a-day check. Nothing here sends a request.
@MainActor
final class AppUpdateConditionsMonitor {
    private let monitor = NWPathMonitor()
    private var path: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.path = path }
        }
        monitor.start(queue: DispatchQueue(label: "xodus.update.path"))
    }

    deinit { monitor.cancel() }

    var conditions: AppUpdateConditions {
        AppUpdateConditions(online: path.map { $0.status == .satisfied } ?? true,
                            lowDataMode: path?.isConstrained ?? false,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Toolbar item beside the account avatar. Absent unless an update is available, downloading, ready or waiting.
struct AppUpdateToolbarIndicator: View {
    @ObservedObject var updates: AppUpdateController
    var open: () -> Void

    var body: some View {
        if let indicator = updates.indicator {
            Button(indicator.label, systemImage: indicator.symbol, action: open)
            .labelStyle(.iconOnly)
            .modifier(NativeToolbarIconStyle())
            .help(indicator.label)
            .accessibilityLabel(indicator.label)
            .accessibilityValue(indicator.value)
            .accessibilityIdentifier("xodus.update.indicator")
        }
    }
}

struct AppUpdateSettingsSection: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.autoCheck }, set: { updates.autoCheck = $0 }))
                .disabled(!updates.isConfigured)
                .accessibilityIdentifier("xodus.update.autoCheck")
            LabeledContent("Status") {
                Text(updates.statusText).foregroundStyle(.secondary)
                    .accessibilityIdentifier("xodus.update.status")
            }
            if let failure = updates.manualFailure {
                Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.update.failure")
            }
            HStack {
                Button("Check Now") { Task { await updates.checkNow() } }
                    .disabled(!updates.isConfigured || updates.state == .checking)
                    .accessibilityIdentifier("xodus.update.checkNow")
                if updates.canSkipOrRemind {
                    Button("Remind Me Later") { updates.remindMeLater() }
                        .accessibilityIdentifier("xodus.update.remindLater")
                    Button("Skip This Version") { updates.skipThisVersion() }
                        .accessibilityIdentifier("xodus.update.skip")
                }
            }
            Text(updates.isConfigured
                 ? "Checks run at most once a day, never during a game or install, and skip Low Data Mode and Low Power Mode. Updates replace the app only; your games, engines, prefixes and saves are never touched."
                 : "Updates aren't published for this build yet, so there's nothing to check.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
