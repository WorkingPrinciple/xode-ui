// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Calimocho in the Engines list (COR-279 step 5): one status, at most one inline action
/// (Get, Update or Cancel); location, removal and update details live in its ⓘ sheet.
struct CalimochoEngineRow: View {
    enum Action: Equatable { case none, get, update, cancel }

    struct Presentation: Equatable {
        let state: EngineRowState?
        let subtitle: String
        let action: Action
    }

    static let builtIn = "Built-in engine · used by all games"

    @ObservedObject var installer: CalimochoReleaseInstallController
    let availability: CalimochoAvailability
    var isDefault = true
    var showsUpdates = false
    var refreshAdmission: @MainActor () async -> Bool = { false }
    var beginUpdate: @MainActor (LocalCalimochoRelease) -> Void = { _ in }
    let showDetails: () -> Void

    static func presentation(availability: CalimochoAvailability, hasFolder: Bool, progress: String?,
                             updateAvailable: Bool, downloadPublished: Bool, isDefault: Bool) -> Presentation {
        let facts = EngineDisplayName.presentation(for: CalimochoRelease.engineID).detail
        if let progress { return Presentation(state: nil, subtitle: progress, action: .cancel) }
        switch availability {
        case .ready:
            let subtitle = EngineRowState.subtitle([facts], isDefault: isDefault) ?? builtIn
            return updateAvailable ? Presentation(state: .updateAvailable, subtitle: subtitle, action: .update)
                : Presentation(state: .ready, subtitle: subtitle, action: .none)
        case .missing where !hasFolder:
            return Presentation(state: .notInstalled, subtitle: builtIn, action: downloadPublished ? .get : .none)
        case .missing, .invalid:
            return Presentation(state: .couldntVerify, subtitle: facts ?? builtIn, action: .none)
        case .checking, .pendingVerification:
            return Presentation(state: .verifying, subtitle: facts ?? builtIn, action: .none)
        case .notChecked:
            return Presentation(state: nil, subtitle: hasFolder ? (facts ?? builtIn) : builtIn, action: .none)
        }
    }

    private var pendingUpdate: LocalCalimochoRelease? {
        guard showsUpdates else { return nil }
        switch installer.updateOutcome {
        case .pinnedUpdate(let old)? where !installer.hasEngineFolder: return old
        case .finishUpdate(let old)?: return old
        default: return nil
        }
    }

    var body: some View {
        let row = Self.presentation(availability: availability, hasFolder: installer.hasEngineFolder,
                                    progress: installer.progress?.label, updateAvailable: pendingUpdate != nil,
                                    downloadPublished: CalimochoRelease.downloadPublished, isDefault: isDefault)
        EngineRow(name: "Calimocho", detail: row.subtitle, state: row.state, info: showDetails) {
            switch row.action {
            case .get:
                Button(CalimochoRelease.getTitle) { installer.install(refreshAdmission: refreshAdmission) }
                    .disabled(installer.isWorking)
                    .accessibilityIdentifier("ode.engines.calimocho.get")
            case .update:
                if let old = pendingUpdate {
                    Button("Update") { beginUpdate(old) }
                        .disabled(installer.isWorking || installer.checkingUpdates)
                        .accessibilityIdentifier("ode.engines.calimocho.update")
                }
            case .cancel:
                if installer.progress != .checkingAdmission && installer.progress != .removing {
                    Button("Cancel", action: installer.cancel)
                        .accessibilityIdentifier("ode.engines.calimocho.cancel")
                }
            case .none:
                EmptyView()
            }
        }
        .accessibilityIdentifier("ode.engines.calimocho.row")
        if let error = installer.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ode.engines.calimocho.error")
        }
    }
}
