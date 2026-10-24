// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
enum EngineManagementChecks {
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
        } catch EngineInspectionError.invalidResponse {
            check(true, "REQ80 changed live Wine identity cannot reuse persisted admission")
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
}
