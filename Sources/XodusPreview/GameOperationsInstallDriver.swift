// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

/// Live `InstallQueueDriver` that executes queued installs through the app's existing,
/// tested install path (`GameOperationsController.runQueuedOperation`). The queue owns
/// ordering and pause/resume/cancel; this driver owns a single engine run, so there is one
/// real execution path (reserve → run script → register installation → release), not a
/// duplicate of it.
///
/// Package-type detection and engine routing (M1/M3) are owned by a separate workstream; a
/// queued job here assumes a standard `install` record. When that model lands, the record
/// built below is the integration point for routing by package type.
@MainActor
final class GameOperationsInstallDriver: InstallQueueDriver {
    private let operations: GameOperationsController

    init(operations: GameOperationsController) { self.operations = operations }

    func run(runID: String, job: InstallJob, destination: String,
             onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent {
        let record = GameOperationRecord(id: runID, kind: .install, productID: job.productID,
                                         title: job.title, destination: destination, installedID: nil)
        return await operations.runQueuedOperation(record) { value in
            guard let activity = InstallActivity(engine: value.phase),
                  let progress = InstallProgress(bytesDone: value.bytesDone, bytesTotal: value.bytesTotal) else { return }
            Task { await onProgress(activity, progress) }
        }
    }

    func stop(runID: String) async {
        await operations.cancelQueuedRun(runID: runID)
    }
}

private extension InstallActivity {
    /// Maps an engine-reported progress phase to a lifecycle activity. The engine's terminal
    /// `done`/`failed` phases have no activity — the run's outcome code drives those.
    init?(engine phase: GameScriptProgress.Phase) {
        switch phase {
        case .preparing: self = .preparing
        case .downloading: self = .downloading
        case .verifying: self = .verifying
        case .configuring: self = .configuring
        case .done, .failed: return nil
        }
    }
}
