// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
enum EngineManagementChecks {
    static func routingOnly(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/EngineRoutingChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "COR134: Synthetic engine routing files are cleaned") }
        }
        try await selectionPersistenceChecks(root: root, check: check)
    }

    static func launchSupportChecks(check: (Bool, String) -> Void) {
        let suite = "Xodus.req114.support.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "REQ114 M1 isolated defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard let catalog = try? NativeEngineDefaults.read(),
              let nms = catalog.bindings.first(where: { $0.engineName == "calimocho-wine11.20-gptk4b3-tls-vulkan-private" }) else {
            check(false, "REQ114 M1 bundled engine defaults readable"); return
        }
        let present: (String) -> String? = { $0 == nms.registryPath.map(NativeTitleLaunchProfile.expand) ? nms.registrySha256 : nil }
        let unprofiled = NativeLaunchSupport.evaluate(productID: "9NZZZZZZZZZZ", defaults: defaults,
            engineDefaults: { catalog }, registryDigest: present)
        check(unprofiled == .notSupported(NativeLaunchSupport.notSupportedReason) && !unprofiled.canPlay
              && !unprofiled.offersEngines,
              "REQ114 M1/R1 title without an admitted launch profile is not yet supported and never offers Play")
        let missingRelease = NativeLaunchSupport.evaluate(productID: "9P9VNSQK1W3K", defaults: defaults,
            engineDefaults: { catalog }, registryDigest: present, releaseStatus: { _ in .notInstalled })
        check(!missingRelease.canPlay && missingRelease.offersEngines
              && missingRelease.reason?.contains("Calimocho isn't installed") == true
              && missingRelease.reason?.contains("No other engine was substituted") == true,
              "REQ115 M1/R3 Brotato's pinned but absent Calimocho release shows Engine needed, not Play")
        check(NativeLaunchSupport.evaluate(productID: "BQVQTL3PCH05", defaults: defaults,
                engineDefaults: { catalog }, registryDigest: present) == .supported,
              "REQ114 M1 profiled title whose bound engine registry matches is supported")
        check(NativeLaunchSupport.evaluate(productID: "BQVQTL3PCH05", defaults: defaults,
                engineDefaults: { catalog }, registryDigest: { _ in nil }).offersEngines,
              "REQ114 M1 missing engine registry on this Mac withholds Play")
        check(NativeLaunchSupport.evaluate(productID: "BQVQTL3PCH05", defaults: defaults,
                engineDefaults: { catalog }, registryDigest: { _ in String(repeating: "0", count: 64) }).offersEngines,
              "REQ114 M1 changed engine registry bytes withhold Play")
        check(NativeLaunchSupport.evaluate(productID: "9P9VNSQK1W3K", defaults: defaults, hasEngineOverride: true,
                engineDefaults: { catalog }, registryDigest: present) == .supported
              && NativeLaunchSupport.evaluate(productID: "9NZZZZZZZZZZ", defaults: defaults, hasEngineOverride: true,
                engineDefaults: { catalog }, registryDigest: present) != .supported,
              "REQ114 M1 explicit per-game engine applies only to profiled titles")
        let unavailable = InstalledGamesController.nativeLaunchFailureMessage(NativeLaunchError.engineUnavailable)
        check(unavailable == NativeLaunchError.engineUnavailable.localizedDescription
              && unavailable.contains("Open Engines") && !unavailable.contains("Runtime settings")
              && InstalledGamesController.launchFailureOpensEngines(NativeLaunchError.engineUnavailable)
              && !InstalledGamesController.launchFailureOpensEngines(NativeLaunchError.installationNotReady)
              && InstalledGamesController.nativeLaunchFailureMessage(GameScriptError.failed(14))
                == InstalledGameActionCopy.launchUnavailable,
              "REQ114 B2 Play failures keep their specific cause and offer Engines only for engine issues")
        check(EngineDisplayName.label("calimocho-wine11.20-gptk4b3-tls-vulkan-private") == "Calimocho"
              && EngineDisplayName.label("apple-gptk-4.0b3") == "Apple Game Porting Toolkit",
              "REQ114 U2 engine identifiers map to user-meaningful names without renaming IDs")
        highballChecks(check: check)
    }

    static func highballChecks(check: (Bool, String) -> Void) {
        func json(_ state: String, qualified: Bool, product: String, error: String?) -> Data {
            let failure = error.map { "{\"code\":\"\($0)\"}" } ?? "null"
            return Data("""
            {"schemaVersion":1,"capability":"highballAdmissionV1","providerID":"highball","state":"\(state)",
            "qualified":\(qualified),"admitted":\(qualified),"ready":\(qualified),"productID":"\(product)",
            "candidate":{"version":"0.10.22"},"error":\(failure)}
            """.utf8)
        }
        check(HighballContract.decode(json("missing", qualified: false, product: "9P9VNSQK1W3K",
                                           error: "HIGHBALL_NOT_INSTALLED")) == .missing,
              "REQ127 missing Highball decodes and offers Get")
        check(HighballContract.decode(json("detected", qualified: false, product: "BQVQTL3PCH05",
                                           error: "HIGHBALL_TITLE_UNQUALIFIED"))
              == .detected(version: "0.10.22", blocker: "HIGHBALL_TITLE_UNQUALIFIED"),
              "REQ127 detected-but-unqualified Highball is blocked")
        check(HighballContract.decode(json("qualified", qualified: true, product: "9P9VNSQK1W3K", error: nil))
              == .qualified(version: "0.10.22", productID: "9P9VNSQK1W3K"),
              "REQ127 qualified requires the backend verdict")
        check(HighballContract.decode(json("detected", qualified: true, product: "X", error: nil)) == nil
              && HighballContract.decode(json("qualified", qualified: false, product: "X", error: nil)) == nil
              && HighballContract.decode(Data("{}".utf8)) == nil,
              "REQ127 inconsistent or unknown backend output is never qualified")
        check(HighballState.missing.offersGet && !HighballState.detected(version: nil, blocker: nil).offersGet
              && HighballContract.detect(at: URL(fileURLWithPath: "/nonexistent/Highball.app")) == .missing,
              "REQ127 Get appears only when absent and detection is read-only")
        let qualified = json("qualified", qualified: true, product: HighballContract.qualifiedProductID, error: nil)
        check(HighballContract.decode(qualified, product: HighballContract.qualifiedProductID, exitCode: 0) != nil
              && HighballContract.decode(qualified, product: "BQVQTL3PCH05", exitCode: 0) == nil
              && HighballContract.decode(qualified, product: HighballContract.qualifiedProductID, exitCode: 1) == nil
              && HighballContract.decode(json("detected", qualified: false, product: HighballContract.qualifiedProductID,
                                              error: "HIGHBALL_TITLE_UNQUALIFIED"),
                                         product: HighballContract.qualifiedProductID, exitCode: 0) == nil,
              "REQ127 a verdict for another product, or an exit status that disagrees with it, is refused")
        let local = HighballState.detected(version: "0.10.22", blocker: nil)
        check(HighballContract.reconcile(local: local, backend: nil) == local
              && !HighballContract.reconcile(local: local, backend: nil).isQualified
              && HighballContract.reconcile(local: local, backend: .qualified(version: "0.10.22",
                  productID: HighballContract.qualifiedProductID)).isQualified
              && HighballContract.reconcile(local: .missing, backend: nil) == .missing,
              "REQ127 without a backend verdict Highball stays Detected, never Qualified")
        check(HighballCopy.detail(.qualified(version: "0.10.22", productID: HighballContract.qualifiedProductID))
                == "0.10.22 · Qualified for Brotato only"
              && HighballCopy.detail(.detected(version: nil, blocker: "HIGHBALL_SIGNATURE_INVALID"))
                == "Signature couldn't be verified"
              && HighballCopy.detail(.detected(version: "1", blocker: nil)) == "1 · Not qualified"
              && !HighballCopy.explanation.contains("backend")
              && HighballCopy.explanation.contains(AppBrand.displayName),
              "REQ127 rows read Missing, Detected or Qualified for the one title in plain language")
    }

    /// COR-224/REQ-127: admitted CrossOver and Highball engines decode, but launch only for their one title.
    static func providerScopeChecks(check: (Bool, String) -> Void) throws {
        func inspection(_ declared: String?, _ admitted: String?, admission: String = "admitted",
                        name: String = "engine") -> EngineInspection {
            EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
                registrySha256: String(repeating: "a", count: 64), engineName: name, declaredProvider: declared,
                admittedProvider: admitted, admission: admission, ready: true, qualified: false,
                wineSha256: String(repeating: "b", count: 64), wineserverSha256: String(repeating: "c", count: 64),
                error: nil)
        }
        func decodes(_ value: EngineInspection) -> Bool {
            guard let bytes = try? JSONEncoder().encode(value) else { return false }
            return (try? EngineInspection.decode(bytes, engine: "engine", registryDigest: nil, exitCode: 0)) != nil
        }
        check(decodes(inspection("calimocho", "calimocho")) && decodes(inspection("crossover", "crossover"))
              && decodes(inspection("highball", "highball"))
              && !decodes(inspection("other", "other")) && !decodes(inspection("crossover", "highball"))
              && !decodes(inspection("highball", "calimocho"))
              && !decodes(inspection("crossover", nil, admission: "genericWine"))
              && decodes(inspection("other", nil, admission: "genericWine")),
              "REQ127/COR224: engine-inspect admits Calimocho, CrossOver and Highball only as themselves; unknown providers fail closed")
        func selection(_ provider: String) -> AdmittedEngineSelection {
            AdmittedEngineSelection(registryPath: "/tmp/registry.json", inspection: inspection(provider, provider))
        }
        func game(_ product: String) -> InstalledGame {
            InstalledGame(id: UUID(), title: "Fixture", identityName: "Fixture", version: "1", storeId: product,
                          folder: "/tmp/fixture", launcher: "", importedAt: Date())
        }
        func overrides(_ provider: String, _ product: String) -> Bool {
            (try? NativeLaunchConfiguration.validateOverride(selection(provider), game: game(product))) != nil
        }
        check(overrides("crossover", AdmittedProviderScope.crossOverProductID)
              && !overrides("crossover", HighballContract.qualifiedProductID)
              && overrides("highball", HighballContract.qualifiedProductID)
              && !overrides("highball", AdmittedProviderScope.crossOverProductID)
              && !overrides("highball", "FIXTURE00001") && !overrides("crossover", "FIXTURE00001"),
              "REQ127/COR224: CrossOver appears only for No Man's Sky and Highball only for Brotato")
        check(NativeEngineDefaults.permitsGlobalDefault(selection("calimocho"))
              && !NativeEngineDefaults.permitsGlobalDefault(selection("crossover"))
              && !NativeEngineDefaults.permitsGlobalDefault(selection("highball")),
              "COR263: Calimocho stays the only global default; title-scoped providers never become it")
        let home = "/Users/fixture"
        let root = HighballContract.engineRoot(home: home).path
        func verdict(_ entry: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "capability": "highballAdmissionV1", "providerID": "highball",
                "productID": HighballContract.qualifiedProductID, "state": "qualified", "admitted": true,
                "ready": true, "qualified": true, "candidate": ["version": "0.10.22"], "engine": NSNull(),
                "error": NSNull(), "registryEntry": entry])) ?? Data()
        }
        var entry: [String: Any] = [
            "name": HighballContract.engineName, "provider": ["id": "highball", "contract_version": 1],
            "kind": "free", "local_only": true, "version": "Highball 0.10.22 engine x64-crossover26.3-r27",
            "renderer": "dxmt", "install_path": root, "wine": root + "/engine/bin/wine",
            "wineserver": root + "/engine/bin/wineserver", "sha256": HighballContract.wineSha256,
            "wineserver_sha256": HighballContract.wineserverSha256,
            "environment": ["WINEESYNC": "0"], "smoke_test": ["status": "pass", "evidence": "x"]]
        let rendered = try HighballContract.registryData(verdict: verdict(entry),
            product: HighballContract.qualifiedProductID, exitCode: 0, home: home)
        let again = try HighballContract.registryData(verdict: verdict(entry),
            product: HighballContract.qualifiedProductID, exitCode: 0, home: home)
        entry["wine"] = "/tmp/other/wine"
        let moved = try? HighballContract.registryData(verdict: verdict(entry),
            product: HighballContract.qualifiedProductID, exitCode: 0, home: home)
        let refused = try? HighballContract.registryData(verdict: verdict(entry),
            product: HighballContract.qualifiedProductID, exitCode: 1, home: home)
        check(rendered == again && String(decoding: rendered, as: UTF8.self).contains(HighballContract.engineName)
              && moved == nil && refused == nil,
              "REQ127: The Highball registry renders deterministically from a qualified verdict for the pinned engine path only")
    }

    /// Owner decision (27 Oct): a profile's qualification time bound never reaches user Play.
    static func playTimeoutChecks(check: (Bool, String) -> Void) throws {
        let profiles = try NativeTitleLaunchProfile.bundledProfiles()
        let bounded = profiles.filter { $0.timeoutSeconds != nil }
        let source = (try? String(contentsOfFile: "Sources/XodusPreview/NativeLaunchConfiguration.swift", encoding: .utf8)) ?? ""
        let play = source.range(of: "func arguments() async throws -> [String] {").map {
            String(source[$0.lowerBound...].prefix(2_000)) } ?? ""
        check(!bounded.isEmpty && bounded.allSatisfy { $0.arguments.contains("--timeout-seconds") }
              && profiles.allSatisfy { !$0.playArguments.contains("--timeout-seconds") }
              && play.contains("profile?.playArguments") && !play.contains("profile?.arguments"),
              "Owner: app Play never passes --timeout-seconds for any of \(profiles.count) bundled profiles; the bound stays on probe arguments only (\(bounded.map(\.productID)))")
    }

    /// REQ-127: the app runs only the read-only `highball-inspect` contract and never a game or Highball.
    static func highballInspectionChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let cli = root.appendingPathComponent("highball-cli")
        let launched = root.appendingPathComponent("highball-must-not-run")
        func script(capability: String, verdict: String, exit: Int) throws {
            try Data("""
            #!/bin/sh
            if [ "$1" != "highball-inspect" ]; then /usr/bin/touch '\(launched.path)'; exit 91; fi
            if [ "$2" = "--contract-version" ]; then printf '%s\\n' '\(capability)'; exit 0; fi
            if [ "$2" != "--product" ] || [ "$3" != "\(HighballContract.qualifiedProductID)" ] || [ -n "$4" ]; then
              /usr/bin/touch '\(launched.path)'; exit 92
            fi
            printf '%s\\n' '\(verdict)'
            exit \(exit)

            """.utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        let supported = #"{"schemaVersion":1,"capability":"highballAdmissionV1","supported":true}"#
        let product = HighballContract.qualifiedProductID
        let qualifiedVerdict = #"{"schemaVersion":1,"capability":"highballAdmissionV1","providerID":"highball","productID":"\#(product)","state":"qualified","admitted":true,"ready":true,"qualified":true,"candidate":{"version":"0.10.22"},"engine":null,"registryEntry":null,"error":null}"#
        let detectedVerdict = #"{"schemaVersion":1,"capability":"highballAdmissionV1","providerID":"highball","productID":"\#(product)","state":"detected","admitted":false,"ready":false,"qualified":false,"candidate":{"version":"0.10.22"},"error":{"code":"HIGHBALL_ENGINE_HASH_MISMATCH","message":"x"}}"#
        let client = EngineInspectionClient()
        try script(capability: supported, verdict: qualifiedVerdict, exit: 0)
        let qualified = await client.highball(executable: cli)
        try script(capability: supported, verdict: detectedVerdict, exit: 1)
        let detected = await client.highball(executable: cli)
        try script(capability: supported, verdict: qualifiedVerdict, exit: 1)
        let disagreeing = await client.highball(executable: cli)
        try script(capability: #"{"schemaVersion":1,"capability":"highballAdmissionV1","supported":false}"#,
                   verdict: qualifiedVerdict, exit: 0)
        let unsupported = await client.highball(executable: cli)
        let absent = await client.highball(executable: root.appendingPathComponent("no-backend"))
        check(qualified == .qualified(version: "0.10.22", productID: product)
              && detected == .detected(version: "0.10.22", blocker: "HIGHBALL_ENGINE_HASH_MISMATCH")
              && disagreeing == nil && unsupported == nil && absent == nil
              && !FileManager.default.fileExists(atPath: launched.path),
              "REQ127 Settings asks only highball-inspect for Brotato; unsupported, missing or inconsistent backends give no verdict")
    }

    /// REQ-115/B3: release engines are discovered, hash- and signature-verified and rendered per Mac; nothing user-specific ships.
    static func releaseEngineChecks(check: (Bool, String) -> Void) throws {
        let bundled = try Data(contentsOf: LaunchRecipeResources.engineDefaultsURL())
        let catalog = try NativeEngineDefaults.read()
        let release = catalog.bindings.first { $0.engineName == catalog.defaultEngine }
        let devLocal = catalog.bindings.filter { $0.registryPath != nil && $0.provider == nil }
        let scoped = catalog.bindings.filter { $0.provider != nil }
        check(scoped.map(\.engineName).sorted() == ["crossover-26.3-mvk142", HighballContract.engineName]
              && scoped.allSatisfy { $0.developerLocal == true && $0.engineName != catalog.defaultEngine }
              && scoped.first { $0.provider == "highball" }?.isHighball == true
              && scoped.first { $0.provider == "crossover" }?.registrySha256
                == "c246dd2977fc42daf933d1e39507d5c1e2b49a7aa37beaaa6fe5348bcccbf80d"
              && NativeEngineDefaults.titleScopedEngineNames == Set(scoped.map(\.engineName)),
              "REQ127/COR224: CrossOver and Highball are developer-local, title-scoped bindings that are never the default")
        check(CalimochoReleasePin.release06.engineName == "calimocho-11.20-4.0b3-06"
              && CalimochoReleasePin.all == [.release04, .release06]
              && catalog.defaultEngine == "calimocho-11.20-4.0b3-06"
              && CalimochoReleasePin.release06.wineSha256 == "803a62d101303bb3160da4aa8a506857c3d1e1146aa4a0c9ee8250357ef12505"
              && CalimochoReleasePin.release06.wineserverSha256 == "7102d70405e7667acf143e710723f58fb24d32eee81468b1f0f02279343601d0"
              && CalimochoReleasePin.release06.engineJSONSha256 == "d3ca32d8d706be0ca948f661f76e68c4a735b78362c6fb95fe50c12eb5db18ff"
              && CalimochoReleasePin.release06.manifestSha256 == "db1b642e1d1a93cf50a3620a994ca049e34ce2352dc25fc34617a651302528bf"
              && CalimochoReleasePin.release06.teamID == "M62Z4M5EUY"
              && CalimochoReleasePin.release06.archiveSha256 == "3fc4467b466b6f8f0855c1934b2fe6a3d1c02b0c5ca85037860b735e4e419ee5"
              && CalimochoReleasePin.release06.archiveByteCount == 200_075_043
              && CalimochoReleasePin.release06.expandedByteCount == 695_625_804
              && CalimochoReleaseInstallService().pin == .release06
              && release?.release == .release06 && release?.registryPath == nil && release?.registrySha256 == nil
              && catalog.bindings.contains { $0.release == .release04 }
              && devLocal.map(\.engineName) == ["calimocho-wine11.20-gptk4b3-tls-vulkan-private"]
              && devLocal.allSatisfy { $0.developerLocal == true }
              && String(decoding: bundled, as: UTF8.self).components(separatedBy: "${HOME}/src/").count == 2
              && !String(decoding: bundled, as: UTF8.self).contains("/Users/"),
              "REQ115 B3: shipped engine defaults pin the release engine by name and keep only the documented NMS developer-local exception")

        guard let canonicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CalimochoInstallError.invalidArchive("The temporary test folder couldn't be resolved.")
        }
        let root = URL(fileURLWithPath: String(cString: canonicalTemporary), isDirectory: true)
            .appendingPathComponent("xodus-req115-engine-\(UUID().uuidString)")
        free(canonicalTemporary)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let engines = root.appendingPathComponent("Engines"), registries = root.appendingPathComponent("registries")
        let name = CalimochoReleasePin.release04.engineName
        func build(environment: [String: String] = ["WINELOADER": "${ENGINE_ROOT}/bin/wine", "WINEDEBUG": "-all"],
                   wine: String = "bin/wine") throws -> CalimochoReleasePin {
            let folder = engines.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
            var listing = ""
            for (file, body) in [("bin/wine", "wine"), ("bin/wineserver", "server"), ("lib/libcalimocho.dylib", "library")] {
                try Data(body.utf8).write(to: folder.appendingPathComponent(file))
                chmod(folder.appendingPathComponent(file).path, 0o755)
                listing += "\(CalimochoReleaseEngines.digest(Data(body.utf8)))  \(file)\n"
            }
            let manifest: [String: Any] = ["schema": "calimocho-engine/1", "engine_id": name, "version": "0.1120.4.4",
                "provider": ["id": "calimocho", "contract_version": 1], "paths": ["wine": wine, "wineserver": "bin/wineserver"],
                "environment": environment, "signing": ["team_id": "M62Z4M5EUY"]]
            let json = try JSONSerialization.data(withJSONObject: manifest)
            try json.write(to: folder.appendingPathComponent("calimocho-engine.json"))
            listing += "\(CalimochoReleaseEngines.digest(json))  calimocho-engine.json\n"
            try Data(listing.utf8).write(to: folder.appendingPathComponent("MANIFEST.sha256"))
            return CalimochoReleasePin(engineName: name, wineSha256: CalimochoReleaseEngines.digest(Data("wine".utf8)),
                wineserverSha256: CalimochoReleaseEngines.digest(Data("server".utf8)),
                engineJSONSha256: CalimochoReleaseEngines.digest(json),
                manifestSha256: CalimochoReleaseEngines.digest(Data(listing.utf8)), teamID: "M62Z4M5EUY",
                renderer: "apple-4.0b3", downloadURL: nil, archiveSha256: nil,
                archiveByteCount: nil, expandedByteCount: nil, attestation: "fixture")
        }
        let signed: (URL, String) -> Bool = { _, requirement in requirement.contains("\"M62Z4M5EUY\"") }
        func outcome(_ pin: CalimochoReleasePin, signature: @escaping (URL, String) -> Bool = signed) -> CalimochoReleaseError? {
            do { _ = try CalimochoReleaseEngines.verify(pin, root: engines, signature: signature); return nil }
            catch let error as CalimochoReleaseError { return error } catch { return .damaged("unexpected") }
        }
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        let missingPin = try build()
        try FileManager.default.removeItem(at: engines.appendingPathComponent(name))
        check(outcome(missingPin) == .notInstalled
              && NativeLaunchSupport.releaseManifestStatus(missingPin, root: engines) == .notInstalled
              && CalimochoReleaseError.notInstalled.localizedDescription == "Calimocho isn't installed.",
              "REQ115 B3: an absent release engine reports Calimocho isn't installed")

        let pin = try build()
        check(CalimochoAvailability.verifiedRelease(root: engines, signature: signed) == .missing,
              "M1: only -04 installed reports the active -06 missing, not pending")
        let activeFolder = engines.appendingPathComponent(CalimochoReleasePin.release06.engineName)
        try FileManager.default.moveItem(at: engines.appendingPathComponent(name), to: activeFolder)
        check(CalimochoAvailability.verifiedRelease(root: engines, signature: signed) != .missing,
              "M1: only -06 installed is inspected as active, never mistaken for missing -04")
        try FileManager.default.moveItem(at: activeFolder, to: engines.appendingPathComponent(name))
        let verified = try CalimochoReleaseEngines.verify(pin, root: engines, signature: signed)
        func inspection(admitted: Bool) -> EngineInspection {
            EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
                registrySha256: String(repeating: "a", count: 64), engineName: name, declaredProvider: "calimocho",
                admittedProvider: admitted ? "calimocho" : nil, admission: admitted ? "admitted" : "denied",
                ready: admitted, qualified: false, wineSha256: pin.wineSha256, wineserverSha256: pin.wineserverSha256,
                error: admitted ? nil : .init(code: "PROVIDER_NOT_ADMITTED", message: "manifest entry mismatch"))
        }
        let admitted = inspection(admitted: true), denied = inspection(admitted: false)
        check(CalimochoAvailability.verifiedRelease(pin, root: engines.appendingPathComponent("absent"), signature: signed,
                                                    admission: admitted) == .missing
              && CalimochoAvailability.verifiedRelease(pin, root: engines, signature: signed, admission: admitted) == .ready
              && CalimochoAvailability.verifiedRelease(pin, root: engines, signature: { _, _ in false }, admission: admitted)
                != .ready,
              "REQ115 B3: Engines availability is ready only for a verified, admitted release, missing when absent, invalid when unsigned")
        check(CalimochoAvailability.verifiedRelease(pin, root: engines, signature: signed, admission: nil)
                == .pendingVerification,
              "REQ115 M3: a locally verified engine without backend admission stays pending and never Ready")
        let library = engines.appendingPathComponent(name).appendingPathComponent("lib/libcalimocho.dylib")
        try Data("tampered".utf8).write(to: library)
        check(outcome(pin) == nil
              && CalimochoAvailability.verifiedRelease(pin, root: engines, signature: signed, admission: denied)
                == .invalid(CalimochoAvailability.notAdmittedReason),
              "REQ115 M3: a corrupted manifest entry passes only the app pre-filter; with the backend refusing admission it never yields Ready")
        try Data("library".utf8).write(to: library)
        let rendered = try CalimochoReleaseEngines.renderRegistry(verified, registries: registries)
        let registry = try NativeEngineRegistry.read(rendered.url)
        let entry = registry.engines.first
        let folder = engines.appendingPathComponent(name).path
        check(CalimochoReleaseEngines.installedNames(root: engines) == [name]
              && registry.engines.count == 1 && entry?.name == name && entry?.provider?.id == "calimocho"
              && entry?.wine == folder + "/bin/wine" && entry?.sha256 == pin.wineSha256
              && entry?.wineserver_sha256 == pin.wineserverSha256
              && entry?.environment == ["WINELOADER": folder + "/bin/wine", "WINEDEBUG": "-all"]
              && registry.byteDigest == rendered.digest
              && (try? CalimochoReleaseEngines.renderRegistry(verified, registries: registries).digest) == rendered.digest,
              "REQ115 B3: a verified release engine renders a stable local registry with absolute paths and its environment unchanged")

        check(outcome(pin, signature: { _, _ in false }) == .untrusted,
              "REQ115 B3: an engine not signed by the publisher's Team ID is refused")
        try Data("tampered".utf8).write(to: engines.appendingPathComponent(name + "/bin/wineserver"))
        check(outcome(pin).map { if case .damaged = $0 { true } else { false } } == true,
              "REQ115 B3: a changed wineserver fails its release pin")
        for (label, mutate) in [("DYLD_* environment", { try build(environment: ["DYLD_INSERT_LIBRARIES": "/tmp/x"]) }),
                                ("MTL_HUD environment", { try build(environment: ["MTL_HUD_ENABLED": "1"]) }),
                                ("unknown ${VAR}", { try build(environment: ["X": "${HOME}/x"]) }),
                                ("path escaping the engine folder", { try build(wine: "../outside/wine") }),
                                ("absolute path", { try build(wine: "/bin/sh") })] as [(String, () throws -> CalimochoReleasePin)] {
            let mutated = try mutate()
            check(outcome(mutated).map { if case .damaged = $0 { true } else { false } } == true,
                  "REQ115 B3: release manifest with \(label) is refused")
        }
        let linkPin = try build()
        let real = engines.appendingPathComponent(name), moved = root.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: real, to: moved)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: moved)
        check(outcome(linkPin).map { if case .damaged = $0 { true } else { false } } == true
              && CalimochoReleaseEngines.installedNames(root: engines).isEmpty,
              "REQ115 B3: a symlinked engine folder is neither discovered nor verified")

    }

    static func run(check: (Bool, String) -> Void) async throws {
        launchSupportChecks(check: check)
        try releaseEngineChecks(check: check)
        try await CalimochoReleaseInstallerChecks.run(check: check)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            .appendingPathComponent("EngineManagementChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ79 removes only its owned fixture directory") }
        }
        try await highballInspectionChecks(root: root, check: check)
        try providerScopeChecks(check: check)
        try playTimeoutChecks(check: check)
        let executable = root.appendingPathComponent("wine")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func entry(_ name: String = "fixture", kind: String = "free", smoke: String = "pass",
                   presentation: String? = nil, path: String? = nil) throws -> NativeEngineRegistry.Entry {
            var fields: [String: Any] = [
                "name": name, "kind": kind, "wine": path ?? executable.path,
                "smoke_test": ["status": smoke], "version": "11.20",
                "source_url": "https://www.winehq.org/"
            ]
            if let presentation { fields["presentation_validation"] = ["status": presentation] }
            return try JSONDecoder().decode(NativeEngineRegistry.Entry.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        let wine = try entry()
        check(CrossOverDependencyState.absent.title == "CrossOver is not installed"
              && CrossOverDependencyState.absent.explanation.contains("only for games configured to use it"),
              "REQ79 missing CrossOver copy is route-specific, not a universal gameplay prerequisite")
        let crossOver = try entry("cross", kind: "CrossOver")
        check(EngineManagementPolicy.matches(wine, provider: .standaloneWine)
              && !EngineManagementPolicy.matches(wine, provider: .crossover)
              && EngineManagementPolicy.matches(crossOver, provider: .crossover)
              && !EngineManagementPolicy.matches(crossOver, provider: .standaloneWine),
              "REQ79 registry menus keep commercial CrossOver and generic free Wine distinct")
        check(!EngineManagementPolicy.matches(wine, provider: .gptk4)
              && !EngineManagementPolicy.matches(wine, provider: .gptk3),
              "REQ79 graphics toolkit declarations never impersonate a registered engine")
        check(try EngineManagementPolicy.status(wine) == .usable
              && EngineManagementPolicy.status(try entry(smoke: "pending")) == .detected
              && EngineManagementPolicy.status(try entry(smoke: "failed")) == .unsupported
              && EngineManagementPolicy.status(try entry(presentation: "failed")) == .unsupported
              && EngineManagementPolicy.status(try entry(path: "/missing/wine")) == .missing
              && EngineManagementPolicy.status(try entry(path: "relative/wine")) == .error
              && EngineManagementPolicy.status(try entry(kind: "unknown")) == .unsupported,
              "REQ79 distinguishes observed, smoke-tested, unsupported, missing and invalid records")
        check(EngineManagementPolicy.status(try entry("calimocho-impostor")) != .qualified,
              "REQ79 a provider-looking filename never proves identity or game qualification")
        check(wine.version == "11.20" && wine.source_url == "https://www.winehq.org/"
              && EngineManagementPolicy.calimochoSource.absoluteString == "https://github.com/WorkingPrinciple/calimocho"
              && CrossOverDependencyState.trialDownloadURL.absoluteString == "https://www.codeweavers.com/crossover",
              "REQ79 retains declared metadata separately and uses only verified official acquisition destinations")
        let suite = "EngineManagementChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "fixture", "kind": "free", "wine": executable.path, "smoke_test": ["status": "pass"]],
            ["name": "cross", "kind": "CrossOver", "wine": executable.path, "smoke_test": ["status": "pass"]]
        ]])
        let registryURL = root.appendingPathComponent("registry.json")
        try bytes.write(to: registryURL)
        let registry = try NativeEngineRegistry.read(registryURL)
        defaults.set("fixture", forKey: "Xodus.lifecycle.engine.crossover")
        do {
            _ = try NativeLaunchConfiguration.selectEngine(registry: registry, provider: .crossover,
                                                          defaults: defaults, provenEngine: nil)
            check(false, "REQ79 rejects a stale CrossOver preference pointing to generic Wine")
        } catch NativeLaunchError.engineUnavailable {
            check(true, "REQ79 rejects a stale CrossOver preference pointing to generic Wine without fallback")
        }
        defaults.set("cross", forKey: "Xodus.lifecycle.engine.crossover")
        check(try NativeLaunchConfiguration.selectEngine(registry: registry, provider: .crossover,
            defaults: defaults, provenEngine: nil).name == "cross",
              "REQ79 valid explicit provider selection resolves the exact record")
        let scopedBytes = try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "crossover-26.3-mvk142", "kind": "CrossOver", "wine": executable.path,
             "provider": ["id": "crossover", "contract_version": 1]],
            ["name": "missing-wine", "kind": "CrossOver", "wine": root.appendingPathComponent("absent/wine").path]
        ]])
        let scopedURL = root.appendingPathComponent("scoped-registry.json")
        try scopedBytes.write(to: scopedURL)
        let scoped = try NativeEngineRegistry.read(scopedURL)
        func picks(_ name: String, scoped admitted: Bool) -> Bool {
            (try? NativeLaunchConfiguration.selectEngine(registry: scoped, provider: nil, defaults: defaults,
                provenEngine: name, scopedAdmission: admitted))?.name == name
        }
        check(picks("crossover-26.3-mvk142", scoped: true) && !picks("crossover-26.3-mvk142", scoped: false)
              && !picks("missing-wine", scoped: true),
              "COR224 e2e: A freshly admitted title-scoped engine needs no registry smoke test, only an executable Wine; unadmitted records still do")
        defaults.set("removed", forKey: "Xodus.lifecycle.engine.crossover")
        do {
            _ = try NativeLaunchConfiguration.selectEngine(registry: registry, provider: .crossover,
                                                          defaults: defaults, provenEngine: nil)
            check(false, "REQ79 missing explicit choice is not substituted")
        } catch NativeLaunchError.engineUnavailable {
            check(true, "REQ79 missing explicit choice is not substituted")
        }
        EngineDefaults.setDefaultEngine(.standaloneWine, defaults)
        check(EngineDefaults.defaultEngine(defaults) == .standaloneWine,
              "REQ79 default preference persists in the same key used by actual game routing")
        let observation = EngineRegistryObservation()
        await observation.refresh(path: registryURL.path, allowsFileReads: false)
        check(observation.status == .notChecked && observation.entries.isEmpty,
              "REQ79 fixture-disabled reads cannot fabricate detected installations")
        await observation.refresh(path: "", allowsFileReads: true)
        check(observation.status == .missing, "REQ79 unset registry is missing, not a successful empty detection")
        await observation.refresh(path: registryURL.path, allowsFileReads: true)
        check(observation.status == .detected && observation.entries.count == 2,
              "REQ79 actual bounded local read observes all records without discarding failed entries")
        try Data("not JSON".utf8).write(to: registryURL)
        await observation.refresh(path: registryURL.path, allowsFileReads: true)
        check(observation.status == .error && observation.errorMessage != nil && observation.entries.isEmpty,
              "REQ79 invalid refresh explicitly retires stale observations and offers retry")
        try bytes.write(to: registryURL)
        await observation.refresh(path: registryURL.path, allowsFileReads: true)
        check(observation.status == .detected && observation.errorMessage == nil,
              "REQ79 retry recovers only after the registry is actually readable again")
        let digest = String(repeating: "a", count: 64)
        let inspected = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: digest, engineName: "candidate", declaredProvider: "calimocho",
            admittedProvider: "calimocho", admission: "admitted", ready: true, qualified: false,
            wineSha256: String(repeating: "b", count: 64), wineserverSha256: String(repeating: "c", count: 64),
            error: nil)
        let inspectionBytes = try JSONEncoder().encode(inspected)
        check(try EngineInspection.decode(inspectionBytes, engine: "candidate", registryDigest: digest,
            exitCode: 0) == inspected, "REQ80 exact complete backend-admitted tuple is accepted as provider evidence only")
        for mutation in ["engineName", "registrySha256", "admittedProvider", "wineSha256", "qualified", "ready"] {
            var object = try JSONSerialization.jsonObject(with: inspectionBytes) as! [String: Any]
            object[mutation] = mutation == "qualified" ? true : mutation == "ready" ? false : "wrong"
            do {
                _ = try EngineInspection.decode(JSONSerialization.data(withJSONObject: object),
                    engine: "candidate", registryDigest: digest, exitCode: 0)
                check(false, "REQ80 rejects mismatched \(mutation)")
            } catch { check(true, "REQ80 rejects mismatched \(mutation)") }
        }
        for mutation in ["missing", "extra", "duplicate"] {
            var object = try JSONSerialization.jsonObject(with: inspectionBytes) as! [String: Any]
            let malformed: Data
            if mutation == "duplicate" {
                malformed = Data(("{\"ready\":false," + String(decoding: inspectionBytes.dropFirst(), as: UTF8.self)).utf8)
            } else {
                if mutation == "missing" { object.removeValue(forKey: "error") }
                else { object["unexpected"] = true }
                malformed = try JSONSerialization.data(withJSONObject: object)
            }
            do {
                _ = try EngineInspection.decode(malformed, engine: "candidate", registryDigest: digest, exitCode: 0)
                check(false, "REQ80 rejects \(mutation) contract fields")
            } catch { check(true, "REQ80 rejects \(mutation) contract fields") }
        }
        let unadmitted = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: digest, engineName: "candidate", declaredProvider: "calimocho",
            admittedProvider: nil, admission: "unadmitted", ready: false, qualified: false,
            wineSha256: String(repeating: "b", count: 64), wineserverSha256: String(repeating: "c", count: 64),
            error: .init(code: "PROVIDER_NOT_ADMITTED", message: "This provider is not admitted."))
        check(try EngineInspection.decode(JSONEncoder().encode(unadmitted), engine: "candidate",
            registryDigest: digest, exitCode: 1) == unadmitted,
              "REQ80 typed unadmitted declaration is observable but cannot become a usable provider")
        let selection = AdmittedEngineSelection(registryPath: registryURL.path, inspection: inspected)
        try selection.validate(registryPath: registryURL.path, engineName: "candidate", registryDigest: digest)
        do {
            try selection.validate(registryPath: registryURL.path, engineName: "candidate",
                                   registryDigest: String(repeating: "d", count: 64))
            check(false, "REQ80 stale registry digest cannot reuse admission")
        } catch { check(true, "REQ80 stale registry digest cannot reuse admission") }
        let mockCLI = root.appendingPathComponent("inspection-cli")
        let json = String(decoding: inspectionBytes, as: UTF8.self)
        try Data("""
        #!/bin/sh
        if [ "$2" = "--contract-version" ]; then
          printf '%s\\n' '{"schemaVersion":1,"capability":"engineAdmissionV1","supported":true}'
        else
          printf '%s\\n' '\(json)'
        fi

        """.utf8).write(to: mockCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mockCLI.path)
        let inspector = EngineInspectionClient()
        let observed = try await inspector.inspect(executable: mockCLI, registry: registryURL,
                                                   engine: "candidate", expectedDigest: digest)
        check(observed == inspected, "REQ80 synthetic CLI supports real capability probe then exact digest inspection")
        let backend = BackendConfiguration(executable: mockCLI, stateDirectory: root)
        try await inspector.validateLaunch(configuration: backend, arguments: [
            "--engine", "candidate", "--registry", registryURL.path, "--expected-registry-sha256", digest
        ], selection: selection)
        check(true, "REQ80 fresh actual-executable inspection validates the persisted tuple before launch")
        try Data("""
        #!/bin/sh
        if [ "$2" = "--contract-version" ]; then
          printf '%s\\n' '{"schemaVersion":1,"capability":"engineAdmissionV1","supported":true}'
        else
          printf '%s\\n' '\(json.replacingOccurrences(of: String(repeating: "b", count: 64), with: String(repeating: "d", count: 64)))'
        fi

        """.utf8).write(to: mockCLI)
        do {
            try await inspector.validateLaunch(configuration: backend, arguments: [
                "--engine", "candidate", "--registry", registryURL.path, "--expected-registry-sha256", digest
            ], selection: selection)
            check(false, "REQ80 changed live Wine identity cannot reuse persisted admission")
        } catch NativeLaunchError.selectionChanged {
            check(true, "REQ80 changed live Wine identity cannot reuse persisted admission")
        }
        for reason in ["ENGINE_REGISTRY_DIGEST_MISMATCH", "Engine wineserver is missing"] {
            let failure = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
                registrySha256: nil, engineName: "candidate", declaredProvider: nil,
                admittedProvider: nil, admission: nil, ready: false, qualified: false,
                wineSha256: nil, wineserverSha256: nil,
                error: .init(code: "ENGINE_INSPECTION_FAILED", message: reason))
            let response = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
            let launched = root.appendingPathComponent("must-not-launch-\(UUID().uuidString)")
            try Data("""
            #!/bin/sh
            if [ "$1" != "engine-inspect" ]; then
              /usr/bin/touch '\(launched.path)'
              exit 91
            fi
            if [ "$2" = "--contract-version" ]; then
              printf '%s\\n' '{"schemaVersion":1,"capability":"engineAdmissionV1","supported":true}'
            else
              printf '%s\\n' '\(response)'
              exit 1
            fi

            """.utf8).write(to: mockCLI)
            let lifecycle = NativeGameLifecycle()
            var preparedPrefix = false
            do {
                _ = try await lifecycle.run(configuration: backend, accountHash: String(repeating: "a", count: 64),
                    operation: "launch", product: "FIXTURE00001", gameDirectory: root,
                    runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent(UUID().uuidString),
                    launchArguments: ["--engine", "candidate", "--registry", registryURL.path,
                                      "--expected-registry-sha256", digest], engineSelection: selection,
                    prepareAdmittedPrefix: { preparedPrefix = true })
                check(false, "REQ95 fresh inspection failure must stop lifecycle before launch")
            } catch {
                let message = InstalledGamesController.nativeLaunchFailureMessage(error)
                check(error is EngineInspectionError && error.localizedDescription.contains(reason)
                      && message == error.localizedDescription && message != InstalledGameActionCopy.launchUnavailable
                      && InstalledGamesController.launchFailureOpensEngines(error)
                      && !preparedPrefix
                      && !FileManager.default.fileExists(atPath: launched.path) && lifecycle.stateDirectory == nil,
                      "REQ95 native lifecycle rejection retains \(reason) diagnostically with its specific Play failure and Engines action before spawn or state writes")
            }
        }
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: mockCLI)
        do {
            _ = try await inspector.inspect(executable: mockCLI, registry: registryURL, engine: "candidate")
            check(false, "REQ80 old CLI capability failure cannot masquerade as supported")
        } catch EngineInspectionError.unsupported {
            check(true, "REQ80 old CLI capability failure cannot masquerade as supported")
        }
        let declaredRegistry = root.appendingPathComponent("declared.json")
        try Data("""
        {"engines":[{"name":"candidate","kind":"free","wine":"\(executable.path)",
        "smoke_test":{"status":"pass"},"provider":{"id":"calimocho","contract_version":1}}]}
        """.utf8).write(to: declaredRegistry)
        let declared = try NativeEngineRegistry.read(declaredRegistry).engines[0]
        check(!EngineManagementPolicy.matches(declared, provider: .standaloneWine),
              "REQ80 untrusted Calimocho declarations are not generic Wine menu entries")
        let primary = root.appendingPathComponent("xgameruntime.dll")
        try Data("neutral primary".utf8).write(to: primary)
        try Data("neutral legacy".utf8).write(to: root.appendingPathComponent("xgameruntime_legacy.dll"))
        let runtime = try NativeRuntimeReference.capture(primary)
        defaults.set(declaredRegistry.path, forKey: "Xodus.lifecycle.registry")
        let game = InstalledGame(id: UUID(), title: "Neutral", identityName: "Neutral", version: "1.0.0.0",
            storeId: "FIXTURE00001", folder: root.path, launcher: "", importedAt: Date(), usesNativeLifecycle: true)
        try bytes.write(to: registryURL)
        defaults.set(registryURL.path, forKey: "Xodus.lifecycle.registry")
        defaults.set("cross", forKey: "Xodus.lifecycle.engine.crossover")
        let verifiedCrossOver = CrossOverDependencyState.installed(.init(
            location: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            version: "26.3", buildVersion: "26.3.0.39832"))
        for state in [CrossOverDependencyState.absent, .unverified, .notChecked, .checking, verifiedCrossOver] {
            for recipePinned in [false, true] {
                do {
                    let resolved = try NativeLaunchConfiguration.resolve(game: game,
                        provider: recipePinned ? nil : .crossover, defaults: defaults, runtime: runtime,
                        provenEngine: recipePinned ? "cross" : nil, detectCrossOver: { state })
                    check(state.isVerified && resolved.engine == "cross",
                          "REQ79 CrossOver resolver requires current verified dependency for \(recipePinned ? "pinned" : "explicit") route: \(state.title)")
                } catch NativeLaunchError.engineUnavailable {
                    check(!state.isVerified,
                          "REQ79 CrossOver resolver refuses unavailable dependency without fallback: \(state.title)")
                }
            }
            defaults.set("fixture", forKey: "Xodus.lifecycle.engine.standaloneWine")
            let generic = try NativeLaunchConfiguration.resolve(game: game, provider: .standaloneWine,
                defaults: defaults, runtime: runtime, detectCrossOver: { state })
            check(generic.engine == "fixture",
                  "REQ79 generic Wine resolution is independent of CrossOver dependency: \(state.title)")
        }
        defaults.set(declaredRegistry.path, forKey: "Xodus.lifecycle.registry")
        do {
            _ = try NativeLaunchConfiguration.resolve(game: game, provider: nil, defaults: defaults,
                                                      runtime: runtime, provenEngine: "candidate")
            check(false, "REQ80 declared Calimocho cannot resolve without saved backend admission")
        } catch NativeLaunchError.engineUnavailable {
            check(true, "REQ80 declared Calimocho cannot resolve without saved backend admission")
        }
        let overlayProfile = NativeTitleLaunchProfile(version: 1, productID: "FIXTURE00001",
            engine: "candidate", shimDirectory: nil, environment: [:], prefixOverlays: [])
        let overlayLaunch = NativeLaunchConfiguration(engine: "candidate", registry: declaredRegistry,
            prefix: root.appendingPathComponent("must-not-create"), runtime: runtime, profile: overlayProfile,
            shims: .approved, admittedSelection: selection)
        do {
            _ = try await overlayLaunch.arguments()
            check(false, "REQ80 derived registries cannot bypass exact admitted registry bytes")
        } catch NativeLaunchError.invalidProfile {
            check(true, "REQ80 derived registries are refused before generating any launch artifact")
        }
        await observation.refresh(path: declaredRegistry.path, allowsFileReads: true, executable: mockCLI)
        check(observation.inspections.isEmpty && observation.inspectionMessage != nil,
              "REQ80 unsupported installed CLI yields explicit provider-unavailable guidance")
        let started = root.appendingPathComponent("inspection-started")
        try Data("""
        #!/bin/sh
        if [ "$2" = "--contract-version" ]; then
          printf '%s\\n' '{"schemaVersion":1,"capability":"engineAdmissionV1","supported":true}'
        else
          /usr/bin/touch '\(started.path)'
          exec /bin/sleep 30
        fi

        """.utf8).write(to: mockCLI)
        let delayed = Task { try await inspector.inspect(executable: mockCLI, registry: registryURL, engine: "candidate") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(FileManager.default.fileExists(atPath: started.path), "REQ80 cancellation fixture reached its owned child")
        delayed.cancel()
        do {
            _ = try await delayed.value
            check(false, "REQ80 cancellation cannot publish provider success")
        } catch is CancellationError {
            check(true, "REQ80 cancellation cannot publish provider success")
        }
        check(!(await inspector.hasOwnedProcess), "REQ80 cancellation joins its exact subprocess before returning")
        if let sourceBackend = ProcessInfo.processInfo.environment["XODUS_ENGINE_INSPECTION_TEST_BACKEND"] {
            let server = root.appendingPathComponent("wineserver")
            try Data("neutral server, never executed".utf8).write(to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
            func hash(_ bytes: Data) -> String {
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            var record: [String: Any] = [
                "name": "fixture-engine", "kind": "free", "wine": executable.path,
                "wineserver": server.path, "sha256": hash(try Data(contentsOf: executable)),
                "wineserver_sha256": hash(try Data(contentsOf: server)),
                "smoke_test": ["status": "pass"]
            ]
            for declared in [false, true] {
                if declared { record["provider"] = ["id": "calimocho", "contract_version": 1] }
                let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "engines": [record]])
                try data.write(to: registryURL)
                let actual = try await inspector.inspect(executable: URL(fileURLWithPath: sourceBackend),
                    registry: registryURL, engine: "fixture-engine", expectedDigest: hash(data))
                check(actual.registrySha256 == hash(data) && actual.engineName == "fixture-engine"
                      && !actual.qualified && actual.admittedProvider == nil
                      && (declared
                          ? actual.admission == "unadmitted" && !actual.ready
                              && actual.error?.code == "PROVIDER_NOT_ADMITTED"
                          : actual.admission == "genericWine" && actual.ready && actual.error == nil),
                      "REQ80 actual source backend projection matches consumer: \(declared ? "unadmitted Calimocho" : "generic Wine")")
            }
        }
        let settings = RuntimeProviderSettings(detectCrossOver: { .absent })
        settings.select(.calimocho)
        check(RuntimeProviderSettings.providerChoices == [.calimocho]
              && settings.planningBlocker?.contains("verified registry selection") == true,
              "REQ95 current choices are Calimocho-only and do not invent a backend runtime-plan capability")
        try await selectionPersistenceChecks(root: root, check: check)
        await settings.refreshCrossOverDependency()
        for width in [CGFloat(440), CGFloat(560)] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: EngineProviderOverview(settings: settings, allowsCheck: false)
                    .padding().frame(width: width, height: 600, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                host.appearance = NSAppearance(named: appearance)
                host.sizingOptions = []
                host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
                host.layoutSubtreeIfNeeded()
                check(host.window == nil && host.fittingSize.height <= 600,
                      "REQ79 native provider rows fit \(Int(width))pt \(appearance.rawValue) without a live window")
                if let destination = ProcessInfo.processInfo.environment["XODUS_ENGINE_RENDER_DIRECTORY"] {
                    let output = URL(fileURLWithPath: destination)
                        .appendingPathComponent("providers-\(Int(width))-\(appearance.rawValue).png")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw EngineInspectionError.failed
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw EngineInspectionError.failed
                    }
                    try png.write(to: output)
                }

            }
        }
    }

    private static func selectionPersistenceChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let largeRegistry = root.appendingPathComponent("many-generic-engines.json")
        let invocation = root.appendingPathComponent("must-not-inspect-generic")
        let unusedInspector = root.appendingPathComponent("unused-inspector")
        try Data("#!/bin/sh\ntouch '\(invocation.path)'\nexit 91\n".utf8).write(to: unusedInspector)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unusedInspector.path)
        var genericRecords: [[String: Any]] = (0..<28).map {
            ["name": "generic-\($0)", "kind": "free", "wine": "/synthetic/wine",
             "smoke_test": ["status": "pass"]]
        }
        try JSONSerialization.data(withJSONObject: ["engines": genericRecords]).write(to: largeRegistry)
        let genericObservation = EngineRegistryObservation()
        await genericObservation.refresh(path: largeRegistry.path, allowsFileReads: true, executable: unusedInspector)
        check(genericObservation.status == .detected && genericObservation.entries.count == 28
              && genericObservation.inspectionMessage == nil && genericObservation.inspections.isEmpty
              && !FileManager.default.fileExists(atPath: invocation.path),
              "COR167: Generic free Wine registries never consume Calimocho admission slots or execute inspection")
        for index in genericRecords.indices {
            genericRecords[index]["provider"] = ["id": "calimocho", "contract_version": 1]
        }
        try JSONSerialization.data(withJSONObject: ["engines": genericRecords]).write(to: largeRegistry)
        await genericObservation.refresh(path: largeRegistry.path, allowsFileReads: true, executable: unusedInspector)
        check(genericObservation.inspectionMessage?.contains("at most 16") == true
              && !FileManager.default.fileExists(atPath: invocation.path),
              "COR167: Declared Calimocho candidates retain the bounded admission cap without inspecting excess records")
        let suite = "REQ95-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NativeLaunchError.invalidProfile }
        defer { defaults.removePersistentDomain(forName: suite) }
        let wine = root.appendingPathComponent("selected-wine")
        let server = root.appendingPathComponent("selected-wineserver")
        let registry = root.appendingPathComponent("selected-registry.json")
        let prefix = root.appendingPathComponent("selected-prefix")
        for file in [wine, server] {
            try Data("#!/bin/sh\nexit 91\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let wineHash = hash(try Data(contentsOf: wine)), serverHash = hash(try Data(contentsOf: server))
        let record: [String: Any] = [
            "engines": [
                [
                    "name": "exact-calimocho", "kind": "free", "wine": wine.path, "wineserver": server.path,
                    "sha256": wineHash, "wineserver_sha256": serverHash, "smoke_test": ["status": "pass"],
                    "provider": ["id": "calimocho", "contract_version": 1],
                ],
                [
                    "name": "alternate-calimocho", "kind": "free", "wine": wine.path, "wineserver": server.path,
                    "sha256": wineHash, "wineserver_sha256": serverHash, "smoke_test": ["status": "pass"],
                    "provider": ["id": "calimocho", "contract_version": 1],
                ]
            ]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try bytes.write(to: registry)
        let inspection = EngineInspection(
            schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: hash(bytes), engineName: "exact-calimocho", declaredProvider: "calimocho",
            admittedProvider: "calimocho", admission: "admitted", ready: true, qualified: false,
            wineSha256: wineHash, wineserverSha256: serverHash, error: nil)
        let selection = AdmittedEngineSelection(registryPath: registry.path, inspection: inspection)
        let alternateInspection = EngineInspection(
            schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: hash(bytes), engineName: "alternate-calimocho", declaredProvider: "calimocho",
            admittedProvider: "calimocho", admission: "admitted", ready: true, qualified: false,
            wineSha256: wineHash, wineserverSha256: serverHash, error: nil)
        let alternate = AdmittedEngineSelection(registryPath: registry.path, inspection: alternateInspection)
        check(try NativeEngineSettings.defaultAdmissionName(defaults: defaults) == NativeEngineDefaults.read().defaultEngine,
              "COR167: Settings uses the bundled launch default when no saved admission exists, never legacy None")
        try NativeEngineSettings.persistDefaultAdmission(alternate, defaults: defaults)
        let savedDefault = defaults.data(forKey: NativeEngineDefaults.preferenceKey)
            .flatMap { try? JSONDecoder().decode(AdmittedEngineSelection.self, from: $0) }
        check(try savedDefault == alternate
              && NativeEngineSettings.defaultAdmissionName(defaults: defaults) == alternate.inspection.engineName
              && EngineDefaults.defaultEngine(defaults) == .calimocho,
              "COR167: Set Default stores the exact bounded binding admission consumed by launch and updates its readable identity")
        for invalid in ["invalid saved type", Data("invalid saved admission".utf8)] as [Any] {
            defaults.set(invalid, forKey: NativeEngineDefaults.preferenceKey)
            do {
                _ = try NativeEngineSettings.defaultAdmissionName(defaults: defaults)
                check(false, "COR167: Invalid saved default is reported instead of silently displaying a fallback")
            } catch {
                check(true, "COR167: Invalid saved default is reported instead of silently displaying a fallback")
            }
        }
        defaults.removeObject(forKey: NativeEngineDefaults.preferenceKey)
        defaults.set(try JSONEncoder().encode(selection), forKey: AdmittedEngineSelection.preferenceKey)
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        guard let reloadedDefaults = UserDefaults(suiteName: suite) else { throw NativeLaunchError.invalidProfile }
        check(try AdmittedEngineSelection.read(defaults: reloadedDefaults) == selection
              && EngineDefaults.defaultEngine(reloadedDefaults) == .calimocho,
              "REQ95 global default and its exact admission survive a fresh defaults reader")
        let storeURL = root.appendingPathComponent("selected-games.json")
        let store = InstalledGameStore(file: storeURL)
        var game = InstalledGame(
            id: UUID(), title: "Synthetic", identityName: "Synthetic", version: "1",
            storeId: "FIXTURE00001", folder: root.path, launcher: "", importedAt: Date(), usesNativeLifecycle: true)
        _ = try await store.upsert(game)
        _ = try await store.setEngineOverride(id: game.id, override: .calimocho, selection: selection)
        guard let reloaded = try await InstalledGameStore(file: storeURL).load().first else {
            throw InstalledGameError.invalidRegistry
        }
        game = reloaded
        check(
            game.engineOverride == .calimocho && game.engineSelection == selection,
            "REQ95 exact Calimocho registry/engine/Wine/server admission survives per-game save and fresh-store reload")
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        defaults.set("missing-default-registry", forKey: "Xodus.lifecycle.registry")
        defaults.removeObject(forKey: AdmittedEngineSelection.preferenceKey)
        let primary = root.appendingPathComponent("selected-runtime/xgameruntime.dll")
        try FileManager.default.createDirectory(
            at: primary.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("synthetic runtime".utf8).write(to: primary)
        try Data("synthetic legacy".utf8).write(
            to: primary.deletingLastPathComponent().appendingPathComponent("xgameruntime_legacy.dll"))
        let runtime = try NativeRuntimeReference.capture(primary)
        defaults.set(registry.path, forKey: "Xodus.lifecycle.registry")
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        let mock = root.appendingPathComponent("default-selection-cli")
        let reply = String(decoding: try JSONEncoder().encode(inspection), as: UTF8.self)
        let alternateReply = String(decoding: try JSONEncoder().encode(alternateInspection), as: UTF8.self)
        try Data("""
            #!/bin/sh
            if [ "$2" = "--contract-version" ]; then
              printf '%s\\n' '{"schemaVersion":1,"capability":"engineAdmissionV1","supported":true}'
            else
              case " $* " in
                *" --engine alternate-calimocho "*) printf '%s\\n' '\(alternateReply)' ;;
                *) printf '%s\\n' '\(reply)' ;;
              esac
            fi

            """.utf8).write(to: mock)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let backend = BackendConfiguration(executable: mock, stateDirectory: root)
        let defaultCatalog = NativeEngineDefaults(version: 1, defaultEngine: "exact-calimocho", bindings: [
            NativeEngineDefaults.Binding(registryPath: registry.path, registrySha256: hash(bytes),
                engineName: "exact-calimocho", wineSha256: wineHash, wineserverSha256: serverHash)
        ])
        EngineDefaults.setDefaultEngine(nil, defaults)
        let initialLaunch = try await NativeLaunchConfiguration.resolveDefault(game: game,
            configuration: backend, provider: nil, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
        check(initialLaunch.admittedSelection == selection && EngineDefaults.defaultEngine(defaults) == .calimocho,
              "COR132: An unset Settings provider initializes only the verified configured Calimocho default")
        for legacy in [nil, .crossover, .gptk3, .gptk4, .standaloneWine, .calimocho] as [RuntimeProviderKind?] {
            var savedGame = game
            savedGame.engineOverride = legacy
            savedGame.engineSelection = AdmittedEngineSelection(registryPath: "/removed/per-game-registry",
                inspection: inspection)
            let before = savedGame
            let current = try await NativeLaunchConfiguration.resolveDefault(game: savedGame,
                configuration: backend, provider: EngineDefaults.defaultEngine(defaults),
                defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
            check(current.engine == "exact-calimocho" && current.registry == registry
                  && current.admittedSelection == selection && savedGame == before,
                  "COR132: Settings default resolves exact admitted identity and preserves ignored per-game \(String(describing: legacy)) data")
        }
        check(try JSONDecoder().decode(AdmittedEngineSelection.self,
                  from: defaults.data(forKey: NativeEngineDefaults.preferenceKey) ?? Data()) == selection,
              "COR132: First verified implicit default persists in its own settings key, not legacy registry preferences")
        _ = try await store.setEngineOverrideV2(id: game.id, selection: alternate)
        let explicit = try await store.load()[0]
        check(explicit.engineOverrideV2?.version == 2 && explicit.engineOverrideV2?.selection == alternate
              && explicit.engineSelection == game.engineSelection && explicit.engineOverride == game.engineOverride,
              "COR134: Optional menu override survives reload in a versioned field without migrating legacy choices")
        let perGameBytes = try Data(contentsOf: storeURL)
        try NativeEngineSettings.persistDefaultAdmission(selection, defaults: defaults)
        check(try Data(contentsOf: storeURL) == perGameBytes
              && NativeEngineSettings.defaultAdmissionName(defaults: defaults) == selection.inspection.engineName,
              "COR167: Settings Set Default leaves the persisted per-game V2 override unchanged")
        let explicitLaunch = try await NativeLaunchConfiguration.resolveDefault(game: explicit, configuration: backend,
            provider: .calimocho, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
        check(explicitLaunch.admittedSelection == alternate && explicitLaunch.engine == "alternate-calimocho",
              "COR134: Only the explicit versioned override is consumed, with fresh admission before launch")
        let invalidOverrideData = try JSONEncoder().encode(explicit)
        var invalidObject = try JSONSerialization.jsonObject(with: invalidOverrideData) as? [String: Any] ?? [:]
        var invalidOverride = invalidObject["engineOverrideV2"] as? [String: Any] ?? [:]
        invalidOverride["version"] = 1
        invalidObject["engineOverrideV2"] = invalidOverride
        let invalidGame = try JSONDecoder().decode(InstalledGame.self,
            from: JSONSerialization.data(withJSONObject: invalidObject))
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: invalidGame, configuration: backend,
                provider: .calimocho, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
            check(false, "COR134: An unknown override version never silently becomes Settings default")
        } catch NativeLaunchError.selectionChanged {
            check(true, "COR134: An unknown override version never silently becomes Settings default")
        }
        _ = try await store.setEngineOverrideV2(id: game.id, selection: nil)
        let clearedOverride = try await store.load()[0]
        check(clearedOverride.engineOverrideV2 == nil && clearedOverride.engineSelection == game.engineSelection
              && clearedOverride.engineOverride == game.engineOverride,
              "COR134: Use default clears only the current optional override and preserves historical engine data")
        let defaultLaunch = try await NativeLaunchConfiguration.resolveDefault(game: clearedOverride, configuration: backend,
            provider: .calimocho, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
        let persistedDefault = try JSONDecoder().decode(AdmittedEngineSelection.self,
            from: defaults.data(forKey: NativeEngineDefaults.preferenceKey) ?? Data())
        check(defaultLaunch.admittedSelection == selection
              && persistedDefault == selection,
              "COR134: Clearing a different override returns to Settings default without changing that default")
        let nms = InstalledGame(id: UUID(), title: "No Man's Sky", identityName: "HelloGames.NoMansSky",
            version: "7.6.0.0", storeId: "BQVQTL3PCH05", folder: root.path, launcher: "", importedAt: Date())
        for folder in ["Xode", "Xodus"] {
            let located = InstalledGame(id: nms.id, title: nms.title, identityName: nms.identityName,
                version: nms.version, storeId: nms.storeId,
                folder: root.appendingPathComponent("Games/\(folder)/NoMansSky-Xbox").path,
                launcher: "", importedAt: nms.importedAt)
            check(NativeLaunchConfiguration.permitsPreservedNMSInstallation(located, home: root.path),
                  "COR180: Exact NMS installation under \(folder) retains its existing qualified prefix binding")
            let wrongProduct = InstalledGame(id: nms.id, title: nms.title, identityName: nms.identityName,
                version: nms.version, storeId: "FIXTURE00001", folder: located.folder,
                launcher: "", importedAt: nms.importedAt)
            check(!NativeLaunchConfiguration.permitsPreservedNMSInstallation(wrongProduct, home: root.path),
                  "COR180: Root compatibility cannot lend the preserved NMS prefix to another product")
        }
        check(!NativeLaunchConfiguration.permitsPreservedNMSInstallation(nms, home: root.path),
              "COR180: Arbitrary custom paths cannot borrow the preserved-prefix exception")
        do {
            try NativeLaunchConfiguration.validateOverride(alternate, game: nms, defaults: defaults)
            check(false, "COR134: A conflicting override cannot be offered or saved for a pinned title")
        } catch NativeLaunchError.configurationConflict {
            check(true, "COR134: A conflicting override cannot be offered or saved for a pinned title")
        }
        let nmsInspection = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: "170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609",
            engineName: "calimocho-wine11.20-gptk4b3-tls-vulkan-private", declaredProvider: "calimocho",
            admittedProvider: "calimocho", admission: "admitted", ready: true, qualified: false,
            wineSha256: wineHash, wineserverSha256: serverHash, error: nil)
        try NativeLaunchConfiguration.validateOverride(
            AdmittedEngineSelection(registryPath: registry.path, inspection: nmsInspection), game: nms, defaults: defaults)
        check(true, "COR134: Exact pinned title identity remains eligible for fresh admission before saving")
        try Data((String(decoding: bytes, as: UTF8.self) + "\n").utf8).write(to: registry)
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: game, configuration: backend,
                provider: .calimocho, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
            check(false, "COR132: Changed registry cannot reuse a default admission")
        } catch { check(true, "COR132: Changed registry cannot reuse a default admission") }
        try bytes.write(to: registry)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        defaults.set("missing-default-registry", forKey: "Xodus.lifecycle.registry")
        let resolved = try NativeLaunchConfiguration.resolve(
            game: game, provider: .calimocho,
            defaults: defaults, runtime: runtime)
        let actual = try NativeEngineRegistry.read(resolved.registry).engines[0]
        check(
            resolved.engine == "exact-calimocho" && resolved.registry == registry
                && resolved.admittedSelection == selection && actual.wine == wine.path
                && actual.wineserver == server.path && actual.sha256 == wineHash
                && actual.wineserver_sha256 == serverHash && EngineDefaults.defaultEngine(defaults) == .crossover,
            "REQ95 reloaded per-game identity wins over independently changed global default/registry/admission, resolving exact Wine and server"
        )
        for field in ["ready", "admission", "qualified"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inspection)) as? [String: Any] ?? [:]
            if field == "admission" { object[field] = "unadmitted" }
            else { object[field] = field == "qualified" }
            let invalid = try JSONDecoder().decode(EngineInspection.self,
                from: JSONSerialization.data(withJSONObject: object))
            do {
                try AdmittedEngineSelection(registryPath: registry.path, inspection: invalid)
                    .validate(registryPath: registry.path, engineName: resolved.engine, registryDigest: hash(bytes))
                check(false, "REQ95 invalid \(field) cannot qualify a saved selection")
            } catch NativeLaunchError.providerNotAdmitted {
                check(true, "REQ95 invalid \(field) refuses artifact admission rather than granting gameplay qualification")
            }
        }
        do {
            _ = try await store.setEngineOverride(id: game.id, override: .calimocho)
            check(false, "REQ95 an enum alone cannot persist a Calimocho configuration")
        } catch NativeLaunchError.engineNotSelected {
            check(true, "REQ95 an enum alone cannot persist a Calimocho configuration")
        }
        let shimFolder = root.appendingPathComponent("selected-shims")
        try FileManager.default.createDirectory(at: shimFolder, withIntermediateDirectories: false)
        var shimHashes: [String: String] = [:]
        for name in ["windows.web.dll", "XCurl.dll", "cacert.pem"] {
            let data = Data("synthetic \(name)".utf8)
            try data.write(to: shimFolder.appendingPathComponent(name))
            shimHashes[name] = hash(data)
        }
        let launch = NativeLaunchConfiguration(
            engine: resolved.engine, registry: registry, prefix: prefix,
            runtime: runtime, profile: nil, shims: .init(directory: shimFolder, hashes: shimHashes),
            admittedSelection: selection)
        let arguments = try await launch.arguments()
        check(arguments == ["--engine", resolved.engine, "--registry", registry.path,
                            "--expected-registry-sha256", hash(bytes), "--prefix", prefix.path,
                            "--runtime-dll", primary.path, "--shim-dir", shimFolder.path]
                            + QualificationDiagnostics.arguments(provider: selection.inspection.admittedProvider),
              "REQ95 actual launch arguments carry the reloaded exact registry digest/engine/prefix/runtime, not an enum selector")
        do {
            func admitted(_ name: String, _ provider: String) -> AdmittedEngineSelection {
                AdmittedEngineSelection(registryPath: "/tmp/\(name).json", inspection: EngineInspection(
                    schemaVersion: 1, capability: "engineAdmissionV1", registrySha256: String(repeating: "a", count: 64),
                    engineName: name, declaredProvider: provider, admittedProvider: provider, admission: "admitted",
                    ready: true, qualified: false, wineSha256: String(repeating: "b", count: 64),
                    wineserverSha256: String(repeating: "c", count: 64), error: nil))
            }
            let picker = RuntimeInstallationPicker.defaultEngineChoices(
                available: [admitted("calimocho-11.20-4.0b3-06", "calimocho"), admitted("crossover-26.3-mvk142", "crossover"),
                            admitted("highball-x64-crossover26.3-r27", "highball")],
                failed: ["crossover-26.3-mvk142"])
            check(picker.map(\.id) == ["calimocho-11.20-4.0b3-06"]
                  && EngineConfiguratorSections<EmptyView>.selectableDefaults(
                        [EngineChoice.named("a", ready: true), EngineChoice.named("b", ready: false),
                         EngineChoice.named("c", ready: true, playable: false)]).map(\.id) == ["a"]
                  && !picker.contains { $0.id.hasPrefix("crossover") || $0.name.localizedCaseInsensitiveContains("CrossOver") },
                  "REQ109 CrossOver is never offered in the Default Engine picker, even when admitted or failing")
            let app = CrossOverInstallation(location: URL(fileURLWithPath: "/Applications/CrossOver.app"),
                                            version: "26.3", buildVersion: "26.3.0")
            check(CrossOverEngineRow.presentation(state: .installed(app)) == .init(state: .ready, detail: "26.3 · No Man's Sky only")
                  && CrossOverEngineRow.presentation(state: .absent)
                    == .init(state: .notInstalled, detail: "No Man's Sky only · from CodeWeavers")
                  && CrossOverEngineRow.presentation(state: .unverified) == .init(state: .couldntVerify, detail: "No Man's Sky only")
                  && CrossOverEngineRow.presentation(state: .checking).state == .verifying
                  && CrossOverEngineRow.presentation(state: .notChecked) == .init(state: nil, detail: "No Man's Sky only"),
                  "COR-279 F1/F2: CrossOver is always listed; Verifying only while a check runs, no badge before one")
            check(HighballEngineRow.presentation(.missing) == (.notInstalled, "Brotato only · open source")
                  && HighballEngineRow.presentation(.qualified(version: "1.2", productID: "9P9VNSQK1W3K")) == (.ready, "1.2 · Brotato only")
                  && HighballEngineRow.presentation(.detected(version: "1.2", blocker: nil)) == (.notQualified, "1.2 · Brotato only")
                  && HighballEngineRow.presentation(nil) == (nil, "Brotato only"),
                  "COR-279 F3: Highball is always listed; never Not Installed before a detection")
            check(EngineRowState.allCases.map(\.title)
                    == ["Ready", "Update Available", "Not Installed", "Verifying", "Couldn't Verify", "Not Qualified", "Testing Only"]
                  && EngineRowState.subtitle(["Wine 11.20"], isDefault: true) == "Wine 11.20 · Default"
                  && EngineConfiguratorSections<EmptyView>.state(for: EngineChoice.named("x", ready: true), checking: false) == .ready
                  && EngineConfiguratorSections<EmptyView>.state(for: EngineChoice.named("x", ready: true, playable: false), checking: false) == .testingOnly
                  && EngineConfiguratorSections<EmptyView>.state(for: EngineChoice.named("x", ready: false), checking: true) == .verifying
                  && EngineConfiguratorSections<EmptyView>.state(for: EngineChoice.named("x", ready: false), checking: false) == .couldntVerify,
                  "COR-279 step 2: one status vocabulary; Default is a subtitle suffix that keeps readiness visible")
        }
        #if XODUS_QUALIFICATION
        check(QualificationDiagnostics.arguments(provider: nil) == ["--diagnostic-wine-debug", "warn+gdkc"]
              && QualificationDiagnostics.arguments(provider: AdmittedProviderScope.calimocho) == ["--diagnostic-wine-debug", "warn+gdkc"]
              && QualificationDiagnostics.arguments(provider: AdmittedProviderScope.crossOver).isEmpty
              && QualificationDiagnostics.arguments(provider: AdmittedProviderScope.highball).isEmpty,
              "REQ32 qualification build adds only the fixed warn+gdkc channel, and only on Calimocho routes")
        check(try NativeTitleLaunchProfile.bundledProfiles().filter { $0.runtime?.primarySHA256 == QualificationDiagnostics.pinnedPrimarySHA256 }
                .map(\.productID).sorted() == ["9NR1R1XWLCNB", "9P8DL6W0JBB8", "9PDC8J1BSV8B"]
              && QualificationDiagnostics.pinnedPrimarySHA256 != QualificationDiagnostics.releasePrimarySHA256,
              "REQ32 qualification build runs FH6, Hades and EDC on the 39088c3 outcome-lines pair")
        do {
            let ordinary = "io.github.xodus.qual-import-check.\(UUID().uuidString)"
            let suite = "io.github.xodus.qual-target-check.\(UUID().uuidString)"
            let target = UserDefaults(suiteName: suite)!
            target.set("kept", forKey: "existing")
            UserDefaults.standard.setPersistentDomain(["existing": "ordinary", "imported": "value"], forName: ordinary)
            QualificationDiagnostics.importOrdinaryPreferences(into: target, bundleIdentifier: "qual", ordinary: ordinary)
            let firstImport = target.string(forKey: "imported") == "value" && target.string(forKey: "existing") == "kept"
            UserDefaults.standard.setPersistentDomain(["imported": "changed"], forName: ordinary)
            QualificationDiagnostics.importOrdinaryPreferences(into: target, bundleIdentifier: "qual", ordinary: ordinary)
            let untouched = UserDefaults.standard.persistentDomain(forName: ordinary)?["imported"] as? String == "changed"
            check(firstImport && target.string(forKey: "imported") == "value" && untouched,
                  "REQ32 qualification variant imports the ordinary preferences once, read-only, without overwriting its own")
            UserDefaults.standard.removePersistentDomain(forName: ordinary)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        #else
        check([nil, AdmittedProviderScope.calimocho, AdmittedProviderScope.crossOver, AdmittedProviderScope.highball]
                .allSatisfy { QualificationDiagnostics.arguments(provider: $0).isEmpty },
              "REQ32 ordinary builds pass no diagnostic Wine channels")
        check(QualificationDiagnostics.pinnedPrimarySHA256 == QualificationDiagnostics.releasePrimarySHA256,
              "REQ32 ordinary builds keep the release runtime pair")
        #endif
        check(
            try await launch.prefixNotice() == nil && !FileManager.default.fileExists(atPath: prefix.path),
            "REQ95 fresh-prefix preflight is read-only and does not claim or create a prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
        try Data("preserved".utf8).write(to: prefix.appendingPathComponent("save-fixture"))
        check(
            try await launch.prefixNotice()?.contains("legacy-unclaimed") == true,
            "REQ95 a nonempty unmarked prefix is explicitly legacy-unclaimed, not silently adopted")
        let marker = root.appendingPathComponent(".selected-prefix.xodus-engine-owner.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "engine": "another-engine", "wine_sha256": wineHash])
            .write(to: marker)
        do {
            _ = try await launch.prefixNotice()
            check(false, "REQ95 conflicting prefix ownership must refuse")
        } catch NativeLaunchError.prefixConflict {
            check(true, "REQ95 conflicting prefix ownership refuses before spawn without changing prefix or saves")
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "engine": resolved.engine, "wine_sha256": wineHash])
            .write(to: marker)
        check(
            try await launch.prefixNotice() == nil
                && Data(contentsOf: prefix.appendingPathComponent("save-fixture")) == Data("preserved".utf8),
            "REQ95 matching prefix ownership preserves the existing prefix and synthetic save bytes")
        try Data((String(decoding: bytes, as: UTF8.self) + "\n").utf8).write(to: registry)
        do {
            _ = try NativeLaunchConfiguration.resolve(
                game: game, provider: .calimocho, defaults: defaults, runtime: runtime)
            check(false, "REQ95 drifted registry must refuse")
        } catch NativeLaunchError.selectionChanged {
            check(
                true,
                "REQ95 even semantically equivalent changed registry bytes refuse rather than substitute a global engine"
            )
        }
        try bytes.write(to: registry)
        try FileManager.default.removeItem(at: wine)
        do {
            _ = try NativeLaunchConfiguration.resolve(
                game: game, provider: .calimocho, defaults: defaults, runtime: runtime)
            check(false, "REQ95 missing selected Wine must refuse")
        } catch NativeLaunchError.engineUnavailable {
            check(true, "REQ95 missing selected Wine refuses before any launch or fallback")
        }
        _ = try await store.setEngineOverride(id: game.id, override: nil)
        let cleared = try await InstalledGameStore(file: storeURL).load().first
        check(
            cleared?.engineOverride == nil && cleared?.engineSelection == nil
                && EngineDefaults.defaultEngine(defaults) == .crossover,
            "REQ95 clearing a per-game choice clears its exact binding without changing the global default")
    }
}
