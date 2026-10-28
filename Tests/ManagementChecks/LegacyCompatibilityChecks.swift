// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeLegacyCompatibility

extension Checks {
    /// REQ-150: the one compatibility adapter maps renamed identities and imports old preferences
    /// once, without overwriting newer values or touching the old domain.
    func legacyCompatibilityChecks() {
        let current = LegacyCompatibility.currentBundleIdentifier
        let legacy = LegacyCompatibility.legacyBundleIdentifier
        check(LegacyCompatibility.legacyBundleIdentifier(for: current) == legacy
              && LegacyCompatibility.legacyBundleIdentifier(for: current + ".development") == legacy + ".development"
              && LegacyCompatibility.legacyBundleIdentifier(for: current + ".qualification") == legacy + ".qualification"
              && LegacyCompatibility.legacyBundleIdentifier(for: current + ".credential-broker") == legacy + ".credential-broker"
              && LegacyCompatibility.legacyBundleIdentifier(for: current + "x") == nil
              && LegacyCompatibility.legacyBundleIdentifier(for: nil) == nil,
              "REQ-150: Each renamed bundle ID variant maps to its pre-rename ID; unrelated IDs do not")

        let suite = "req150.preferences.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "REQ-150: Preference import suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldPrefix = LegacyCompatibility.legacyKeyPrefixes[0].0
        let oldKey = oldPrefix + "lifecycle.registry"
        defaults.set("/kept/new", forKey: "Ode.lifecycle.engine.crossover")
        let old: [String: Any] = [oldKey: "/old/registry.json",
                                  oldPrefix + "lifecycle.engine.crossover": "/old/engine",
                                  "unprefixed": 3]
        let copied = LegacyCompatibility.importLegacyPreferences(into: defaults, bundleIdentifier: current + ".development",
                                                                 legacyDomain: old)
        check(copied == 2 && defaults.string(forKey: "Ode.lifecycle.registry") == "/old/registry.json"
              && defaults.string(forKey: "Ode.lifecycle.engine.crossover") == "/kept/new"
              && defaults.integer(forKey: "unprefixed") == 3 && defaults.object(forKey: oldKey) == nil
              && old.count == 3,
              "REQ-150: Old preferences are copied under renamed keys; newer values win; the old domain is only read")
        check(LegacyCompatibility.importLegacyPreferences(into: defaults, bundleIdentifier: current + ".development",
                                                          legacyDomain: ["Ode.recentGameSearches": ["late"]]) == 0
              && defaults.object(forKey: "Ode.recentGameSearches") == nil,
              "REQ-150: Preferences are imported once")
        check(LegacyCompatibility.importLegacyPreferences(into: UserDefaults(suiteName: suite + ".unbundled")!,
                                                          bundleIdentifier: nil, legacyDomain: old) == 0,
              "REQ-150: An unbundled run imports nothing")
        UserDefaults(suiteName: suite + ".unbundled")?.removePersistentDomain(forName: suite + ".unbundled")

        check(LegacyCompatibility.legacyKeychainService(for: "Ode Library") != nil
              && LegacyCompatibility.legacyKeychainService(for: "Ode B6 synthetic qualification") == nil,
              "REQ-150/COR-310: Only the renamed Library Keychain service has a read-only old source")

        let legacyLine = Data(#"{"schema":""#.utf8) + Data(LegacyCompatibility.legacySchemaIDs[0].0.utf8)
            + Data(#"","x":1}"#.utf8)
        check(String(decoding: LegacyCompatibility.normalizingLegacySchemaIDs(legacyLine), as: UTF8.self)
                == #"{"schema":"urn:ode:management:1.0","x":1}"#
              && LegacyCompatibility.normalizingLegacySchemaIDs(Data(#"{"note":"urn:ode:management:1.0"}"#.utf8))
                == Data(#"{"note":"urn:ode:management:1.0"}"#.utf8),
              "REQ-150: A pre-rename management schema ID is normalised to the canonical one before validation")

        let lock = URL(fileURLWithPath: "/games/.Halls.ode-lifecycle.lock")
        let owner = URL(fileURLWithPath: "/prefixes/.p.ode-engine-owner.json")
        check(LegacyCompatibility.legacySidecar(for: lock)?.lastPathComponent.hasPrefix(".Halls.") == true
              && LegacyCompatibility.legacySidecar(for: lock)?.lastPathComponent != lock.lastPathComponent
              && LegacyCompatibility.legacySidecar(for: lock)?.deletingLastPathComponent() == lock.deletingLastPathComponent()
              && LegacyCompatibility.legacySidecar(for: owner)?.pathExtension == "json"
              && LegacyCompatibility.legacySidecar(for: URL(fileURLWithPath: "/games/Halls")) == nil,
              "REQ-150: Backend sidecars have one read-only pre-rename name beside the canonical one")
        check(LegacyCompatibility.runIDPrefixes.first == "ode-"
              && LegacyCompatibility.privateSaveFolders.count == 6
              && LegacyCompatibility.privateSaveFolders.contains("odeprivatelocalsaves"),
              "REQ-150: New run IDs use ode-; both save-folder families of all three kinds are recognised")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("req150-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        let state = LegacyCompatibility.dataRoots[0]
        let oldRoot = home.appendingPathComponent(state.legacy), newRoot = home.appendingPathComponent(state.current)
        let absent = LegacyCompatibility.dataMoveState(home: home.path)
        try? fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let notMoved = LegacyCompatibility.dataMoveState(home: home.path)
        try? fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let split = LegacyCompatibility.dataMoveState(home: home.path)
        try? fileManager.removeItem(at: oldRoot)
        try? fileManager.createSymbolicLink(at: oldRoot, withDestinationURL: newRoot)
        let aliased = LegacyCompatibility.dataMoveState(home: home.path)
        check(absent == .ready && notMoved == .notMoved([state.legacy]) && split == .split([state.legacy])
              && aliased == .ready,
              "REQ-150: Data move state: unmoved and split old folders block startup; absent or aliased old roots do not")
    }
}
