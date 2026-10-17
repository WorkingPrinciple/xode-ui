// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum CatalogArtworkRole: String, Codable, Sendable {
    case boxArt, poster, hero, tile
}

public enum CatalogArtworkStatus: String, Codable, Sendable {
    case available, absent, rejected, notQueried
}

public enum CatalogArtworkSource: String, Codable, Sendable {
    case displayCatalog = "MicrosoftDisplayCatalog:v7.0"
    case titleHub = "XboxTitleHub:v2"
    case xboxCompanion = "XboxCompanion"
}

public struct CatalogArtworkReference: Codable, Hashable, Sendable {
    public let role: CatalogArtworkRole
    public let url: String
    public let width: Int?
    public let height: Int?
    public let source: CatalogArtworkSource

    public func validatedURL() throws -> URL {
        let result: URL
        switch source {
        case .displayCatalog, .titleHub:
            let prefix = "https://store-images.s-microsoft.com/image/"
            let asset = url.dropFirst(prefix.count)
            guard url.hasPrefix(prefix), url.utf8.count <= 2048,
                  asset.utf8.first.map({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  }) == true,
                  !asset.isEmpty,
                  asset.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || [45, 46, 95].contains($0)
                  }), let parsed = URL(string: url) else {
                throw ManagementError.invalidPayload
            }
            result = parsed
        case .xboxCompanion:
            guard url.utf8.count <= 2048, let parts = URLComponents(string: url),
                  parts.scheme == "https", parts.host == "images-eds-ssl.xboxlive.com",
                  parts.port == nil, parts.user == nil, parts.password == nil,
                  parts.fragment == nil, !parts.path.isEmpty, let parsed = parts.url else {
                throw ManagementError.invalidPayload
            }
            result = parsed
        }

        switch (width, height) {
        case (nil, nil): break
        case let (width?, height?):
            guard (1...8192).contains(width), (1...8192).contains(height),
                  width * height <= 16_777_216 else { throw ManagementError.invalidPayload }
        default: throw ManagementError.invalidPayload
        }
        return result
    }

    public static func validate(_ artwork: [Self], status: CatalogArtworkStatus) throws {
        guard artwork.count <= 4, Set(artwork.map(\.role)).count == artwork.count,
              (status == .available) == !artwork.isEmpty else { throw ManagementError.invalidPayload }
        for reference in artwork { _ = try reference.validatedURL() }
    }

    public static func preferred(in artwork: [Self], roles: [CatalogArtworkRole]) -> Self? {
        for role in roles {
            if let reference = artwork.first(where: { $0.role == role }) { return reference }
        }
        return nil
    }
}
