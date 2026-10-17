// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore
import XodusManagement

/// Validates `InstalledGamesController`'s update-detection wiring: available versions become
/// the retained integration point and per-game status is derived through `UpdateDetector`.
/// The exhaustive version-comparison matrix lives in the `ManagementChecks` fixtures; this
/// confirms the controller surfaces it correctly.
@MainActor
enum InstalledGameUpdateChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        func game(version: String, storeId: String) -> InstalledGame {
            InstalledGame(id: UUID(), title: "Fixture", identityName: "Fixture.App", version: version,
                          storeId: storeId, folder: "/games/Fixture", launcher: "/games/Fixture/run",
                          importedAt: Date())
        }

        let controller = InstalledGamesController(defaultEngine: { nil },
                                                  detectAvailability: { RunnerAvailability([.crossover]) })
        let installed = game(version: "1.0.0.0", storeId: "9NBLGGH1234A")

        check(controller.updateStatus(for: installed) == .unknown,
              "Without a known available version the update status is unknown")

        controller.applyAvailableVersions(["9NBLGGH1234A": "1.0.1.0"])
        check(controller.availableVersions["9NBLGGH1234A"] == "1.0.1.0",
              "Applied available versions are retained as the M1/M3 integration point")
        check(controller.updateStatus(for: installed) == .updateAvailable,
              "A strictly newer available version surfaces an available update")
        check(controller.updateStatus(for: game(version: "1.0.1.0", storeId: "9NBLGGH1234A")) == .upToDate,
              "An equal installed version is up to date")
        check(controller.updateStatus(for: game(version: "2.0.0.0", storeId: "9NBLGGH1234A")) == .upToDate,
              "An installed version newer than available is up to date, not a downgrade")
        check(controller.updateStatus(for: game(version: "not-a-version", storeId: "9NBLGGH1234A")) == .unknown,
              "An unparseable installed version is unknown rather than falsely current")
        check(controller.updateStatus(for: game(version: "1.0.0.0", storeId: "9NBLGGH9999Z")) == .unknown,
              "A game without an available entry is unknown")
    }
}
