// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
    private var operation: Task<Bool, Never>?

    func shutdown(session: LiveSession?, runtime: RuntimeProviderSettings?,
                  installedGames: InstalledGamesController? = nil,
                  pcGames: PCGamesController? = nil,
                  gameOperations: GameOperationsController? = nil,
                  calimochoInstaller: CalimochoReleaseInstallController? = nil) async -> Bool {
        if let operation { return await operation.value }
        guard gameOperations?.canQuit != false else { return false }
        gameOperations?.beginTermination()
        installedGames?.applicationTerminating = true
        pcGames?.beginTermination()
        runtime?.beginApplicationTermination()
        session?.applicationTerminating = true
        let pending = Task {
            let installerClosed = await calimochoInstaller?.shutdownForApplicationTermination() ?? true
            async let runtimeClosed = runtime?.shutdownForApplicationTermination() ?? true
            async let managementClosed = session?.disconnect() ?? true
            async let foregroundClosed = installedGames?.shutdownForegroundHandoff() ?? true
            let results = await (runtimeClosed, managementClosed, foregroundClosed)
            return installerClosed && results.0 && results.1 && results.2
        }
        operation = pending
        let closed = await pending.value
        if !closed {
            calimochoInstaller?.resumeAfterTerminationRefusal()
            installedGames?.applicationTerminating = false
            pcGames?.resumeAfterTerminationRefusal()
            gameOperations?.resumeAfterTerminationRefusal()
            runtime?.resumeAfterTerminationRefusal()
            session?.applicationTerminating = false
            operation = nil
        }
        return closed
    }
}
