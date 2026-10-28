// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The only Swift home for pre-Ode names (REQ-150, COR-308), mirroring the backend's compatibility
/// manifest `docs/contracts/ode-identity-compat-v1.json` (xode-macos-private-ai a272b1d7).
///
/// `Contract` holds stable protocol values that never change; the persistent-data-identity section
/// names data on disk that stays until an explicit owner decision. Everything else is a name written
/// by builds or backends before the rename and is read only: REMOVE AFTER NEXT RELEASE.
public enum LegacyCompatibility {
    /// Stable protocol identifiers shared with the backend.
    public enum Contract {
        /// This stable v1 hash domain must not change: it determines existing account identities (COR-314).
        public static let accountHashDomain = "xodus-account-v1\u{0}"
    }

    // MARK: Persistent data identity. Kept until an explicit owner decision, never on a timer (F4c/F5).

    /// Game library folder names an earlier build used under ~/Games and at volume roots. Games
    /// installed there stay where they are.
    public static let legacyGameLibraryFolders = ["Xodus"]

    /// In-prefix save folder names, lower-cased, for both name families. The old family is never
    /// moved or merged (COR-316).
    public static let privateSaveFolders = ["localsaves", "containersaves", "cloudsnapshot"].flatMap {
        ["odeprivate" + $0, "xodusprivate" + $0]
    }

    /// The package marker file installed games keep on disk. The backend still writes and reports this name
    /// in install-inventory package records; inspection reports the canonical `.ode-streaming.msixvc`.
    public static let onDiskPackageMarker = ".xodus-streaming.msixvc"

    /// Name prefixes a package record may carry: the canonical one and the on-disk one.
    public static let packageRecordPrefixes = [".ode-streaming", ".xodus-streaming"]

    /// Names inherited from upstream that owned code keeps writing and reading indefinitely.
    public enum Inherited {
        /// Read by upstream Wine's builtin xgameruntime (xodus-gaming/wine dlls/xgameruntime/private.h).
        public static let xblOnline = "XODUS_XBL_ONLINE"
    }

    /// Runtime environment names held at their pre-rename spelling while the app's pinned runtime pair predates
    /// f8092bb, which reads only these (manifest `runtimePinPending`). Move to ODE_* when a runtime at or after
    /// f8092bb is pinned; no dual writes.
    public enum RuntimePinPending {
        public static let runtimeComSTA = "XODUS_PRIVATE_RUNTIME_COM_STA"
        public static let callerOwnsCOM = "XODUS_PRIVATE_CALLER_OWNS_COM"
        public static let localSaves = "XODUS_PRIVATE_LOCAL_SAVES"
    }

    // MARK: Wire. REMOVE AFTER NEXT RELEASE.

    public static let legacySchemaIDs = [("urn:xodus:management:1.0", "urn:ode:management:1.0")]

    /// One management line with a pre-rename schema ID rewritten to the canonical one, so it can be
    /// validated against the canonical schema. Matches only the exact quoted JSON string.
    public static func normalizingLegacySchemaIDs(_ line: Data) -> Data {
        var line = line
        for (old, new) in legacySchemaIDs {
            let oldBytes = Data("\"\(old)\"".utf8), newBytes = Data("\"\(new)\"".utf8)
            while let range = line.range(of: oldBytes) { line.replaceSubrange(range, with: newBytes) }
        }
        return line
    }

    // MARK: Sidecars and run IDs. REMOVE AFTER NEXT RELEASE.

    static let sidecarSuffixes = [(".ode-lifecycle.lock", ".xodus-lifecycle.lock"),
                                  (".ode-engine-owner.json", ".xodus-engine-owner.json")]

    /// The pre-rename name of a backend sidecar (`.<name>.ode-lifecycle.lock`,
    /// `.<prefix>.ode-engine-owner.json`), or nil. Read only: new sidecars use canonical names.
    public static func legacySidecar(for url: URL) -> URL? {
        let name = url.lastPathComponent
        for (new, old) in sidecarSuffixes where name.hasSuffix(new) {
            return url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(new.count)) + old)
        }
        return nil
    }

    /// Generated run IDs: new ones use the first prefix; earlier builds' records use the second.
    public static let runIDPrefixes = ["ode-", "xodus-"]

    // MARK: Identity. REMOVE AFTER NEXT RELEASE.

    public static let currentBundleIdentifier = "com.workingprinciple.xode"
    public static let legacyBundleIdentifier = "io.github.dragoshont.xodus"

    /// The pre-rename identifier for a renamed bundle identifier, keeping its variant suffix
    /// (`.development`, `.qualification`, `.credential-broker`); nil for anything else.
    public static func legacyBundleIdentifier(for identifier: String?) -> String? {
        guard let identifier, identifier == currentBundleIdentifier
                || identifier.hasPrefix(currentBundleIdentifier + ".") else { return nil }
        return legacyBundleIdentifier + identifier.dropFirst(currentBundleIdentifier.count)
    }

    // MARK: Preferences. REMOVE AFTER NEXT RELEASE.

    public static let legacyKeyPrefixes = [("Xodus.", "Ode."), ("xodus.", "ode.")]
    public static let importMarker = "Ode.legacyPreferencesImported"

    /// The renamed key for a pre-rename preference key.
    public static func renamedPreferenceKey(_ key: String) -> String {
        for (old, new) in legacyKeyPrefixes where key.hasPrefix(old) {
            return new + key.dropFirst(old.count)
        }
        return key
    }

    /// Copies preferences from the pre-rename domain once. Values already set win; the old domain
    /// is only read and stays in place for rollback. Returns the number of keys copied.
    @discardableResult
    public static func importLegacyPreferences(into defaults: UserDefaults = .standard,
                                               bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                               legacyDomain: [String: Any]? = nil) -> Int {
        guard !defaults.bool(forKey: importMarker),
              let legacy = legacyBundleIdentifier(for: bundleIdentifier) else { return 0 }
        var copied = 0
        for (key, value) in legacyDomain ?? defaults.persistentDomain(forName: legacy) ?? [:] {
            let renamed = renamedPreferenceKey(key)
            guard defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
            copied += 1
        }
        defaults.set(true, forKey: importMarker)
        return copied
    }

    // MARK: Keychain. REMOVE AFTER NEXT RELEASE.

    /// Pre-rename Keychain service for a current one. The old item is read and copied forward on
    /// first use, and never changed or deleted this release (COR-310).
    public static func legacyKeychainService(for service: String) -> String? {
        ["Ode Library": "Xodus Library"][service]
    }

    /// Set once an item has been copied forward from `legacyKeychainService(for:)`, or the user
    /// signed out, so the old item is not consulted again.
    public static func keychainCopyForwardMarker(service: String) -> String {
        "Ode.legacyKeychainCopied.\(service)"
    }

    // MARK: Files. REMOVE AFTER NEXT RELEASE.

    /// Renamed data roots relative to the home folder. The backend's one-time data move renames each
    /// old root and leaves an alias at the old path for one release.
    public static let dataRoots: [(current: String, legacy: String)] = [
        ("Library/Application Support/Ode to X/State", "Library/Application Support/Xodus"),
        ("Library/Application Support/Ode to X/CLI", "Library/Application Support/XodusCLI"),
        ("Library/Application Support/Ode to X/EdgeCDP", "Library/Application Support/XodusEdgeCDP"),
        ("Library/Application Support/Ode to X/Remote", "Library/Application Support/XodusRemote"),
        ("Library/Logs/Ode to X/Remote", "Library/Logs/XodusRemote"),
        ("Library/Caches/Ode to X", "Library/Caches/Xodus"),
    ]

    /// Where the one-time data move stands for the State and CLI roots.
    public enum DataMoveState: Equatable, Sendable {
        /// Every old root is absent or the alias the move leaves behind.
        case ready
        /// An old root is still a real folder and its new root is missing: the move has not run.
        case notMoved([String])
        /// An old root is still a real folder and its new root exists too. The move contract does not
        /// define this state, so the app must not pick either copy.
        case split([String])
    }

    /// Reads where the data move stands, without changing anything. Old roots that are symbolic links
    /// (the move's one-release aliases) count as moved.
    public static func dataMoveState(home: String = NSHomeDirectory(),
                                     fileManager: FileManager = .default) -> DataMoveState {
        var notMoved: [String] = [], split: [String] = []
        for root in dataRoots.prefix(2) {
            let legacy = (home as NSString).appendingPathComponent(root.legacy)
            let current = (home as NSString).appendingPathComponent(root.current)
            guard let type = try? fileManager.attributesOfItem(atPath: legacy)[.type] as? FileAttributeType,
                  type == .typeDirectory else { continue }
            if fileManager.fileExists(atPath: current) { split.append(root.legacy) } else { notMoved.append(root.legacy) }
        }
        if !split.isEmpty { return .split(split) }
        return notMoved.isEmpty ? .ready : .notMoved(notMoved)
    }
}
