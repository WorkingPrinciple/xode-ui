// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct CatalogCommerce {
    struct Payload: Decodable { let Products: [Product] }
    struct Product: Decodable {
        struct Availability: Decodable {
            struct SKU: Decodable {
                let SkuType: String?
                let Properties: PCGamesCatalog.Product.Availability.SKU.PropertiesDTO?
            }
            struct Offer: Decodable {
                struct ConditionsDTO: Decodable {
                    struct Client: Decodable {
                        let AllowedPlatforms: [PCGamesCatalog.Product.Availability.SKU.PropertiesDTO.Package.Platform]?
                    }
                    let StartDate: String?
                    let EndDate: String?
                    let ClientConditions: Client?
                }
                struct Order: Decodable {
                    struct PriceDTO: Decodable {
                        let ListPrice: Decimal?
                        let CurrencyCode: String?
                        let IsPIRequired: Bool?
                    }
                    let Price: PriceDTO?
                }
                let Actions: [String]?
                let Markets: [String]?
                let Conditions: ConditionsDTO?
                let OrderManagementData: Order?
                let RemediationRequired: Bool?
                let Remediations: [JSONValue]?
            }
            let Sku: SKU?
            let Availabilities: [Offer]?
        }
        let ProductId: String
        let DisplaySkuAvailabilities: [Availability]?
    }

    let amount: Decimal
    let currency: String
    let expires: Date

    var label: String { amount == 0 ? "Free" : amount.formatted(.currency(code: currency)) }
    func isCurrent(now: Date = Date()) -> Bool { now < expires }
    func isFree(now: Date = Date()) -> Bool { amount == 0 && isCurrent(now: now) }

    static func price(_ product: Product, market: String,
                      now: Date = Date()) -> Self? {
        let offers = (product.DisplaySkuAvailabilities ?? []).filter {
            $0.Sku?.SkuType == "full" && ($0.Sku?.Properties?.Packages ?? []).contains {
                ($0.PlatformDependencies ?? []).contains { $0.PlatformName == "Windows.Desktop" }
            }
        }.flatMap { $0.Availabilities ?? [] }
        return offers.compactMap { offer -> Self? in
            guard offer.Actions?.contains("Purchase") == true,
                  offer.Markets?.contains(market) == true,
                  offer.RemediationRequired != true, offer.Remediations?.isEmpty ?? true,
                  let conditions = offer.Conditions,
                  conditions.ClientConditions?.AllowedPlatforms?.contains(where: {
                      $0.PlatformName == "Windows.Desktop"
                  }) == true,
                  let start = conditions.StartDate.flatMap(GameCompatibilityResult.parseDate),
                  let end = conditions.EndDate.flatMap(GameCompatibilityResult.parseDate),
                  start <= now, now < end,
                  let price = offer.OrderManagementData?.Price,
                  let amount = price.ListPrice, !amount.isNaN, amount >= 0,
                  let currency = price.CurrencyCode,
                  currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
                  amount > 0 || price.IsPIRequired == false else { return nil }
            return Self(amount: amount, currency: currency, expires: min(end, now.addingTimeInterval(900)))
        }.min { $0.amount < $1.amount }
    }
}

enum CatalogAcquisition {
    enum Kind: Equatable {
        case free, gamePass
        var label: String {
            switch self {
            case .free: "Get free on xbox.com"
            case .gamePass: "View Game Pass on xbox.com"
            }

        }
    }

    static func kind(licensed: Bool, gamePass: Bool, commerce: CatalogCommerce?,
                     now: Date = Date()) -> Kind? {
        guard !licensed else { return nil }
        if commerce?.isFree(now: now) == true { return .free }
        return gamePass ? .gamePass : nil
    }
}

struct CatalogAcquisitionConsent {
    private(set) var isPresented = false
    private(set) var authorization: UUID?

    mutating func request() {
        guard authorization == nil else { return }
        isPresented = true
    }

    mutating func confirm() {
        guard isPresented else { return }
        isPresented = false
        authorization = UUID()
    }

    mutating func cancel() { isPresented = false }
    mutating func finish() { authorization = nil }
}
