// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusManagement

/// The install, repair or uninstall activity a Library tile shows for one product.
///
/// Projected only from state the producers already publish (`GameOperationsController` and
/// `DownloadQueueController`). Progress is shown only when a producer reports a byte total,
/// and no time estimate is ever derived: none of the producers supply one.
struct LibraryActivity: Equatable {
    enum Kind: Equatable {
        case install, repair, uninstall

        init(_ kind: GameOperationRecord.Kind) {
            switch kind {
            case .install, .resume: self = .install
            case .repair: self = .repair
            case .uninstall: self = .uninstall
            }
        }
    }

    enum State: Equatable {
        case preparing
        case queued
        case active(phase: String?, fraction: Double?)
        case paused
        case stopping
        case needsCheck
        case failed
        case cancelled
        case completed
    }

    let kind: Kind
    let state: State

    var isInFlight: Bool {
        switch state {
        case .preparing, .queued, .active, .paused, .stopping: true
        case .needsCheck, .failed, .cancelled, .completed: false
        }
    }

    var fraction: Double? {
        if case .active(_, let fraction) = state { fraction } else { nil }
    }

    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)).clamped(to: 0...100) } }

    private var noun: String {
        switch kind {
        case .install: "Installation"
        case .repair: "Repair"
        case .uninstall: "Uninstall"
        }
    }

    private var verb: String {
        switch kind {
        case .install: "Installing"
        case .repair: "Repairing"
        case .uninstall: "Uninstalling"
        }
    }

    var title: String {
        switch state {
        case .preparing: "Preparing"
        case .queued: "Queued"
        case .active: percent.map { "\(verb) \($0)%" } ?? verb
        case .paused: "Paused"
        case .stopping: "Stopping…"
        case .needsCheck: "Needs checking"
        case .failed: "\(noun) failed"
        case .cancelled: "\(noun) cancelled"
        case .completed:
            switch kind {
            case .install: "Installed"
            case .repair: "Repaired"
            case .uninstall: "Uninstalled"
            }
        }
    }

    /// Spoken and tooltip text. Adds the reported phase, which the compact tile title omits.
    var accessibilityText: String {
        var parts = [title]
        if case .active(let phase?, _) = state, kind != .uninstall { parts.append(phase) }
        parts.append("Details in Downloads")
        return parts.joined(separator: ". ")
    }

    var symbol: String {
        switch state {
        case .preparing, .active, .stopping: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .needsCheck: "exclamationmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .completed: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch state {
        case .failed: .red
        case .needsCheck: .orange
        case .completed: .green
        default: .secondary
        }
    }

    /// The operation state that `GameOperationsController` publishes, captured for projection.
    struct Operations {
        var operation: GameOperationRecord.Kind?
        var operationProductID: String?
        var queuedInstalls: [QueuedGameInstall] = []
        var installQueuePaused = false
        var progress: GameScriptProgress?
        var cancelling = false
        var recoveryRequired = false
        var installingDirectly = false
        var directInstallProductID: String?
        var directInstallCancelled = false
        var feedbackProductID: String?
        var feedbackKind: GameOperationRecord.Kind?
        var error: String?
        var notice: String?
        var failureCode: Int?
    }

    /// Live work wins over waiting requests, which win over finished feedback.
    static func resolve(productID: String, operations: Operations, jobs: [InstallJob] = [],
                        stoppingJobIDs: Set<UUID> = []) -> LibraryActivity? {
        if let kind = operations.operation, operations.operationProductID == productID {
            let kind = Kind(kind)
            if operations.recoveryRequired { return LibraryActivity(kind: kind, state: .needsCheck) }
            if operations.cancelling { return LibraryActivity(kind: kind, state: .stopping) }
            let progress = operations.progress
            let fraction = progress.flatMap { value in
                value.bytesTotal.flatMap { $0 > 0 ? Double(value.bytesDone) / Double($0) : nil }
            }
            return LibraryActivity(kind: kind, state: .active(phase: progress?.phase.title, fraction: fraction))
        }
        if operations.installingDirectly, operations.directInstallProductID == productID {
            return LibraryActivity(kind: .install,
                                   state: operations.directInstallCancelled ? .stopping : .preparing)
        }
        if let job = jobs.last(where: { $0.productID == productID && $0.phase.occupiesSlot })
            ?? jobs.last(where: { $0.productID == productID && $0.phase == .paused }) {
            return LibraryActivity(kind: .install,
                                   state: stoppingJobIDs.contains(job.id) ? .stopping : state(of: job))
        }
        if let entry = operations.queuedInstalls.first(where: { $0.record.productID == productID }) {
            return LibraryActivity(kind: Kind(entry.record.kind),
                                   state: operations.installQueuePaused ? .paused : .queued)
        }
        if let job = jobs.last(where: { $0.productID == productID && $0.phase == .queued }) {
            return LibraryActivity(kind: .install, state: state(of: job))
        }
        if operations.operation == nil, operations.feedbackProductID == productID,
           let kind = operations.feedbackKind.map(Kind.init) {
            if operations.failureCode == 14 { return LibraryActivity(kind: kind, state: .cancelled) }
            if operations.error != nil { return LibraryActivity(kind: kind, state: .failed) }
            if operations.notice != nil, operations.failureCode == nil {
                return LibraryActivity(kind: kind, state: .completed)
            }
        }
        if let job = jobs.last(where: { $0.productID == productID }) {
            return LibraryActivity(kind: .install, state: state(of: job))
        }
        return nil
    }

    private static func state(of job: InstallJob) -> State {
        switch job.phase {
        case .queued: .queued
        case .preparing, .downloading, .verifying, .configuring:
            .active(phase: activityPhaseTitle(job.phase), fraction: job.progress?.fraction)
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private static func activityPhaseTitle(_ phase: InstallPhase) -> String? {
        switch phase {
        case .preparing: GameScriptProgress.Phase.preparing.title
        case .downloading: GameScriptProgress.Phase.downloading.title
        case .verifying: GameScriptProgress.Phase.verifying.title
        case .configuring: GameScriptProgress.Phase.configuring.title
        default: nil
        }
    }
}

extension LibraryActivity.Operations {
    @MainActor init(_ controller: GameOperationsController) {
        self.init(operation: controller.operation?.kind,
                  operationProductID: controller.operation?.productID,
                  queuedInstalls: controller.queuedInstalls,
                  installQueuePaused: controller.installQueuePaused,
                  progress: controller.progress,
                  cancelling: controller.cancelling,
                  recoveryRequired: controller.recoveryRequired,
                  installingDirectly: controller.installingDirectly,
                  directInstallProductID: controller.directInstallProductID,
                  directInstallCancelled: controller.directInstallCancelled,
                  feedbackProductID: controller.feedbackProductID,
                  feedbackKind: controller.feedbackKind,
                  error: controller.error,
                  notice: controller.notice,
                  failureCode: controller.failureCode)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// The compact tile row: the activity state plus a route to the full Downloads view.
struct LibraryActivityStatus: View {
    let activity: LibraryActivity
    let showDownloads: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if activity.isInFlight, activity.fraction == nil, activity.state != .paused,
               activity.state != .queued {
                ProgressView().controlSize(.mini)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: activity.symbol)
                    .foregroundStyle(activity.tint)
                    .accessibilityHidden(true)
            }
            Text(activity.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button(action: showDownloads) {
                Image(systemName: "arrow.down.forward.square")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show in Downloads")
            .accessibilityLabel("Show \(activity.title.lowercased()) in Downloads")
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.accessibilityText)
        .accessibilityAction(named: "Show in Downloads", showDownloads)
        .accessibilityIdentifier("xodus.library.activity")
    }
}

/// A thin determinate bar over the cover. Drawn only when a byte total is known.
struct LibraryActivityBar: View {
    let fraction: Double

    var body: some View {
        ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}
