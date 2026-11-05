// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

final class RecipeLaunchFailureChecks: XCTestCase {
    func testBundledRuntimeCatalogueMatchesCompiledLifecyclePin() throws {
        let catalogue = try NativeTitleLaunchProfile.RuntimeCatalogue.bundled()
        XCTAssertEqual(catalogue.cliSha256, NativeLifecyclePins.cliSHA256)
        XCTAssertEqual(catalogue.evidenceCliSha256,
                       "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604")
        XCTAssertEqual(catalogue.items.filter(\.observed).map(\.storeId),
                       ["9P4NV23Q6QC2", "9MT5NJ5W7B8Z"])
    }

    func testInvalidRecipeIsReportedWithoutExposingTheRecipePath() throws {
        let runID = "2b9218c5-1251-4d57-9c3c-e0097a607dc9"
        let log = "/state/runs/\(runID)"
        let result = NativeGameResult(
            version: 1, runID: runID,
            operation: "launch", product: "9NR1R1XWLCNB", success: false,
            exitCode: 1, errorCode: "OPERATION_FAILED",
            gameDirectory: "/game", logDirectory: log,
            resultPath: "\(log)/result.json", progressPath: "\(log)/progress.jsonl",
            error: "RECIPE_ID_MISMATCH: requested title differs from /private/recipe.json"
        )

        try result.validate(operation: "launch", product: "9NR1R1XWLCNB",
                            gameDirectory: URL(fileURLWithPath: "/game"),
                            stateDirectory: URL(fileURLWithPath: "/state"), exitCode: 1)
        XCTAssertEqual(
            result.launchFailureMessage(stoppedByUser: false),
            "The launch recipe could not be loaded for this game. Open the launch log for details."
        )
        XCTAssertNil(result.launchFailureMessage(stoppedByUser: true))
    }

    func testUnrelatedLaunchFailureKeepsTheExistingMessage() {
        let result = NativeGameResult(
            version: 1, runID: "2b9218c5-1251-4d57-9c3c-e0097a607dc9",
            operation: "launch", product: "9NR1R1XWLCNB", success: false,
            exitCode: 1, errorCode: "OPERATION_FAILED",
            gameDirectory: "/game", logDirectory: "/run",
            resultPath: "/run/result.json", progressPath: "/run/progress.jsonl",
            error: "Another launch failure"
        )

        XCTAssertEqual(
            result.launchFailureMessage(stoppedByUser: false),
            InstalledGameActionCopy.launchUnavailable
        )
    }

    @MainActor
    func testRealCLIRecipeFailureReachesTheLaunchResult() async throws {
        let environment = ProcessInfo.processInfo.environment
        let names = ["XODUS_RECIPE_TEST_CLI", "XODUS_RECIPE_TEST_CLI_SHA256", "XODUS_RECIPE_TEST_FILE"]
        if names.allSatisfy({ environment[$0] == nil }) {
            throw XCTSkip("Set the real CLI, its expected SHA-256, and the shipped recipe to run this account-free check.")
        }
        guard let executablePath = environment[names[0]],
              let executableHash = environment[names[1]],
              let recipePath = environment[names[2]] else {
            XCTFail("All real-CLI recipe check inputs are required.")
            return
        }
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let recipe = URL(fileURLWithPath: recipePath).resolvingSymlinksInPath()
        let recipeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: recipe)) as? [String: Any]
        )
        XCTAssertEqual(recipeObject["storeId"] as? String, "9N431PX143P8")

        let files = FileManager.default
        let temporaryPath = try XCTUnwrap(realpath(files.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        let root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
            .appendingPathComponent("XodusRecipeLaunch-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer {
            do { try files.removeItem(at: root) }
            catch { XCTFail("Could not remove the isolated recipe check directory: \(error)") }
        }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let game = root.appendingPathComponent("game", isDirectory: true)
        let recipes = root.appendingPathComponent("recipes", isDirectory: true)
        let emptyRecipes = root.appendingPathComponent("empty-recipes", isDirectory: true)
        for directory in [home, game, recipes, emptyRecipes] {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        }
        try files.copyItem(at: recipe, to: recipes.appendingPathComponent("9NR1R1XWLCNB.json"))

        let identity = NativeAuthHostBinding(executable: executable, sha256: executableHash)
        _ = try identity.validatedArguments()
        let configuration = BackendConfiguration(executable: executable, stateDirectory: root,
                                                  executableIdentity: identity)
        let launcher = NativeGameLifecycle()
        let prefix = root.appendingPathComponent("never-created-prefix")
        // HOME does not isolate macOS Keychain; inspect the CLI's preflight order before running.
        let arguments = ["--wine", root.appendingPathComponent("missing-wine").path,
                         "--prefix", prefix.path,
                         "--runtime-dll", root.appendingPathComponent("missing-runtime.dll").path]
        let state = root.appendingPathComponent("mismatch-state")
        let rejected = try await launcher.run(
            configuration: configuration, accountHash: String(repeating: "a", count: 64),
            operation: "launch", product: "9NR1R1XWLCNB", gameDirectory: game,
            runID: InstalledGamesController.runID(), stateRoot: state, launchArguments: arguments,
            launchEnvironment: ["HOME": home.path, "XODE_RECIPES_DIR": recipes.path]
        )
        XCTAssertEqual(rejected.errorCode, "OPERATION_FAILED")
        XCTAssertTrue(rejected.error?.hasPrefix("RECIPE_ID_MISMATCH:") == true)
        XCTAssertEqual(rejected.launchFailureMessage(stoppedByUser: false),
                       "The launch recipe could not be loaded for this game. Open the launch log for details.")
        XCTAssertFalse(files.fileExists(atPath: prefix.path))
        XCTAssertFalse(files.fileExists(atPath: state.appendingPathComponent("locks").path))
        for name in ["stdout.log", "stderr.log", "service.log", "launch-stage.json"] {
            XCTAssertFalse(files.fileExists(atPath: URL(fileURLWithPath: rejected.logDirectory)
                .appendingPathComponent(name).path), "\(name) must not exist before preflight succeeds")
        }

        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let fallbackRoots = [
            home.appendingPathComponent("Library/Application Support/XOde/recipes"),
            home.appendingPathComponent(".config/xode/recipes"),
            contents.appendingPathComponent("Resources/recipes"),
            contents.deletingLastPathComponent().appendingPathComponent("recipes"),
            URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("recipes")
        ]
        for directory in fallbackRoots {
            var info = stat()
            let path = directory.appendingPathComponent("000000000000.json").path
            guard lstat(path, &info) != 0, errno == ENOENT else {
                XCTFail("The missing-recipe control has a present or unreadable fallback.")
                return
            }
        }
        let missingState = root.appendingPathComponent("missing-state")
        let missingRecipe = try await launcher.run(
            configuration: configuration, accountHash: String(repeating: "a", count: 64),
            operation: "launch", product: "000000000000", gameDirectory: game,
            runID: InstalledGamesController.runID(), stateRoot: missingState, launchArguments: arguments,
            launchEnvironment: ["HOME": home.path, "XODE_RECIPES_DIR": emptyRecipes.path]
        )
        XCTAssertEqual(missingRecipe.error, "Wine must be an existing absolute executable path")
        XCTAssertEqual(missingRecipe.launchFailureMessage(stoppedByUser: false),
                       InstalledGameActionCopy.launchUnavailable)
        XCTAssertFalse(files.fileExists(atPath: prefix.path))
        XCTAssertFalse(files.fileExists(atPath: missingState.appendingPathComponent("locks").path))
        XCTAssertFalse(files.fileExists(atPath: URL(fileURLWithPath: missingRecipe.logDirectory)
            .appendingPathComponent("service.log").path))
    }
}
