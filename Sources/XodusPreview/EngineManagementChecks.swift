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

    static func run(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            .appendingPathComponent("EngineManagementChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ79 removes only its owned fixture directory") }
        }
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
              && EngineManagementPolicy.calimochoSource.absoluteString == "https://github.com/dragoshont/calimocho"
              && CrossOverDependencyState.trialDownloadURL.absoluteString == "https://www.codeweavers.com/crossover/download",
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
            do {
                _ = try await lifecycle.run(configuration: backend, accountHash: String(repeating: "a", count: 64),
                    operation: "launch", product: "FIXTURE00001", gameDirectory: root,
                    runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent(UUID().uuidString),
                    launchArguments: ["--engine", "candidate", "--registry", registryURL.path,
                                      "--expected-registry-sha256", digest], engineSelection: selection)
                check(false, "REQ95 fresh inspection failure must stop lifecycle before launch")
            } catch {
                let message = InstalledGamesController.nativeLaunchFailureMessage(error)
                check(error is EngineInspectionError && error.localizedDescription.contains(reason)
                      && message == InstalledGameActionCopy.launchUnavailable
                      && !FileManager.default.fileExists(atPath: launched.path) && lifecycle.stateDirectory == nil,
                      "REQ95 native lifecycle rejection retains \(reason) diagnostically with generic Play failure before spawn or state writes")
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
        let explicitLaunch = try await NativeLaunchConfiguration.resolveDefault(game: explicit, configuration: backend,
            provider: .calimocho, defaults: defaults, runtime: runtime, engineDefaults: defaultCatalog)
        check(explicitLaunch.admittedSelection == alternate && explicitLaunch.engine == "alternate-calimocho",
              "COR134: Only the explicit versioned override is consumed, with fresh admission before launch")
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
                            "--runtime-dll", primary.path, "--shim-dir", shimFolder.path],
              "REQ95 actual launch arguments carry the reloaded exact registry digest/engine/prefix/runtime, not an enum selector")
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
