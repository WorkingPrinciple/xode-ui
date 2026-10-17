// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

extension Checks {
    func artworkChecks() async throws {
        let validator = try ContractValidator()
        let artwork: JSONValue = .object([
            "role": .string("boxArt"),
            "url": .string("https://store-images.s-microsoft.com/image/neutral-asset"),
            "width": .integer(2048), "height": .integer(2048),
            "source": .string("MicrosoftDisplayCatalog:v7.0")
        ])
        try validator.validate(artwork, definition: "artwork")
        let reference = try artwork.decode(CatalogArtworkReference.self)
        check(try reference.validatedURL().host == "store-images.s-microsoft.com",
              "Native image URLs use only the exact Store CDN and one approved opaque asset")
        try CatalogArtworkReference.validate([reference], status: .available)
        check(true, "Live artwork retains a real role, declared dimensions and catalog source")
        for url in [
            "http://store-images.s-microsoft.com/image/neutral-asset",
            "//store-images.s-microsoft.com/image/neutral-asset",
            "https://store-images.s-microsoft.com/image/neutral-asset?width=300",
            "https://store-images.s-microsoft.com/image/neutral-asset#fragment",
            "https://user@store-images.s-microsoft.com/image/neutral-asset",
            "https://store-images.s-microsoft.com:443/image/neutral-asset",
            "https://store-images.s-microsoft.com.evil.invalid/image/neutral-asset",
            "https://127.0.0.1/image/neutral-asset",
            "https://store-images.s-microsoft.com/image/first/second",
            "https://store-images.s-microsoft.com/image/%2e%2e",
            "https://store-images.s-microsoft.com/image/.first",
            "https://store-images.s-microsoft.com/image/neutral~asset"
        ] {
            var object = artwork.object!
            object["url"] = .string(url)
            do {
                _ = try JSONValue.object(object).decode(CatalogArtworkReference.self).validatedURL()
                check(false, "Unsafe artwork URL is rejected before creating any network request")
            } catch {
                check(error as? ManagementError == .invalidPayload,
                      "Unsafe artwork URL is rejected before creating any network request")
            }
        }
        for (width, height) in [(8192, 8192), (0, 100), (8193, 1)] {
            var object = artwork.object!
            object["width"] = .integer(Int64(width))
            object["height"] = .integer(Int64(height))
            do {
                _ = try JSONValue.object(object).decode(CatalogArtworkReference.self).validatedURL()
                check(false, "Dimension and sixteen-megapixel limits are independently enforced")
            } catch { check(error as? ManagementError == .invalidPayload,
                            "Dimension and sixteen-megapixel limits are independently enforced") }
        }
        var incomplete = artwork.object!
        incomplete["height"] = .null
        do {
            _ = try JSONValue.object(incomplete).decode(CatalogArtworkReference.self).validatedURL()
            check(false, "Dimensions must both be unknown or both be positive")
        } catch { check(error as? ManagementError == .invalidPayload,
                        "Dimensions must both be unknown or both be positive") }
        for (references, status) in [([reference, reference], CatalogArtworkStatus.available),
                                     ([], .available), ([reference], .absent),
                                     ([reference], .rejected), ([reference], .notQueried)] {
            do {
                try CatalogArtworkReference.validate(references, status: status)
                check(false, "Artwork roles are unique and status agrees with presence")
            } catch { check(error as? ManagementError == .invalidPayload,
                            "Artwork roles are unique and status agrees with presence") }
        }
        for status in [CatalogArtworkStatus.absent, .rejected, .notQueried] {
            try CatalogArtworkReference.validate([], status: status)
            check(true, "Missing, rejected and legacy unqueried metadata remain distinct from fetch failures")
        }
        let frames = try fixture("positive").array ?? []
        guard let page = frames.first(where: {
            $0["data"]?["scope"]?.string == "recentlyPlayed"
                && $0["data"]?["titles"]?.array?.isEmpty == false
        })?["data"] else { throw ManagementError.invalidPayload }
        let recent = try page.decode(RecentLibrarySnapshot.self)
        try recent.validate(limit: 20)
        check(recent.titles.first?.productID == nil && recent.nextCursor == nil
              && recent.completeness == "partial",
              "Played history is a partial bounded window, not product evidence, ownership or paging")
        var oversizedPage = page.object!
        oversizedPage["titles"] = .array(Array(repeating: page["titles"]!.array!.first!, count: 21))
        do {
            try JSONValue.object(oversizedPage).decode(RecentLibrarySnapshot.self).validate(limit: 20)
            check(false, "Recent history validates the requested window and duplicate identities")
        } catch { check(error as? ManagementError == .invalidPayload,
                        "Recent history validates the requested window and duplicate identities") }
        for stage in RecentLibraryFailure.allCases {
            let error: JSONValue = .object([
                "code": .string(stage.code), "message": .string(stage.message),
                "retryable": .bool(stage.retryable), "details": stage.details
            ])
            check(RecentLibraryFailure(error: error) == stage,
                  "Recent-history failures retain only the approved closed stage tuple")
            var changed = error.object!
            changed["message"] = .string(stage.message + " raw upstream data")
            check(RecentLibraryFailure(error: .object(changed)) == nil,
                  "Extended provider wording cannot enter a typed personal-history failure")
        }
        check(ManagementCommand.libraryRecent.defaultTimeout == .seconds(30)
              && ManagementCommand.authStatus.defaultTimeout == .seconds(130),
              "History keeps its thirty-second bound without changing foreground permission timing")
    }
}
