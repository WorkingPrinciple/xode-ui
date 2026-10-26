// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum CompatibilityResources {
    public static func macGameStatusURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "mac-game-status-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    public static func catalogueURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "game-compatibility-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    public static func publisherEvidenceURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "publisher-anti-cheat-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// The AreWeAntiCheatYet MIT notice shipped with the compatibility data.
    public static func antiCheatReferenceLicenseURL() -> URL? {
        Bundle.module.url(forResource: "AWACY-LICENSE", withExtension: "txt")
    }
}
