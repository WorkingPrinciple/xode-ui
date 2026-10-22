// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum LaunchRecipeResources {
    public static func profilesURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "title-profiles-v1", withExtension: "json",
                                          subdirectory: "LaunchRecipes") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
