// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum InstallPlanFailure: Codable, CaseIterable, Equatable, Sendable {
    case credentialsUnavailable, credentialsProfileChanged, credentialsRejected
    case selectionAmbiguous, packageUnavailable, selectionApplicabilityUnproven, selectionUnsupported
    case formatUnsupported, integrityUnproven, layoutIncomplete, licenseAcquisitionRequired
    case destinationUnsupported, destinationChanged, spaceInsufficient
    case providerUnavailable, providerInvalidResponse, selectionExpired

    public var stage: String { tuple.stage }
    public var reason: String { tuple.reason }
    public var code: String { tuple.code }
    public var message: String { tuple.message }
    public var retryable: Bool { self == .providerUnavailable }

    public var details: JSONValue {
        .object(["category": .string("installPlanFailure"),
                 "stage": .string(stage), "reason": .string(reason)])
    }

    public init?(error: JSONValue) {
        guard let object = error.object, Set(object.keys) == ["code", "message", "retryable", "details"],
              let details = object["details"]?.object, Set(details.keys) == ["category", "stage", "reason"],
              details["category"]?.string == "installPlanFailure",
              let value = Self.allCases.first(where: {
                  details["stage"]?.string == $0.stage && details["reason"]?.string == $0.reason
                      && object["code"]?.string == $0.code && object["message"]?.string == $0.message
                      && object["retryable"]?.boolean == $0.retryable
              }) else { return nil }
        self = value
    }

    public init(from decoder: Decoder) throws {
        guard let value = Self(error: try JSONValue(from: decoder)) else {
            throw ManagementError.invalidPayload
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(["code": .string(code), "message": .string(message),
                              "retryable": .bool(retryable), "details": details]).encode(to: encoder)
    }

    private var tuple: (stage: String, reason: String, code: String, message: String) {
        switch self {
        case .credentialsUnavailable:
            ("credentials", "unavailable", "AUTH_INVALID",
             "Install planning requires a current saved launcher account.")
        case .credentialsProfileChanged:
            ("credentials", "profileChanged", "AUTH_INVALID",
             "The launcher account changed during install planning. Select the edition again.")
        case .credentialsRejected:
            ("credentials", "rejected", "ACCESS_REVOKED",
             "The package metadata provider rejected this account. No license was acquired.")
        case .selectionAmbiguous:
            ("selection", "ambiguous", "PACKAGE_AMBIGUOUS",
             "The selected edition does not resolve to exactly one PC package.")
        case .packageUnavailable:
            ("package", "unavailable", "PACKAGE_UNAVAILABLE",
             "The selected edition has no available matching PC base package.")
        case .selectionApplicabilityUnproven:
            ("selection", "applicabilityUnproven", "UNSUPPORTED_CONFIGURATION",
             "Package architecture, language and dependency applicability are not established by the available metadata.")
        case .selectionUnsupported:
            ("selection", "unsupported", "UNSUPPORTED_CONFIGURATION",
             "The selected edition has no package declared for the requested architecture and language.")
        case .formatUnsupported:
            ("format", "unsupported", "UNSUPPORTED_CONFIGURATION",
             "A supported authenticated pre-key package format has not been established.")
        case .integrityUnproven:
            ("integrity", "unproven", "INTEGRITY_FAILED",
             "The provider digest algorithm, encoding and coverage are not established.")
        case .layoutIncomplete:
            ("layout", "incomplete", "PACKAGE_UNAVAILABLE",
             "The pre-key expanded layout, padded file sizes and scratch bound are incomplete.")
        case .licenseAcquisitionRequired:
            ("license", "acquisitionRequired", "ACCESS_UNKNOWN",
             "Further planning would require a separately authorized license or key operation.")
        case .destinationUnsupported:
            ("destination", "unsupported", "UNSUPPORTED_CONFIGURATION",
             "Install planning currently supports only the existing private managed state root.")
        case .destinationChanged:
            ("destination", "changed", "PLAN_CHANGED",
             "The managed destination changed during install planning. No files were created.")
        case .spaceInsufficient:
            ("space", "insufficient", "INSUFFICIENT_SPACE",
             "The selected volume has insufficient space for the established peak allocation.")
        case .providerUnavailable:
            ("provider", "unavailable", "NETWORK_UNAVAILABLE",
             "The bounded package metadata read did not complete. No license or payload was requested.")
        case .providerInvalidResponse:
            ("provider", "invalidResponse", "INTEGRITY_FAILED",
             "Required package metadata is malformed or inconsistent.")
        case .selectionExpired:
            ("selection", "expired", "PLAN_EXPIRED",
             "The in-memory install planning observation expired. Resolve the selected edition again.")
        }
    }
}
