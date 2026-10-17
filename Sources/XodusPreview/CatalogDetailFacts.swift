// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct CatalogDetailPayload: Decodable {
    struct Product: Decodable {
        struct Localized: Decodable {
            struct Video: Decodable {
                let HLS: String?
                let Caption: String?
                let VideoPurpose: String?
                let PreviewImage: PCGamesCatalog.Product.Localized.Image?
            }
            let Language: String?
            let ProductDescription: String?
            let ShortDescription: String?
            let DeveloperName: String?
            let PublisherName: String?
            let CMSVideos: [Video]?
        }
        struct Market: Decodable {
            struct Usage: Decodable {
                let AggregateTimeSpan: String?
                let AverageRating: Double?
                let RatingCount: Int?
            }
            struct Rating: Decodable {
                let RatingSystem: String?
                let RatingId: String?
                let RatingDescriptors: [String]?
                let InteractiveElements: [String]?
            }
            let Markets: [String]?
            let OriginalReleaseDate: String?
            let UsageData: [Usage]?
            let ContentRatings: [Rating]?
        }
        struct Availability: Decodable {
            struct SKU: Decodable {
                struct PropertiesDTO: Decodable {
                    let HardwareProperties: CatalogPCRequirements?
                    let Packages: [PCGamesCatalog.Product.Availability.SKU.PropertiesDTO.Package]?
                }
                let Properties: PropertiesDTO?
            }
            let Sku: SKU?
        }
        let ProductId: String
        let LocalizedProperties: [Localized]?
        let MarketProperties: [Market]?
        let DisplaySkuAvailabilities: [Availability]?
    }
    let Products: [Product]
}

struct CatalogPCRequirements: Decodable, Hashable, Sendable {
    let MinimumProcessor: String?
    let RecommendedProcessor: String?
    let MinimumGraphics: String?
    let RecommendedGraphics: String?

    var hasValues: Bool {
        [MinimumProcessor, RecommendedProcessor, MinimumGraphics, RecommendedGraphics].contains {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

struct CatalogTrailer: Identifiable, Sendable {
    let url: URL
    let caption: String
    let preview: CatalogArtworkReference?
    var id: String { url.absoluteString }

    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2048, let parts = URLComponents(string: value),
              parts.scheme == "https", parts.host == "cdn-dynmedia-1.microsoft.com",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.range(of: #"^/is/content/microsoftassets/[A-Za-z0-9_-]{1,128}-AVS\.m3u8$"#,
                               options: .regularExpression) != nil,
              (parts.queryItems ?? []).allSatisfy({ $0.name == "packagedStreaming" && $0.value == "true" }),
              (parts.queryItems ?? []).count <= 1,
              let url = parts.url else { throw PCGamesError.invalidResponse }
        return url
    }
}

struct CatalogContentRating: Sendable {
    let label: String
    let descriptors: [String]
    let interactiveElements: [String]

    init?(_ rating: CatalogDetailPayload.Product.Market.Rating) {
        guard let system = rating.RatingSystem, ["ESRB", "PEGI"].contains(system),
              let id = rating.RatingId, id.hasPrefix(system + ":") else { return nil }
        let value = String(id.dropFirst(system.count + 1))
        let esrb = ["E": "Everyone", "E10": "Everyone 10+", "E10+": "Everyone 10+",
                    "T": "Teen", "M": "Mature 17+", "AO": "Adults Only 18+", "RP": "Rating Pending"]
        if system == "ESRB" {
            guard let name = esrb[value] else { return nil }
            label = "ESRB \(name)"
        } else {
            guard ["3", "7", "12", "16", "18"].contains(value) else { return nil }
            label = "PEGI \(value)"
        }
        let descriptions = [
            "ESRB:UseAlc": "Use of alcohol", "ESRB:FanVio": "Fantasy violence",
            "ESRB:Blo": "Blood", "ESRB:MilLan": "Mild language", "ESRB:Vio": "Violence",
            "ESRB:IntVio": "Intense violence", "ESRB:StrLan": "Strong language",
            "ESRB:UseDru": "Use of drugs", "ESRB:SexCon": "Sexual content",
            "PEGI:BadLan": "Bad language", "PEGI:Vio": "Violence", "PEGI:Fea": "Fear",
            "PEGI:Gam": "Gambling", "PEGI:Dru": "Drugs", "PEGI:Sex": "Sex"]
        descriptors = Array((rating.RatingDescriptors ?? []).compactMap { descriptions[$0] }.prefix(12))
        let elements = ["\(system):InGamPur": "In-game purchases",
                        "\(system):UsrInt": "Users interact"]
        interactiveElements = Array((rating.InteractiveElements ?? []).compactMap { elements[$0] }.prefix(6))
    }
}

struct CatalogStoreRating: Sendable {
    let average: Double
    let count: Int
}

struct CatalogDetailFacts: Sendable {
    let description: String?
    let shortDescription: String?
    let developer: String?
    let publisher: String?
    let releaseDate: Date?
    let storeRating: CatalogStoreRating?
    let contentRating: CatalogContentRating?
    let trailers: [CatalogTrailer]
    let screenshots: [CatalogArtworkReference]
    let requirements: CatalogPCRequirements?
    let requirementsVaryByEdition: Bool

    init(product: CatalogDetailPayload.Product, images: [PCGamesCatalog.Product.Localized.Image],
         market: String, language: String) throws {
        let localized = (product.LocalizedProperties ?? []).first {
            $0.Language?.caseInsensitiveCompare(language) == .orderedSame
        } ?? product.LocalizedProperties?.first
        if let actual = localized?.Language?.lowercased() {
            let requested = language.lowercased()
            let actualBase = actual.split(separator: "-", maxSplits: 1).first
            let requestedBase = requested.split(separator: "-", maxSplits: 1).first
            guard actual == requested || actualBase == requestedBase else {
                throw PCGamesError.invalidResponse
            }
        }
        // About uses only the product-level description. SKU descriptions can
        // contain edition or console-upgrade terms and are intentionally ignored.
        description = Self.text(localized?.ProductDescription, maximum: 40_000, multiline: true)
        shortDescription = Self.text(localized?.ShortDescription, maximum: 8_000, multiline: true)
        developer = Self.text(localized?.DeveloperName, maximum: 512)
        publisher = Self.text(localized?.PublisherName, maximum: 512)
        let scopedMarket = product.MarketProperties?.first { $0.Markets?.contains(market) == true }
        releaseDate = scopedMarket?.OriginalReleaseDate.flatMap(GameCompatibilityResult.parseDate)
        if let usage = scopedMarket?.UsageData?.first(where: { $0.AggregateTimeSpan == "AllTime" }),
           let average = usage.AverageRating, average.isFinite, average > 0, average <= 5,
           let count = usage.RatingCount, (1...1_000_000_000).contains(count) {
            storeRating = CatalogStoreRating(average: average, count: count)
        } else { storeRating = nil }
        let ratings = scopedMarket?.ContentRatings ?? []
        let preferredSystem = ["US", "CA", "MX"].contains(market) ? "ESRB" : "PEGI"
        contentRating = ratings.first(where: { $0.RatingSystem == preferredSystem }).flatMap(CatalogContentRating.init)
            ?? ratings.compactMap(CatalogContentRating.init).first
        var videos: [CatalogTrailer] = []
        for video in (localized?.CMSVideos ?? []).prefix(6) {
            guard let hls = video.HLS, let url = try? CatalogTrailer.validatedURL(hls) else { continue }
            let caption = Self.text(video.Caption, maximum: 256) ?? "Trailer"
            let preview = video.PreviewImage.flatMap {
                PCGamesClient.artwork(uri: $0.Uri, width: $0.Width, height: $0.Height, role: .hero)
            }
            if !videos.contains(where: { $0.url == url }) {
                videos.append(CatalogTrailer(url: url, caption: caption, preview: preview))
            }
        }
        trailers = videos
        var screenshotURLs = Set<String>()
        screenshots = Array(images.filter { $0.ImagePurpose == "Screenshot" }.compactMap {
            PCGamesClient.artwork(uri: $0.Uri, width: $0.Width, height: $0.Height, role: .hero)
        }.filter { screenshotURLs.insert($0.url).inserted }.prefix(12))
        var hardware: [CatalogPCRequirements] = []
        for availability in product.DisplaySkuAvailabilities ?? [] {
            guard let properties = availability.Sku?.Properties,
                  (properties.Packages ?? []).contains(where: {
                      ($0.PlatformDependencies ?? []).contains { $0.PlatformName == "Windows.Desktop" }
                  }), let value = properties.HardwareProperties, value.hasValues else { continue }
            let normalized = CatalogPCRequirements(
                MinimumProcessor: Self.text(value.MinimumProcessor, maximum: 2048),
                RecommendedProcessor: Self.text(value.RecommendedProcessor, maximum: 2048),
                MinimumGraphics: Self.text(value.MinimumGraphics, maximum: 2048),
                RecommendedGraphics: Self.text(value.RecommendedGraphics, maximum: 2048))
            if !hardware.contains(normalized) { hardware.append(normalized) }
        }
        requirements = hardware.count == 1 ? hardware.first : nil
        requirementsVaryByEdition = hardware.count > 1
    }

    private static func text(_ value: String?, maximum: Int, multiline: Bool = false) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !(multiline && [9, 10, 13].contains($0.value))
              }) else { return nil }
        return text
    }
}
