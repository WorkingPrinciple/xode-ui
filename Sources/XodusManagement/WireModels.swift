// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

public enum ManagementCommand: String, CaseIterable, Codable, Sendable {
    case hello, authStatus = "auth.status", authBegin = "auth.begin", authCancel = "auth.cancel"
    case authLogout = "auth.logout", inventory = "inventory.snapshot", search = "catalog.search"
    case authVerify = "auth.verify"
    case libraryRecent = "library.recent"
    case product = "product.detail", plan = "install.plan", enqueue = "jobs.enqueue"
    case discover = "catalog.discover", query = "catalog.query"
    case pause = "jobs.pause", resume = "jobs.resume", cancel = "jobs.cancel", retry = "jobs.retry"
    case jobs = "jobs.snapshot", replay = "events.replay", installed = "installed.snapshot"
    case inspectInstallation = "installed.inspect"
    case launch = "game.launch", update = "game.update", rollback = "game.rollback", remove = "game.remove"
    case diagnostics = "diagnostics.export"

    public var resultDefinition: String? {
        switch self {
        case .hello: "helloData"
        case .authStatus, .authLogout, .authBegin, .authCancel: "authData"
        case .authVerify: "authVerifiedData"
        case .libraryRecent: "recentLibraryData"
        case .search: "searchData"
        case .discover: "discoveryData"
        case .query: "queryData"
        case .product: "productData"
        case .enqueue, .cancel, .retry: "jobData"
        case .jobs: "jobsData"
        case .replay: "replayData"
        case .installed: "installedData"
        case .inspectInstallation: "inspectionData"
        case .diagnostics: "diagnosticsData"
        default: nil
        }
    }

    public var defaultTimeout: Duration {
        switch self {
        case .authBegin, .authLogout: .seconds(600)
        case .authStatus: .seconds(130)
        default: .seconds(30)
        }
    }
}

public struct ManagementCapability: Codable, Equatable, Sendable, Identifiable {
    public let command: String
    public let supported: Bool
    public let audience: String?
    public let reason: String?
    public var id: String { command }
}

public struct ManagementHello: Codable, Equatable, Sendable {
    public let backendVersion: String
    public let runtimeFingerprint: String?
    public let capabilities: [ManagementCapability]
    public let sessionID: String
    public let schema: String
    public let catalogCorpus: String

    public func supports(_ command: ManagementCommand) -> Bool {
        capabilities.contains { $0.command == command.rawValue && $0.supported }
    }
}

public enum CredentialState: String, Codable, Sendable {
    case signedOut, credentialPresent, expired, invalid
}

public struct AuthenticationStatus: Codable, Equatable, Sendable {
    public let state: CredentialState
    public let credentialStore: String
    public let audience: String?
    public let expiresAt: String?
    public let entitlementAuthorized: Bool
    public let flow: AuthenticationFlow?
}

public struct AuthenticationVerification: Codable, Equatable, Sendable {
    public let verified: Bool
}

public enum AuthenticatedReadFailure: String, CaseIterable, Equatable, Sendable {
    case credentialUnavailable, profileChanged, authExchangeFailed, authRejected
    case transportFailed, responseInvalid, packageUnavailable

    public var code: String {
        switch self {
        case .credentialUnavailable, .profileChanged, .authExchangeFailed: "AUTH_INVALID"
        case .authRejected: "ACCESS_REVOKED"
        case .transportFailed: "NETWORK_UNAVAILABLE"
        case .responseInvalid: "INTEGRITY_FAILED"
        case .packageUnavailable: "PACKAGE_UNAVAILABLE"
        }
    }

    public var retryable: Bool { self == .authExchangeFailed || self == .transportFailed }
    public var message: String { "Authenticated read failed: \(rawValue)." }
    public var details: JSONValue {
        .object(["category": .string("authenticatedReadFailure"), "stage": .string(rawValue)])
    }

    public init?(error: JSONValue) {
        guard let object = error.object, Set(object.keys) == ["code", "message", "retryable", "details"],
              let details = object["details"]?.object, Set(details.keys) == ["category", "stage"],
              details["category"]?.string == "authenticatedReadFailure",
              let stage = details["stage"]?.string, let failure = Self(rawValue: stage),
              object["code"]?.string == failure.code, object["message"]?.string == failure.message,
              object["retryable"]?.boolean == failure.retryable else { return nil }
        self = failure
    }
}

public enum AuthenticationFlowState: String, Codable, Sendable {
    case pending, completed, cancelled, failed
}
public struct AuthenticationFlow: Codable, Equatable, Sendable {
    public let flowID: String
    public let state: AuthenticationFlowState
    public let error: WireFailure?
}

public struct ProductEntitlement: Codable, Equatable, Sendable {
    public let kind: Entitlement
    public let source: String
    public let checkedAt: String?
    public let expiresAt: String?
}
public struct ProductInstallability: Codable, Equatable, Sendable {
    public let kind: Installability
    public let packageID: String?
    public let packageVersion: String?
    public let reason: String?
}
public struct ProductCompatibility: Codable, Equatable, Sendable {
    public let kind: Compatibility
    public let source: String
    public let checkedAt: String?
    public let os: String?
    public let architecture: String?
    public let runtimeFingerprint: String?
}
public struct ProductInstallation: Codable, Equatable, Sendable {
    public let kind: String
    public let installationID: String?
    public let packageVersion: String?
    public let runtimeFingerprint: String?
}
public struct ProductInventory: Codable, Equatable, Sendable {
    public let completeness: String
    public let checkedAt: String?
    public let lastCompleteAt: String?
    public let source: String?
    public let reason: String?
}
public struct ProductEvidence: Codable, Equatable, Sendable, Identifiable {
    public let productID: String
    public let editionID: String
    public let entitlement: ProductEntitlement
    public let installability: ProductInstallability
    public let compatibility: ProductCompatibility
    public let installation: ProductInstallation
    public let inventory: ProductInventory
    public var id: String { editionID }
}
public struct CatalogProduct: Codable, Equatable, Sendable, Identifiable {
    public let productID: String
    public let title: String
    public let market: String
    public let language: String
    public let source: String
    public let checkedAt: String
    public let freshness: String
    public let editions: [ProductEvidence]
    public let pcCatalogCandidate: Bool
    public let resolvedLanguage: String?
    public let artwork: [CatalogArtworkReference]
    public let artworkStatus: CatalogArtworkStatus
    public var id: String { productID }

    public func validatePublicScope(market: String, language: String) throws {
        try validatePublicScope(market: market, language: language, requiresPCCandidate: true)
    }

    fileprivate func validatePublicScope(market: String, language: String, requiresPCCandidate: Bool) throws {
        try CatalogArtworkReference.validate(artwork, status: artworkStatus)
        guard artwork.allSatisfy({ $0.source == .displayCatalog && $0.role != .tile }) else {
            throw ManagementError.invalidPayload
        }
        guard self.market == market, self.language.caseInsensitiveCompare(language) == .orderedSame,
              (!requiresPCCandidate || pcCatalogCandidate), source != "fixture",
              Set(editions.map(\.id)).count == editions.count,
              editions.allSatisfy({ $0.productID == id && $0.entitlement.kind == .unknown }) else {
            throw ManagementError.invalidPayload
        }
        if let resolvedLanguage {
            let actual = resolvedLanguage.lowercased(), requested = language.lowercased()
            guard actual == requested || (!actual.contains("-") && requested.hasPrefix(actual + "-")) else {
                throw ManagementError.invalidPayload
            }
        }
    }
}
public struct CatalogSearch: Codable, Equatable, Sendable {
    public let products: [CatalogProduct]
    public let corpus: String
    public let completeness: String
    public let nextCursor: String?
    public let cacheRevision: UInt64
}
public struct ProductResult: Codable, Sendable {
    public let product: CatalogProduct
}

public struct InstallationInspection: Codable, Equatable, Sendable {
    public let scope: String
    public let completeness: String
    public let freshness: String
    public let checkedAt: String
    public let directory: String
    public let marker: InspectionMarker
    public let assessment: InspectionAssessment

    public func validateSelection(directory: String) throws {
        guard self.directory == directory, scope == "userSelectedDirectory",
              completeness == "partial", freshness == "live",
              marker.relativePath == ".xodus-streaming.msixvc", marker.format == "msft-xvd",
              assessment.kind == "externalMarkerDetected", !assessment.registered,
              assessment.retailIdentity == "unknown", assessment.fileVerification == "notPerformed",
              assessment.entitlement == "unknown", assessment.compatibility == "unknown",
              !assessment.launchable else { throw ManagementError.invalidPayload }
    }
}

public struct InspectionMarker: Codable, Equatable, Sendable {
    public let relativePath: String
    public let bytes: UInt64
    public let observedMetadataSHA256: String
    public let format: String
    public let formatVersion: UInt32
    public let xvdType: UInt32
    public let contentTypeRaw: UInt32
    public let volumeFlagsRaw: UInt32
    public let contentID: String
    public let headerProductGUID: String
    public let headerPDUID: String
    public let observedPackageVersion: String
}

public struct InspectionAssessment: Codable, Equatable, Sendable {
    public let kind: String
    public let registered: Bool
    public let retailIdentity: String
    public let fileVerification: String
    public let entitlement: String
    public let compatibility: String
    public let launchable: Bool
    public let reason: String
}

public struct DiscoveryFailure: Codable, Equatable, Sendable, Identifiable {
    public let productID: String
    public let error: WireFailure
    public var id: String { productID }
}

public struct CatalogDiscovery: Codable, Equatable, Sendable {
    public let corpus: String
    public let completeness: String
    public let source: String
    public let checkedAt: String
    public let freshness: String
    public let corpusRevision: String
    public let products: [CatalogProduct]
    public let failures: [DiscoveryFailure]
    public let nextCursor: String?

    public func validatePublicScope(market: String, language: String, limit: Int) throws {
        let ids = products.map(\.id) + failures.map(\.id)
        guard corpus == "pcGamePassDiscovery", completeness == "partial",
              source == "MicrosoftGamePassSigls:v3", freshness == "live",
              !ids.isEmpty, ids.count <= limit, Set(ids).count == ids.count else {
            throw ManagementError.invalidPayload
        }
        if let nextCursor {
            let prefix = "d1-\(corpusRevision)-"
            guard nextCursor.hasPrefix(prefix), let offset = UInt64(nextCursor.dropFirst(prefix.count)),
                  offset > 0 else { throw ManagementError.invalidPayload }
        }
        for product in products {
            try product.validatePublicScope(market: market, language: language, requiresPCCandidate: false)
        }
    }
}

public struct CatalogQuery: Codable, Equatable, Sendable {
    public let corpus: String
    public let completeness: String
    public let source: String
    public let checkedAt: String
    public let freshness: String
    public let query: String
    public let products: [CatalogProduct]
    public let failures: [DiscoveryFailure]
    public let nextCursor: String?

    public func validatePublicScope(query: String, market: String, language: String, limit: Int) throws {
        let ids = products.map(\.id) + failures.map(\.id)
        guard corpus == "publicMicrosoftStoreSearch", completeness == "partial",
              source == "MicrosoftStoreEdge:v9.0/searchResults", freshness == "live",
              self.query == query, ids.count <= limit, Set(ids).count == ids.count,
              !ids.isEmpty || nextCursor == nil else {
            throw ManagementError.invalidPayload
        }
        for product in products { try product.validatePublicScope(market: market, language: language) }
    }
}

public struct JobProduct: Codable, Equatable, Sendable {
    public let productID: String
    public let market: String
    public let language: String
    public let refresh: String
}
public struct WireFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let nativeConsentFailure: NativeConsentFailure?

    private enum CodingKeys: String, CodingKey { case code, message, retryable, details }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        let details = try container.decodeIfPresent(JSONValue.self, forKey: .details)
        nativeConsentFailure = code == "AUTH_INVALID" ? NativeConsentFailure(details: details) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retryable, forKey: .retryable)
        if let nativeConsentFailure {
            try container.encode(nativeConsentFailure.details, forKey: .details)
        }
    }
}

public enum NativeConsentFailure: String, CaseIterable, Equatable, Sendable {
    case bootstrapInvalid, clientUnavailable, credentialStorageUnavailable, storedCredentialInvalid
    case providerRequestFailed, providerProofInvalid, proofUnavailable, pipelineFailed, proofInvalid
    case workerOutcomeUnavailable
    case registrationProofInvalid, tokenResponseInvalid, tokenProofInvalid, tokenStructureInvalid
    case tokenKindInvalid, tokenAudienceInvalid, tokenCipherInvalid, tokenSecretInvalid
    case tokenXmlBoundInvalid, tokenXmlParseInvalid, tokenCipherEncodingInvalid

    public var stage: String {
        switch self {
        case .bootstrapInvalid: "privateBootstrap"
        case .clientUnavailable: "clientInitialization"
        case .credentialStorageUnavailable, .storedCredentialInvalid, .providerRequestFailed, .providerProofInvalid,
             .registrationProofInvalid, .tokenResponseInvalid, .tokenProofInvalid, .tokenStructureInvalid,
             .tokenKindInvalid, .tokenAudienceInvalid, .tokenCipherInvalid, .tokenSecretInvalid,
             .tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid:
            "devicePreparation"
        case .proofUnavailable: "deviceProof"
        case .pipelineFailed: "nativeSignIn"
        case .proofInvalid: "storeProof"
        case .workerOutcomeUnavailable: "stageUnavailable"
        }
    }

    public init?(details: JSONValue?) {
        guard let object = details?.object, Set(object.keys) == ["category", "stage", "reason"],
              object["category"]?.string == "nativeConsentFailure",
              let reason = object["reason"]?.string, let value = Self(rawValue: reason),
              object["stage"]?.string == value.stage else { return nil }
        self = value
    }

    public var details: JSONValue {
        .object(["category": .string("nativeConsentFailure"), "stage": .string(stage), "reason": .string(rawValue)])
    }
}
public enum CatalogJobState: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}
public struct CatalogJob: Codable, Equatable, Sendable, Identifiable {
    public let jobID: String
    public let revision: UInt64
    public let kind: String
    public let state: CatalogJobState
    public let requestID: String
    public let createdAt: String
    public let updatedAt: String
    public let product: JobProduct
    public let attempt: Int
    public let error: WireFailure?
    public var id: String { jobID }
}
public struct JobResult: Codable, Sendable {
    public let job: CatalogJob
    public let watermark: UInt64
}
public struct JobsSnapshot: Codable, Sendable {
    public let sessionID: String
    public let watermark: UInt64
    public let jobs: [CatalogJob]
}
public struct ManagementEvent: Codable, Equatable, Sendable {
    public let sessionID: String
    public let sequence: UInt64
    public let requestID: String
    public let jobID: String
    public let revision: UInt64
    public let event: String
    public let data: CatalogJob
}
public struct EventReplay: Codable, Sendable {
    public let sessionID: String
    public let watermark: UInt64
    public let events: [ManagementEvent]
    public let hasMore: Bool
}

public struct ManagementVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
}

public enum InstallationHealth: String, Codable, Sendable {
    case verified, notVerified, broken, recoveryRequired

    public var label: String {
        switch self {
        case .verified: "Registered, last verified"
        case .notVerified: "Registered, not verified"
        case .broken: "Needs repair"
        case .recoveryRequired: "Recovery required"
        }
    }
}

public struct RegisteredInstallation: Codable, Equatable, Sendable, Identifiable {
    public let installationID: String
    public let revision: UInt64
    public let productID: String
    public let editionID: String
    public let packageID: String
    public let packageVersion: String
    public let packageDigest: String
    public let runtimeFingerprint: String?
    public let managedRoot: String
    public let savePolicy: String
    public let health: InstallationHealth
    public var id: String { installationID }

    private enum CodingKeys: String, CodingKey {
        case installationID, revision, productID, editionID, packageID, packageVersion, packageDigest
        case runtimeFingerprint, managedRoot, savePolicy, health
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try container.decode(String.self, forKey: .installationID)
        revision = try container.decode(UInt64.self, forKey: .revision)
        productID = try container.decode(String.self, forKey: .productID)
        editionID = try container.decode(String.self, forKey: .editionID)
        packageID = try container.decode(String.self, forKey: .packageID)
        packageVersion = try container.decode(String.self, forKey: .packageVersion)
        packageDigest = try container.decode(String.self, forKey: .packageDigest)
        runtimeFingerprint = try container.decode(String?.self, forKey: .runtimeFingerprint)
        managedRoot = try container.decode(String.self, forKey: .managedRoot)
        savePolicy = try container.decode(String.self, forKey: .savePolicy)
        health = try container.decode(InstallationHealth.self, forKey: .health)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(revision, forKey: .revision)
        try container.encode(productID, forKey: .productID)
        try container.encode(editionID, forKey: .editionID)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(packageVersion, forKey: .packageVersion)
        try container.encode(packageDigest, forKey: .packageDigest)
        try container.encode(runtimeFingerprint, forKey: .runtimeFingerprint)
        try container.encode(managedRoot, forKey: .managedRoot)
        try container.encode(savePolicy, forKey: .savePolicy)
        try container.encode(health, forKey: .health)
    }
}

public struct InstalledSnapshot: Codable, Equatable, Sendable {
    public let registryVersion: ManagementVersion
    public let scope: String
    public let completeness: String
    public let installations: [RegisteredInstallation]
    public let watermark: UInt64
}

public struct ActivityStore: Sendable {
    public private(set) var sessionID: String?
    public private(set) var watermark: UInt64 = 0
    public private(set) var jobs: [CatalogJob] = []
    public private(set) var needsSnapshot = true
    public private(set) var isReconciling = false
    private var bufferedEvents: [ManagementEvent] = []

    public init() {}

    public mutating func beginSnapshot() throws {
        guard !isReconciling else { throw ManagementError.invalidEvent }
        isReconciling = true
        bufferedEvents = []
    }

    public mutating func abortSnapshot() {
        isReconciling = false
        bufferedEvents = []
        needsSnapshot = true
    }

    public mutating func apply(_ snapshot: JobsSnapshot) throws {
        guard snapshot.jobs.count <= 256, Set(snapshot.jobs.map(\.id)).count == snapshot.jobs.count else {
            throw ManagementError.invalidEvent
        }
        if snapshot.sessionID == sessionID && snapshot.watermark < watermark {
            throw ManagementError.invalidEvent
        }
        sessionID = snapshot.sessionID
        watermark = snapshot.watermark
        jobs = snapshot.jobs
        needsSnapshot = false
        let buffered = bufferedEvents
        bufferedEvents = []
        isReconciling = false
        for event in buffered { try apply(event) }
    }

    public mutating func apply(_ value: ManagementEvent) throws {
        if isReconciling {
            guard bufferedEvents.count < 128 else { throw ManagementError.outputOverflow }
            bufferedEvents.append(value)
            return
        }
        guard !needsSnapshot, value.sessionID == sessionID else {
            needsSnapshot = true
            return
        }
        if value.sequence <= watermark { return }
        guard watermark < UInt64.max, value.sequence == watermark + 1 else {
            needsSnapshot = true
            return
        }
        guard value.jobID == value.data.jobID, value.revision == value.data.revision,
              value.requestID == value.data.requestID else { throw ManagementError.invalidEvent }
        if let index = jobs.firstIndex(where: { $0.id == value.jobID }) {
            let previous = jobs[index]
            guard value.revision > previous.revision,
                  !previous.state.isTerminal || (previous.state == .failed && value.data.state == .queued) else {
                throw ManagementError.invalidEvent
            }
            jobs[index] = value.data
        } else {
            guard jobs.count < 256 else { throw ManagementError.outputOverflow }
            jobs.append(value.data)
        }
        watermark = value.sequence
    }
}
