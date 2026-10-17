// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusManagement
import XCTest
@testable import XodusPreview

final class ShippingChecks: XCTestCase {
    @MainActor func testShippingAdmission() async {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if condition { print("PASS: \(name)") }
            else { failures += 1; XCTFail(name) }
        }
        let remembered = UserDefaults.standard.object(forKey: "Xodus.developerBackendPath")
        UserDefaults.standard.set("/invalid/remembered-development-engine", forKey: "Xodus.developerBackendPath")
        defer {
            if let remembered { UserDefaults.standard.set(remembered, forKey: "Xodus.developerBackendPath") }
            else { UserDefaults.standard.removeObject(forKey: "Xodus.developerBackendPath") }
        }
        let state = AppState()
        let session = LiveSession()
        let injected = LiveSession(configuration: BackendConfiguration(executable: URL(fileURLWithPath: "/invalid/injected"),
                                                                        stateDirectory: URL(fileURLWithPath: "/invalid/state")))
        check(state.destination == .library && state.query.isEmpty && !state.showingAccount
              && state.liveLibraryScope == .games && !state.showsRecentActivity,
              "Shipping navigation starts in PC Library, not activity or fixture state")
        check(!state.pcGames.hasSavedSignIn && state.pcGames.snapshot == nil && !state.pcGames.busy
              && state.pcGames.deviceCode == nil,
              "Shipping PC Library starts without credential access, network results or invented owned games")
        check(state.gameOperations.serviceStatus == nil && !state.gameOperations.serviceBusy
              && state.gameOperations.operation == nil && !state.installedGames.mutationActive,
              "Shipping game operations start without private-script, credential or mutation activity")
        check(state.gameOperations.gamePassStatus == nil && !state.gameOperations.gamePassBusy
              && !state.gameOperations.gamePassActive && session.gamePassProducts.isEmpty
              && state.installedGames.stoppingGameID == nil && state.installedGames.playNotices.isEmpty,
              "Shipping Game Pass and Stop start without cached access, catalog, process or success evidence")
        check(state.gameOperations.setupResult == nil && !state.gameOperations.setupBusy
              && !state.gameOperations.setupNeedsAttention && !state.installedGames.runtimeRepairActive
              && !state.showingSetup,
              "Shipping setup starts unchecked, without a script, repair or invented readiness")
        let results = CatalogSearchResults(query: "neutral", ownedGames: [], storeProducts: [], gamePassProductIDs: [])
        check(results.ownedMatches.isEmpty && results.storeProducts.isEmpty
              && results.badge(for: "FIXTURE00001") == nil && session.gamePassProductIDs.isEmpty
              && state.gameOperations.compatibility.isEmpty && !state.gameOperations.checkingCompatibility,
              "Shipping search and Mac-support badges start without invented ownership/feed/check evidence")
        await state.loadRecentActivityIfVisible(session: session)
        check(session.recentLibrary == nil && !session.recentLibraryBootstrapRunning
              && session.authentication == nil && session.libraryTitle == "Your PC library isn't available yet"
              && session.libraryMessage == "Xodus can't yet verify which PC games you own.",
              "Shipping main Library cannot initiate saved-status or history loading")
        state.openRecentActivity()
        check(state.showsRecentActivity && state.query.isEmpty,
              "Shipping recent activity is an explicitly selected separate Library scope")
        state.navigate(.library)
        check(!state.showsRecentActivity && state.liveLibraryScope == .games,
              "Shipping toolbar Library returns to PC Library, not implicit personal activity")
        check(state.runtimeSettings.configuration == nil && state.runtimeSettings.crossOverDependency == .notChecked,
              "Shipping dependency starts unchecked, without an invented CrossOver installation")
        let official = CrossOverDependencyState.installed(.init(
            location: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            version: "26.3", buildVersion: "26.3.0.39832"))
        let runtime = RuntimeProviderSettings(detectCrossOver: { official })
        await runtime.refreshCrossOverDependency()
        check(runtime.configuration?.provider == .crossover && runtime.configuration?.providerVersion == "26.3"
              && runtime.configuration?.engine.version == nil && runtime.configuration?.graphics.backend == nil
              && runtime.plan == nil,
              "Actual shipping configuration defaults only from a neutral verified CrossOver observation")
        runtime.select(.gptk4)
        check(runtime.requiresExperimentalAcknowledgement && runtime.planningBlocker != nil,
              "Actual shipping alternatives are acknowledgement-gated Experimental configurations")
        runtime.acknowledgeExperimental(true)
        runtime.update { $0.engine.version = "changed" }
        check(!runtime.experimentalAcknowledged && runtime.planningBlocker != nil,
              "Actual shipping component edits reset experimental acknowledgement")
        check(session.authentication == nil && session.products.isEmpty && session.activity.jobs.isEmpty
              && session.installedSnapshot == nil && !session.canSignIn,
              "Shipping live account, products, activity and registry start without invented evidence")
        check(ShippingPairPins.approved == nil, "Unpaired repository production build has no generated approval")
        check(session.backendPath == Bundle.main.bundleURL
              .appendingPathComponent("Contents/Resources/XodusEngine/xodus-cli").path,
              "Shipping engine path ignores environment and remembered development selection")
        check(injected.backendPath == session.backendPath,
              "Development configuration injection cannot replace the shipping engine")
        await session.connect()
        check(!session.isReady && session.hello == nil
              && session.errorMessage == ManagementError.pairedEngineUnavailable.localizedDescription,
              "Unpaired shipping connect fails actionably without an engine process")
        check(await session.disconnect(), "Unpaired shipping setup owns no child")
        state.runtimeSettings.select(.gptk4)
        state.runtimeSettings.acknowledgeExperimental(true)
        state.runtimeSettings.makePlan(executable: URL(fileURLWithPath: session.backendPath))
        check(!state.runtimeSettings.planning && state.runtimeSettings.plan == nil
              && state.runtimeSettings.errorMessage == ManagementError.pairedEngineUnavailable.localizedDescription,
              "Shipping pure planning also fails closed without the compiled pair")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("XodusShippingChecks-\(UUID().uuidString)")
        do {
            guard let neutralEngine = ProcessInfo.processInfo.environment["XODUS_NEUTRAL_ENGINE"],
                  let neutralFixture = ProcessInfo.processInfo.environment["XODUS_NEUTRAL_FIXTURE"] else {
                throw ManagementError.invalidRequest
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            let app = root.appendingPathComponent("Neutral.app")
            let macOS = app.appendingPathComponent("Contents/MacOS")
            let resources = app.appendingPathComponent("Contents/Resources")
            let engine = resources.appendingPathComponent("XodusEngine/xodus-cli")
            let helper = macOS.appendingPathComponent("XodusAuthHost")
            try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "invalid.example.shippingchecks", "CFBundleExecutable": "Xodus",
                "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: neutralEngine), to: engine)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
            let helperData = Data("Neutral helper identity only; never executed.".utf8)
            try helperData.write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let engineData = try Data(contentsOf: engine)
            func hash(_ data: Data) -> String {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let source = String(repeating: "a", count: 40)
            let receipt = resources.appendingPathComponent("XodusAuthHost.json")
            let canonical = Data("{\"sha256\": \"\(hash(helperData))\", \"sourceCommit\": \"\(source)\", \"version\": 1}\n".utf8)
            try canonical.write(to: receipt)
            guard let bundle = Bundle(url: app) else { throw ManagementError.invalidPayload }
            let pins = ShippingPairIdentity(schemaVersion: 1, appSourceCommit: source,
                appSourceTree: String(repeating: "b", count: 40),
                producerCommit: "c1073100ce8936a751b962b1401ddb641c8be38a",
                producerTree: "7a808c0e6a8a909455d07eb463379ab55bdf138c",
                engineSHA256: hash(engineData), engineBytes: Int64(engineData.count),
                helperSHA256: hash(helperData), helperBytes: Int64(helperData.count),
                helperVersion: 1, helperSourceCommit: source)
            let neutralState = root.appendingPathComponent("shippingpair")
            try FileManager.default.createDirectory(at: neutralState, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: neutralFixture),
                                             to: neutralState.appendingPathComponent("positive.json"))
            let configuration = try ShippingPairAdmission.configuration(bundle: bundle,
                stateDirectory: neutralState, pins: pins)
            let client = try ManagementClient()
            _ = try await client.connect(configuration)
            check(true, "Compiled shipping admission accepts only the exact owned neutral engine/helper pair")
            try Data("Changed after connection".utf8).write(to: helper)
            do {
                _ = try await client.request(.authLogout)
                check(false, "Paired auth mutation rechecks helper and engine before writing a command")
            } catch {
                check(error as? ManagementError == .pairedEngineUnavailable,
                      "Paired auth mutation rechecks helper and engine before writing a command")
            }
            try helperData.write(to: helper)
            check(await client.close(), "Admitted neutral management process is reaped without auth or helper execution")
            func rejects(_ name: String, identity: ShippingPairIdentity? = nil) {
                do {
                    _ = try ShippingPairAdmission.configuration(bundle: bundle,
                        stateDirectory: root.appendingPathComponent("unused"), pins: identity ?? pins)
                    check(false, name)
                } catch { check(error as? ManagementError == .pairedEngineUnavailable, name) }
            }
            func altered(engineBytes: Int64? = nil, helperVersion: Int = 1,
                         producer: String = "c1073100ce8936a751b962b1401ddb641c8be38a") -> ShippingPairIdentity {
                ShippingPairIdentity(schemaVersion: 1, appSourceCommit: pins.appSourceCommit,
                    appSourceTree: pins.appSourceTree, producerCommit: producer, producerTree: pins.producerTree,
                    engineSHA256: pins.engineSHA256, engineBytes: engineBytes ?? pins.engineBytes,
                    helperSHA256: pins.helperSHA256, helperBytes: pins.helperBytes,
                    helperVersion: helperVersion, helperSourceCommit: pins.helperSourceCommit)
            }
            rejects("Exact bytes are checked separately from a matching engine hash",
                    identity: altered(engineBytes: pins.engineBytes + 1))
            rejects("Unexpected helper version cannot grant native login admission", identity: altered(helperVersion: 2))
            rejects("A compiled stale producer source is not the reviewed native-host producer",
                    identity: altered(producer: String(repeating: "0", count: 40)))
            rejects("The previous producer cannot borrow the artwork-normalization pair approval",
                    identity: altered(producer: "2b31d199a3be15422596b46bc70e0926df30b539"))
            try Data((String(data: canonical, encoding: .utf8) ?? "")
                .replacingOccurrences(of: source, with: String(repeating: "c", count: 40)).utf8).write(to: receipt)
            rejects("A helper receipt from another source cannot borrow compiled pair approval")
            try canonical.write(to: receipt)
            try Data("Changed helper".utf8).write(to: helper)
            rejects("Changed helper hash or size rejects pair before launch")
            try helperData.write(to: helper)
            try Data("Old or changed engine".utf8).write(to: engine)
            rejects("Old engine or changed signed engine bytes reject pair before launch")
            let changedClient = try ManagementClient()
            do {
                _ = try await changedClient.connect(configuration)
                check(false, "Already-admitted engine is reverified immediately before process launch")
            } catch {
                check(error as? ManagementError == .pairedEngineUnavailable,
                      "Already-admitted engine is reverified immediately before process launch")
            }
            check(await changedClient.close(), "Rejected changed engine leaves no process to retire")
            let planner = RuntimePlanClient()
            do {
                _ = try await planner.plan(executable: engine, configuration: .preset(.gptk4),
                                           executableIdentity: configuration.executableIdentity)
                check(false, "Already-admitted pure planning engine is reverified before execution")
            } catch {
                check(error as? RuntimePlanningError == .unavailable,
                      "Already-admitted pure planning engine is reverified before execution")
            }
            check(!(await planner.hasOwnedProcess), "Rejected pure planning leaves no owned process")
            try engineData.write(to: engine)
            try FileManager.default.removeItem(at: engine)
            rejects("Missing bundled engine does not fall back to an environment engine")
            try FileManager.default.createSymbolicLink(at: engine, withDestinationURL: URL(fileURLWithPath: neutralEngine))
            rejects("Symlinked bundled engine rejects borrowed pair approval")
            try FileManager.default.removeItem(at: engine)
            try FileManager.default.removeItem(at: root)
        } catch {
            check(false, "Shipping neutral harness: " + ((error as? ManagementError)?.localizedDescription ?? "Local fixture failure"))
        }
        print("\(count) shipping checks, \(failures) failures. No account, provider or GUI operation.")
        XCTAssertEqual(failures, 0)
    }
}
