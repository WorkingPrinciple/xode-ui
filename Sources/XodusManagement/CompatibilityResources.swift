// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum CompatibilityResources {
    public static func catalogueURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "game-compatibility-v1", withExtension: "json",
                                          subdirectory: "CompatibilityData") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    public static func publisherEvidenceURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "publisher-anti-cheat-v1", withExtension: "json",
                                          subdirectory: "CompatibilityData") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
