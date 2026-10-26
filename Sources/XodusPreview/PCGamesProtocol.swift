// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import Security
import XodusManagement

enum PCGamesError: Error, LocalizedError, Equatable {
    case invalidResponse, transport, responseTooLarge, http(Int)
    case signInExpired, signInDeclined, signInRequired, keychain(OSStatus)
    case noXboxProfile, childAccount, regionUnavailable, xboxSignIn, identityMismatch
    case incompleteCollection(Int), incompleteCatalog(Int), libraryReadBusy
    case credentialBrokerUnavailable, keychainApprovalRequired, keychainApprovalCancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Microsoft returned game-library details \(AppBrand.displayName) couldn't read. Try again."
        case .transport: "Couldn't reach Microsoft. Check your connection and try again."
        case .responseTooLarge: "Microsoft's response was too large to load safely. Try again later."
        case .http(let status): "Microsoft couldn't complete the request (code \(status)). Try again."
        case .signInExpired: "The sign-in code expired. Start sign-in again."
        case .signInDeclined: "Microsoft sign-in was declined. Start again when you're ready."
        case .signInRequired: "Sign in again to see your PC games."
        case .keychain: "Couldn't access the saved PC-games sign-in. Unlock your Keychain or respond to macOS's permission prompt, then try again."
        case .credentialBrokerUnavailable: "This copy of \(AppBrand.displayName) couldn't verify or reach the saved-sign-in helper. Try again with the approved app and helper pairing. Your saved sign-in is unchanged; \(AppBrand.displayName) won't switch to direct Keychain access while the helper is installed."
        case .keychainApprovalRequired: "\(AppBrand.displayName) needs one-time Keychain approval."
        case .keychainApprovalCancelled: "Keychain approval was cancelled. Your saved sign-in is preserved. Approve access when you're ready."
        case .noXboxProfile: "This Microsoft account needs an Xbox profile. Create one at xbox.com, then sign in again."
        case .childAccount: "This account needs its Xbox family permissions updated before it can sign in."
        case .regionUnavailable: "Xbox sign-in isn't available for this account's region."
        case .xboxSignIn: "Xbox couldn't complete sign-in. Check your account at xbox.com and try again."
        case .identityMismatch: "Microsoft returned different accounts for this request. Sign out of PC games and sign in again."
        case .incompleteCollection(let pages): "Your library couldn't finish loading after \(pages) pages. Refresh to try again."
        case .incompleteCatalog(let count): "PC game details couldn't finish loading after \(count) products. Refresh to try again."
        case .libraryReadBusy: "Your PC library is waiting for another account read. It hasn't been loaded completely."
        }
    }

    static func xbox(_ code: UInt64?) -> Self {
        switch code {
        case 2148916233: .noXboxProfile
        case 2148916235: .regionUnavailable
        case 2148916236, 2148916237, 2148916238: .childAccount
        default: .xboxSignIn
        }
    }
}

protocol PCGamesRefreshStore: Sendable {
    func contains() async throws -> Bool
    func read() async throws -> String?
    func save(_ refreshToken: String) async throws
    func delete() async throws
    func migrationRequired() async throws -> Bool
    func migrate() async throws
    func legacyRetained() async throws -> Bool
}

extension PCGamesRefreshStore {
    func migrationRequired() async throws -> Bool { false }
    func migrate() async throws { throw PCGamesError.credentialBrokerUnavailable }
    func legacyRetained() async throws -> Bool { false }
}

actor PCGamesKeychain: PCGamesRefreshStore {
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Xodus Library",
         kSecAttrAccount as String: "xbox-web",
         kSecAttrSynchronizable as String: false]
    }

    func contains() throws -> Bool {
        try Task.checkCancellation()
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { return true }
        guard status == errSecSuccess else { throw PCGamesError.keychain(status) }
        return true
    }

    func read() throws -> String? {
        try Task.checkCancellation()
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PCGamesError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty, data.count <= 128 * 1024 else { throw PCGamesError.invalidResponse }
        return value
    }

    func save(_ refreshToken: String) throws {
        try Task.checkCancellation()
        guard !refreshToken.isEmpty, refreshToken.utf8.count <= 128 * 1024 else {
            throw PCGamesError.invalidResponse
        }
        let data = Data(refreshToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw PCGamesError.keychain(added) }
        } else if status != errSecSuccess { throw PCGamesError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PCGamesError.keychain(status)
        }
    }
}

struct PCGamesHTTPResponse: Sendable {
    let status: Int
    let data: Data
    let location: String?
    let retryAfter: String?

    init(status: Int, data: Data, location: String? = nil, retryAfter: String? = nil) {
        self.status = status
        self.data = data
        self.location = location
        self.retryAfter = retryAfter
    }
}

protocol PCGamesTransport: Sendable {
    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse
}

private final class PCGamesHTTPPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

struct PCGamesHTTP: PCGamesTransport {
    static let maximumBytes = 4 * 1024 * 1024
    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: PCGamesHTTPPolicy(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, response.url == request.url else {
                throw PCGamesError.invalidResponse
            }
            guard response.expectedContentLength <= Self.maximumBytes else {
                throw PCGamesError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw PCGamesError.responseTooLarge }
                data.append(byte)
            }
            return PCGamesHTTPResponse(status: http.statusCode, data: data,
                                       location: http.value(forHTTPHeaderField: "Location"),
                                       retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch is CancellationError { throw CancellationError() }
        catch let error as PCGamesError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw PCGamesError.transport
        }
    }
}

struct PCGamesDeviceCode: Sendable {
    let code: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: Int
}

struct PCGamesTokens: Sendable {
    let access: String
    let refresh: String
}

struct PCGame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artwork: CatalogArtworkReference?
    let acquisitionKind: PCGameAcquisitionKind

    init(id: String, title: String, artwork: CatalogArtworkReference?,
         acquisitionKind: PCGameAcquisitionKind = .unknown) {
        self.id = id
        self.title = title
        self.artwork = artwork
        self.acquisitionKind = acquisitionKind
    }
}

struct PCGamesSnapshot: Sendable {
    let games: [PCGame]
    let excludedCount: Int
    let updatedAt: Date
    // Memory-only identity: never persisted or logged. Bounds a retained complete snapshot.
    let accountID: String?
    let boundAccountHash: String?
    let unresolvedIDs: Set<String>
    let unresolvedCount: Int
    let unresolvedKinds: [String: PCGameAcquisitionKind]
    let detailFailureCount: Int
    var isComplete: Bool { unresolvedCount == 0 }
    func hasResolvedGame(_ productID: String) -> Bool {
        !unresolvedIDs.contains(productID) && games.contains { $0.id == productID }
    }

    init(games: [PCGame], excludedCount: Int, updatedAt: Date, accountID: String? = nil,
         boundAccountHash: String? = nil, unresolvedIDs: Set<String> = [], unresolvedCount: Int = 0,
         unresolvedKinds: [String: PCGameAcquisitionKind] = [:], detailFailureCount: Int? = nil) {
        self.games = games
        self.excludedCount = excludedCount
        self.updatedAt = updatedAt
        self.accountID = accountID
        self.boundAccountHash = boundAccountHash
        self.unresolvedIDs = unresolvedIDs
        self.unresolvedCount = unresolvedCount
        self.unresolvedKinds = unresolvedKinds
        self.detailFailureCount = detailFailureCount ?? unresolvedCount
    }

    func retainingUnresolved(from previous: Self?) -> Self {
        guard let previous, accountID == previous.accountID,
              boundAccountHash == previous.boundAccountHash else { return self }
        let resolved = Set(games.map(\.id))
        let retained = previous.games.filter { unresolvedIDs.contains($0.id) && !resolved.contains($0.id) }.map {
            PCGame(id: $0.id, title: $0.title, artwork: $0.artwork,
                   acquisitionKind: unresolvedKinds[$0.id] ?? .unknown)
        }
        return Self(games: (games + retained).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }, excludedCount: excludedCount, updatedAt: updatedAt, accountID: accountID,
            boundAccountHash: boundAccountHash, unresolvedIDs: unresolvedIDs, unresolvedCount: unresolvedCount,
            unresolvedKinds: unresolvedKinds, detailFailureCount: detailFailureCount)
    }
}

struct PCGamesCollectionPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let productId: String?
        let productKind: String?
        let status: String?
        let isTrial: Bool?
        let acquisitionType: String?
        private let trialFieldUsable: Bool

        // "Recurring" is a subscription grant such as PC Game Pass; "Single" is a purchase or redemption.
        var acquisitionKind: PCGameAcquisitionKind {
            switch acquisitionType?.lowercased() {
            case "recurring": .subscription
            case "single": .purchased
            default: .unknown
            }
        }

        var isCandidate: Bool {
            productKind == "Game" && status == "Active" && isTrial != true
                && trialFieldUsable && productId?.isEmpty == false
        }

        private enum CodingKeys: String, CodingKey {
            case productId, ProductId, productKind, status, isTrial, acquisitionType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productId = (try? container.decode(String.self, forKey: .productId))
                ?? (try? container.decode(String.self, forKey: .ProductId))
            productKind = try? container.decode(String.self, forKey: .productKind)
            status = try? container.decode(String.self, forKey: .status)
            isTrial = try? container.decode(Bool.self, forKey: .isTrial)
            acquisitionType = try? container.decode(String.self, forKey: .acquisitionType)
            trialFieldUsable = !container.contains(.isTrial)
                || (try? container.decodeNil(forKey: .isTrial)) == true || isTrial != nil
        }
    }
    let items: [Item]
    let continuationToken: String?
}

struct PCGamesCatalog: Decodable {
    struct Product: Decodable {
        struct Localized: Decodable {
            struct Image: Decodable {
                let ImagePurpose: String?
                let Uri: String?
                let Width: Int?
                let Height: Int?
            }
            let ProductTitle: String?
            let Images: [Image]?
        }
        struct Availability: Decodable {
            struct SKU: Decodable {
                struct PropertiesDTO: Decodable {
                    struct Package: Decodable {
                        struct Platform: Decodable { let PlatformName: String? }
                        let PlatformDependencies: [Platform]?
                        let MaxDownloadSizeInBytes: Int64?
                        let PackageFormat: String?
                        private enum CodingKeys: String, CodingKey { case PlatformDependencies, MaxDownloadSizeInBytes, PackageFormat }
                        init(from decoder: Decoder) throws {
                            let values = try decoder.container(keyedBy: CodingKeys.self)
                            PlatformDependencies = try values.decodeIfPresent([Platform].self, forKey: .PlatformDependencies)
                            PackageFormat = try? values.decode(String.self, forKey: .PackageFormat)
                            MaxDownloadSizeInBytes = (try? values.decode(Int64.self, forKey: .MaxDownloadSizeInBytes))
                                ?? (try? values.decode(String.self, forKey: .MaxDownloadSizeInBytes)).flatMap(Int64.init)
                        }
                    }
                    let Packages: [Package]?
                }
                let Properties: PropertiesDTO?
            }
            let Sku: SKU?
        }
        struct PropertiesDTO: Decodable {
            struct Attribute: Decodable {
                let Name: String?
                let ApplicablePlatforms: [String]?
            }
            let Categories: [String]?
            let Category: String?
            let Attributes: [Attribute]?

            private enum CodingKeys: String, CodingKey { case Categories, Category, Attributes }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                Categories = try? values.decode([String].self, forKey: .Categories)
                Category = try? values.decode(String.self, forKey: .Category)
                Attributes = try? values.decode([Attribute].self, forKey: .Attributes)
            }
        }
        let ProductId: String
        let LocalizedProperties: [Localized]?
        let DisplaySkuAvailabilities: [Availability]?
        let Properties: PropertiesDTO?
        let ProductType: String?
        let ProductKind: String?
        private let classificationFieldsUsable: Bool

        private enum CodingKeys: String, CodingKey {
            case ProductId, LocalizedProperties, DisplaySkuAvailabilities, Properties, ProductType, ProductKind
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            ProductId = try values.decode(String.self, forKey: .ProductId)
            LocalizedProperties = try values.decodeIfPresent([Localized].self, forKey: .LocalizedProperties)
            DisplaySkuAvailabilities = try values.decodeIfPresent([Availability].self, forKey: .DisplaySkuAvailabilities)
            Properties = try? values.decode(PropertiesDTO.self, forKey: .Properties)
            func bounded(_ key: CodingKeys) -> String? {
                guard let value = try? values.decode(String.self, forKey: key),
                      !value.isEmpty, value.utf8.count <= 128,
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                return value
            }
            ProductType = bounded(.ProductType)
            ProductKind = bounded(.ProductKind)
            classificationFieldsUsable = [CodingKeys.ProductType, .ProductKind].allSatisfy {
                !values.contains($0) || (try? values.decodeNil(forKey: $0)) == true || bounded($0) != nil
            }
        }

        var isBaseGame: Bool? {
            guard classificationFieldsUsable else { return nil }
            let fields = [ProductType, ProductKind].compactMap { $0 }
            guard !fields.isEmpty else { return nil }
            func classification(_ value: String) -> Bool? {
                switch value {
                case "Game": true
                case "Application", "GameAddon", "GameConsumable", "GameSubscription",
                     "GameBundle", "Consumable", "Durable", "Subscription", "AvatarItem",
                     "Movie", "TVSeason", "TVEpisode": false
                default: nil
                }
            }
            let known = fields.compactMap(classification)
            guard known.count == fields.count, Set(known).count == 1 else { return nil }
            return known.first
        }

        var isPC: Bool {
            (DisplaySkuAvailabilities ?? []).contains { availability in
                (availability.Sku?.Properties?.Packages ?? []).contains { package in
                    (package.PlatformDependencies ?? []).contains { $0.PlatformName == "Windows.Desktop" }
                }
            }
        }

        var pcPackageListing: Bool? {
            if isPC { return true }
            guard let availabilities = DisplaySkuAvailabilities, !availabilities.isEmpty,
                  availabilities.allSatisfy({ availability in
                      guard let packages = availability.Sku?.Properties?.Packages, !packages.isEmpty else { return false }
                      return packages.allSatisfy { package in
                          guard let platforms = package.PlatformDependencies, !platforms.isEmpty else { return false }
                          return platforms.allSatisfy { $0.PlatformName?.isEmpty == false }
                      }
                  }) else { return nil }
            return false
        }

        var pcDownloadBytes: Int64? {
            (DisplaySkuAvailabilities ?? []).flatMap { $0.Sku?.Properties?.Packages ?? [] }
                .filter { ($0.PlatformDependencies ?? []).contains { $0.PlatformName == "Windows.Desktop" } }
                .compactMap(\.MaxDownloadSizeInBytes).filter { $0 > 0 }.max()
        }

        // Public PC package format family (e.g. "MSIXVC", "EAppx"); a catalog fact, not a Mac verdict.
        var pcPackageFormat: String? {
            let families = (DisplaySkuAvailabilities ?? []).flatMap { $0.Sku?.Properties?.Packages ?? [] }
                .filter { ($0.PlatformDependencies ?? []).contains { $0.PlatformName == "Windows.Desktop" } }
                .compactMap { Self.packageFamily($0.PackageFormat) }
            var unique: [String] = []
            for family in families where !unique.contains(family) { unique.append(family) }
            return unique.isEmpty ? nil : unique.joined(separator: " / ")
        }

        static func packageFamily(_ format: String?) -> String? {
            switch format?.lowercased() {
            case "msixvc", "xvc": "MSIXVC"
            case "eappx", "eappxbundle": "EAppx"
            case "appx", "appxbundle": "Appx"
            case "msix", "msixbundle": "MSIX"
            default: nil
            }
        }

        var game: PCGame? {
            guard isBaseGame == true, isPC, let localized = LocalizedProperties?.first,
                  let title = localized.ProductTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.utf8.count <= 4096 else { return nil }
            let images = localized.Images ?? []
            let preferred = images.filter { $0.ImagePurpose == "BoxArt" && $0.Width == $0.Height }
                + images.filter { $0.ImagePurpose == "Poster" }
                + images.filter { $0.ImagePurpose == "BoxArt" && $0.Width != $0.Height }
            let artwork = preferred.lazy.compactMap { image in
                PCGamesClient.artwork(uri: image.Uri, width: image.Width, height: image.Height,
                                      role: image.ImagePurpose == "Poster" ? .poster : .boxArt)
            }.first
            return PCGame(id: ProductId, title: title, artwork: artwork)
        }
    }
    let Products: [Product]
}

struct PCGamesClient: Sendable {
    static let clientID = "1f907974-e22b-4810-a9de-d9647380c97e"
    static let scope = "XboxLive.signin offline_access"
    static let maximumPages = 20
    let transport: any PCGamesTransport
    let descriptors: PublicCatalogDescriptors
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    init(transport: (any PCGamesTransport)? = nil, descriptors: PublicCatalogDescriptors? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport ?? PCGamesHTTP()
        self.descriptors = descriptors ?? transport.map { PublicCatalogDescriptors(transport: $0) } ?? .shared
        self.sleep = sleep
    }

    static func validProductID(_ value: String) -> Bool {
        value.utf8.count == 12 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    static func market(_ region: String?) -> String? {
        guard let region, region.utf8.count == 2,
              region.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return region == "UK" ? "GB" : region
    }

    static func language(_ value: String) -> String {
        guard value.utf8.count <= 35, value.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#,
            options: .regularExpression) == value.startIndex..<value.endIndex else { return "en-US" }
        return value
    }

    static func artwork(uri: String?, width: Int?, height: Int?, role: CatalogArtworkRole) -> CatalogArtworkReference? {
        guard let uri else { return nil }
        let normalized = uri.hasPrefix("//") ? "https:" + uri : uri
        let value = JSONValue.object([
            "role": .string(role.rawValue), "url": .string(normalized),
            "width": width.map { .integer(Int64($0)) } ?? .null,
            "height": height.map { .integer(Int64($0)) } ?? .null,
            "source": .string(CatalogArtworkSource.displayCatalog.rawValue)])
        guard let data = try? JSONEncoder().encode(value),
              let reference = try? JSONDecoder().decode(CatalogArtworkReference.self, from: data),
              (try? reference.validatedURL()) != nil else { return nil }
        return reference
    }

    private func post(_ url: String, json: [String: Any], headers: [String: String] = [:]) throws -> URLRequest {
        guard let endpoint = URL(string: url) else { throw PCGamesError.invalidResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    private func form(_ path: String, values: [String: String]) throws -> URLRequest {
        guard let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/" + path) else {
            throw PCGamesError.invalidResponse
        }
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    private func response(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        try Task.checkCancellation()
        let value = try await transport.send(request)
        try Task.checkCancellation()
        guard value.data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
        return value
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PCGamesError.invalidResponse }
    }

    func deviceCode(now: Date = Date()) async throws -> PCGamesDeviceCode {
        struct DTO: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Int
            let interval: Int?
        }
        let result = try await response(form("devicecode", values: ["client_id": Self.clientID, "scope": Self.scope]))
        guard result.status == 200 else { throw PCGamesError.http(result.status) }
        let value = try decode(DTO.self, result.data)
        guard !value.device_code.isEmpty, value.device_code.utf8.count <= 4096,
              (1...1800).contains(value.expires_in), (1...60).contains(value.interval ?? 5),
              (1...32).contains(value.user_code.utf8.count),
              value.user_code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || $0 == 45 }),
              ["https://microsoft.com/link", "https://www.microsoft.com/link"].contains(value.verification_uri),
              let url = URL(string: value.verification_uri) else { throw PCGamesError.invalidResponse }
        return PCGamesDeviceCode(code: value.device_code, userCode: value.user_code, verificationURL: url,
                                 expiresAt: now.addingTimeInterval(Double(value.expires_in)), interval: value.interval ?? 5)
    }

    private func tokens(_ data: Data) throws -> PCGamesTokens {
        struct DTO: Decodable { let access_token: String; let refresh_token: String }
        let value = try decode(DTO.self, data)
        guard !value.access_token.isEmpty, !value.refresh_token.isEmpty,
              value.access_token.utf8.count <= 128 * 1024, value.refresh_token.utf8.count <= 128 * 1024 else {
            throw PCGamesError.invalidResponse
        }
        return PCGamesTokens(access: value.access_token, refresh: value.refresh_token)
    }

    func poll(_ device: PCGamesDeviceCode) async throws -> PCGamesTokens {
        struct OAuthError: Decodable { let error: String }
        var interval = device.interval
        while Date() < device.expiresAt {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            guard Date() < device.expiresAt else { throw PCGamesError.signInExpired }
            let result = try await response(form("token", values: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": Self.clientID, "device_code": device.code]))
            if result.status == 200 { return try tokens(result.data) }
            guard result.status == 400 else { throw PCGamesError.http(result.status) }
            switch try decode(OAuthError.self, result.data).error {
            case "authorization_pending": continue
            case "slow_down": interval = min(interval + 5, 300)
            case "expired_token": throw PCGamesError.signInExpired
            case "authorization_declined", "access_denied": throw PCGamesError.signInDeclined
            default: throw PCGamesError.signInRequired
            }
        }
        throw PCGamesError.signInExpired
    }

    func refresh(_ refreshToken: String) async throws -> PCGamesTokens {
        let result = try await response(form("token", values: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": Self.clientID, "scope": Self.scope]))
        if result.status == 400 || result.status == 401 { throw PCGamesError.signInRequired }
        guard result.status == 200 else { throw PCGamesError.http(result.status) }
        return try tokens(result.data)
    }

    private struct XboxToken: Decodable {
        struct Claims: Decodable {
            struct User: Decodable { let uhs: String; let xid: String? }
            let xui: [User]
        }
        let Token: String
        let DisplayClaims: Claims
    }

    private func xbox(_ request: URLRequest) async throws -> XboxToken {
        struct XboxError: Decodable { let XErr: UInt64? }
        let result = try await response(request)
        guard result.status == 200 else {
            if let error = try? JSONDecoder().decode(XboxError.self, from: result.data), error.XErr != nil {
                throw PCGamesError.xbox(error.XErr)
            }
            throw PCGamesError.http(result.status)
        }
        let value = try decode(XboxToken.self, result.data)
        guard !value.Token.isEmpty, value.Token.utf8.count <= 128 * 1024,
              value.DisplayClaims.xui.count == 1, let user = value.DisplayClaims.xui.first,
              !user.uhs.isEmpty, user.uhs.utf8.count <= 128,
              user.uhs.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PCGamesError.invalidResponse }
        return value
    }

    func library(accessToken: String, market: String, language: String,
                 expectedAccountID: String? = nil,
                 progress: (@MainActor @Sendable (PCGamesSnapshot) -> Void)? = nil) async throws -> PCGamesSnapshot {
        guard let market = Self.market(market) else { throw PCGamesError.invalidResponse }
        let language = Self.language(language)
        let user = try await xbox(post("https://user.auth.xboxlive.com/user/authenticate", json: [
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=" + accessToken]
        ], headers: ["x-xbl-contract-version": "1"]))
        func xstsRequest(_ relyingParty: String) throws -> URLRequest {
            try post("https://xsts.auth.xboxlive.com/xsts/authorize", json: [
                "RelyingParty": relyingParty, "TokenType": "JWT",
                "Properties": ["UserTokens": [user.Token], "SandboxId": "RETAIL"]
            ], headers: ["x-xbl-contract-version": "1"])
        }
        let xboxIdentity = try await xbox(xstsRequest("http://xboxlive.com"))
        let storeIdentity = try await xbox(xstsRequest("http://mp.microsoft.com/"))
        guard let claim = xboxIdentity.DisplayClaims.xui.first,
              claim.uhs == storeIdentity.DisplayClaims.xui.first?.uhs,
              claim.uhs == user.DisplayClaims.xui.first?.uhs else { throw PCGamesError.identityMismatch }
        guard let xid = claim.xid, !xid.isEmpty, xid.utf8.count <= 32,
              xid.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PCGamesError.invalidResponse }
        guard expectedAccountID == nil || expectedAccountID == xid else { throw PCGamesError.identityMismatch }
        var candidates = Set<String>(), candidateIDs = Set<String>(), cursors = Set<String>()
        var kinds: [String: PCGameAcquisitionKind] = [:]
        var cursor: String?
        for index in 0..<Self.maximumPages {
            var body: [String: Any] = [
                "maxPageSize": 100, "excludeDuplicates": true, "market": market, "validityType": "All",
                "beneficiaries": [["identityType": "xuid", "identityValue": xid, "localTicketReference": "xodus"]]]
            if let cursor { body["continuationToken"] = cursor }
            do {
                let result = try await response(post("https://collections.mp.microsoft.com/v7.0/collections/query",
                    json: body, headers: [
                        "Authorization": "XBL3.0 x=\(claim.uhs);\(storeIdentity.Token)",
                        "x-xbl-contract-version": "2", "Accept-Language": "en-US",
                        "MS-CV": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".0"]))
                guard result.status == 200 else { throw PCGamesError.http(result.status) }
                let page = try decode(PCGamesCollectionPage.self, result.data)
                guard page.items.count <= 100 else { throw PCGamesError.invalidResponse }
                for item in page.items {
                    guard item.isCandidate, let id = item.productId else { continue }
                    candidateIDs.insert(id)
                    if Self.validProductID(id) { candidates.insert(id) }
                    kinds[id] = PCGameAcquisitionKind.merged(kinds[id], item.acquisitionKind)
                }
                cursor = page.continuationToken
                if cursor == "" { cursor = nil }
                if let cursor {
                    guard cursor.utf8.count <= 16 * 1024, cursors.insert(cursor).inserted else {
                        throw PCGamesError.invalidResponse
                    }
                } else { break }
                if index == Self.maximumPages - 1 { throw PCGamesError.incompleteCollection(index + 1) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if case .incompleteCollection = error as? PCGamesError { throw error }
                if index > 0 { throw PCGamesError.incompleteCollection(index) }
                throw error
            }
        }
        return try await resolveCollection(ids: candidates.sorted(), kinds: kinds,
            candidateCount: candidateIDs.count, market: market, language: language, accountID: xid, progress: progress)
    }

    static func tolerantProducts(_ data: Data, batch: [String]) throws -> [PCGamesCatalog.Product] {
        if let products = try? JSONDecoder().decode(PCGamesCatalog.self, from: data).Products,
           products.count <= batch.count, Set(products.map(\.ProductId)).count == products.count,
           products.allSatisfy({ batch.contains($0.ProductId) }) { return products }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Products"] as? [Any] else { throw PCGamesError.invalidResponse }
        var seen = Set<String>(), kept: [PCGamesCatalog.Product] = [], dropped = 0
        for item in items {
            guard let one = try? JSONSerialization.data(withJSONObject: ["Products": [item]]),
                  let product = try? JSONDecoder().decode(PCGamesCatalog.self, from: one).Products.first,
                  batch.contains(product.ProductId), seen.insert(product.ProductId).inserted else { dropped += 1; continue }
            kept.append(product)
        }
        let strictError: String
        do { _ = try JSONDecoder().decode(PCGamesCatalog.self, from: data); strictError = "foreign, duplicate or excess products" }
        catch { strictError = String(describing: error).prefix(300).description }
        Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")
            .warning("Public PC descriptor batch kept \(kept.count) products and dropped \(dropped); strict decode: \(strictError, privacy: .public)")
        return kept
    }

    static let descriptorConcurrency = 2

    func resolveCollection(ids: [String], kinds: [String: PCGameAcquisitionKind], candidateCount: Int,
                           market: String, language: String, accountID: String? = nil,
                           accountHash: String? = nil,
                           progress: (@MainActor @Sendable (PCGamesSnapshot) -> Void)? = nil) async throws -> PCGamesSnapshot {
        guard ids.count <= 10_000, Set(ids).count == ids.count, ids.allSatisfy(Self.validProductID),
              candidateCount >= ids.count else { throw PCGamesError.invalidResponse }
        var resolved: [Int: [PCGamesCatalog.Product]] = [:]
        var failed: [Int: Set<String>] = [:]
        var revalidations: [Int: Task<PublicCatalogDescriptors.Revalidated, Never>] = [:]
        var completedBatches = 0
        func snapshot() -> PCGamesSnapshot {
            var games: [PCGame] = []
            var unresolved = Set(ids)
            var excluded = 0
            for index in resolved.keys.sorted() {
                for product in resolved[index] ?? [] {
                    if let game = product.game {
                        games.append(PCGame(id: game.id, title: game.title, artwork: game.artwork,
                                            acquisitionKind: kinds[game.id] ?? .unknown))
                        unresolved.remove(product.ProductId)
                    } else if product.isBaseGame == false
                        || (product.isBaseGame == true && product.pcPackageListing == false) {
                        unresolved.remove(product.ProductId)
                        excluded += 1
                    }
                }
            }
            let detailFailures = failed.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            // Ties break by ID so the display order doesn't depend on which batch finished first.
            return PCGamesSnapshot(games: games.sorted {
                    let order = $0.title.localizedStandardCompare($1.title)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                },
                excludedCount: excluded, updatedAt: Date(), accountID: accountID, boundAccountHash: accountHash,
                unresolvedIDs: unresolved, unresolvedCount: candidateCount - ids.count + unresolved.count,
                unresolvedKinds: kinds.filter { unresolved.contains($0.key) },
                detailFailureCount: detailFailures.count)
        }
        // P0: one unreadable, duplicate or foreign product never fails its whole batch. Valid products are
        // kept; the rest stay unresolved and are retried.
        func products(_ data: Data, batch: [String]) throws -> [PCGamesCatalog.Product] {
            try Self.tolerantProducts(data, batch: batch)
        }
        if !ids.isEmpty { await progress?(snapshot()) }
        let batches = stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
        let descriptors = descriptors
        // REQ-119: two independent descriptor reads at a time, inside the producer's four-operation limit;
        // LIMIT_EXCEEDED stays a retried descriptor failure. Results are merged as they arrive.
        // REQ-121: saved descriptors resolve at once and are revalidated before the final snapshot.
        try await withThrowingTaskGroup(of: (Int, Result<PublicCatalogDescriptors.Read, any Error>).self) { group in
            var next = 0
            func start(_ group: inout ThrowingTaskGroup<(Int, Result<PublicCatalogDescriptors.Read, any Error>), any Error>) {
                guard next < batches.count else { return }
                let index = next, batch = batches[index]
                next += 1
                group.addTask {
                    do { return (index, .success(try await descriptors.read(ids: batch, market: market, language: language))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<Self.descriptorConcurrency { start(&group) }
            while let (index, result) = try await group.next() {
                let batch = batches[index]
                do {
                    let read = try result.get()
                    resolved[index] = try products(read.data, batch: batch)
                    failed[index] = Set(await descriptors.failures(ids: batch, market: market, language: language).keys)
                    if let revalidation = read.revalidation { revalidations[index] = revalidation }
                    completedBatches += 1
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failed[index] = Set(batch)
                    Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")
                        .warning("Public PC descriptor batch failed; \(batch.count) candidates remain unresolved: \(String(describing: error), privacy: .public)")
                }
                try Task.checkCancellation()
                await progress?(snapshot())
                start(&group)
            }
        }
        guard ids.isEmpty || completedBatches > 0 else { throw PCGamesError.incompleteCatalog(0) }
        var revised = false
        for index in revalidations.keys.sorted() {
            guard let revalidation = revalidations[index] else { continue }
            let revalidated = try await CancellableWait.value(of: revalidation)
            if !revalidated.withdrawn.isEmpty {
                // The network no longer returns these products, so saved details can't resolve them.
                resolved[index] = (resolved[index] ?? []).filter { !revalidated.withdrawn.contains($0.ProductId) }
                revised = true
            }
            let changed = revalidated.changed
            guard !changed.isEmpty else { continue }
            let updated = batches[index].filter(changed.contains)
            do {
                let fresh = try products(try await descriptors.load(ids: updated, market: market, language: language),
                                         batch: updated)
                resolved[index] = (resolved[index] ?? []).filter { !changed.contains($0.ProductId) } + fresh
                revised = true
            } catch is CancellationError { throw CancellationError() }
            catch {
                Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")
                    .warning("Revalidated PC descriptors couldn't be read; saved details remain")
            }
        }
        try Task.checkCancellation()
        if revised { await progress?(snapshot()) }
        return snapshot()
    }
}

/// Awaits an unstructured task's value but stops waiting, without cancelling the task, when the caller is cancelled.
enum CancellableWait {
    static func value<T: Sendable>(of task: Task<T, Never>) async throws -> T {
        let gate = ResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                Task { gate.resume(.success(await task.value)) }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }

    private final class ResumeGate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let early {
                finished = true
                self.early = nil
                lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard let continuation else {
                if early == nil { early = result }
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }
}

