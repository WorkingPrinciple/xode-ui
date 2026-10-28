// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A parsed MicrosoftGame.config / package four-part version
/// (`major.minor.build.revision`, each a `UInt16`). Parsing mirrors the validation already
/// used by the installed-game config reader so installed and available versions compare on
/// identical rules.
public struct GameVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [UInt16]

    public init?(parsing string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var parsed: [UInt16] = []
        parsed.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt16(part) else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    public static func < (lhs: GameVersion, rhs: GameVersion) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
            return left < right
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// The result of comparing an installed version against an available version.
public enum UpdateStatus: String, Sendable, Equatable {
    /// An available version is strictly newer than what is installed.
    case updateAvailable
    /// The installed version is current (equal to or newer than available).
    case upToDate
    /// The installed and/or available version is missing or unparseable.
    case unknown

    public var hasUpdate: Bool { self == .updateAvailable }
}

/// Pure update detection: compares installed versions against available versions.
public enum UpdateDetector {
    /// Compares a single installed version against an optional available version.
    public static func status(installed: String, available: String?) -> UpdateStatus {
        guard let available,
              let have = GameVersion(parsing: installed),
              let candidate = GameVersion(parsing: available) else { return .unknown }
        return candidate > have ? .updateAvailable : .upToDate
    }

    /// Resolves update status for a set of installed items against an available-version map.
    public static func resolve<ID: Hashable>(
        installed: [(id: ID, version: String)], available: [ID: String]
    ) -> [ID: UpdateStatus] {
        var result: [ID: UpdateStatus] = [:]
        for entry in installed {
            result[entry.id] = status(installed: entry.version, available: available[entry.id])
        }
        return result
    }
}
