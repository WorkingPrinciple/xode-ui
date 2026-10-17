// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusManagement

extension Checks {
    func registryDevelopmentChecks() throws {
        let artifacts: [(String, String, Int)] = [
            ("registry-development.schema", "13354f71c32e558792a83c64a0920b4831128c455385309d3b036ae93efc4b94", 85408),
            ("registry-development-positive", "af7c7338fb7cd98c1628bf68e0c1ee9deff2c6fe79e62125ce07b2e3723f4ba2", 49392),
            ("registry-development-negative", "4382bc13721a5841ceddf0abe169505152074ba7cc8475fdc56bc3e628c4098f", 83675)
        ]
        for (name, expectedHash, expectedBytes) in artifacts {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
                throw ManagementError.invalidPayload
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            check(hash == expectedHash && data.count == expectedBytes,
                  "Development registry artifact remains exact producer-qualified bytes: \(name)")
        }
        guard let schema = Bundle.module.url(forResource: "registry-development.schema",
                                             withExtension: "json", subdirectory: "Fixtures"),
              let positive = try fixture("registry-development-positive").array,
              let negative = try fixture("registry-development-negative").array else {
            throw ManagementError.invalidPayload
        }
        let development = try ContractValidator(schemaURL: schema,
                                                schemaIdentifier: "urn:xodus:management:1.0")
        let production = try ContractValidator()
        check(positive.count == 102 && negative.count == 99,
              "Separate development corpus contains exactly 102 positive and 99 negative frames")
        for (index, frame) in positive.enumerated() {
            do { try development.validate(frame); check(true, "Producer positive frame development \(index + 1)") }
            catch { check(false, "Producer positive frame development \(index + 1)") }
        }
        for (index, entry) in negative.enumerated() {
            guard let frame = entry["frame"] else { throw ManagementError.invalidPayload }
            do { try development.validate(frame); check(false, "Development negative frame \(index + 1) rejected") }
            catch { check(true, "Development negative frame \(index + 1) rejected") }
        }
        let oldFrames = try fixture("positive").array ?? []
        check(oldFrames.count == 100, "Production corpus remains separate and unchanged")
        for frame in oldFrames { try production.validate(frame) }
        let snapshots = positive.filter { $0["data"]?["installations"]?.array != nil }
        check(snapshots.count == 3, "Qualified registry witnesses include empty, legacy and nullable snapshots")
        for frame in snapshots {
            guard let data = frame["data"] else { throw ManagementError.invalidPayload }
            try development.validate(data, definition: "installedData")
            let snapshot = try data.decode(InstalledSnapshot.self)
            check(snapshot.scope == "managementRegistryOnly" && snapshot.completeness == "complete",
                  "Registry evidence stays local and complete, not ownership or launch permission")
            for record in snapshot.installations {
                let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
                check(try encoded.decode(RegisteredInstallation.self) == record,
                      "Registry records round-trip without losing required fields")
                if record.runtimeFingerprint == nil {
                    check(encoded["runtimeFingerprint"] == .null && record.health == .notVerified,
                          "Required unknown runtime is encoded as explicit null with truthful notVerified health")
                    check(record.health.label == "Registered, not verified",
                          "Unverified local metadata does not claim runtime or payload verification")
                    do { try production.validate(frame); check(false, "Production schema still rejects future registry evidence") }
                    catch { check(true, "Production schema still rejects future registry evidence") }
                } else {
                    check(record.runtimeFingerprint == "fixture-runtime" && record.health == .verified,
                          "Legacy non-null runtime and existing health remain valid")
                    try production.validate(frame)
                }
            }
        }
        guard let record = snapshots.compactMap({ $0["data"]?["installations"]?.array?.first }).last?.object else {
            throw ManagementError.invalidPayload
        }
        for (fingerprint, health) in [(JSONValue.null, InstallationHealth.verified),
                                     (.string("fixture-runtime"), .notVerified)] {
            var changed = record
            changed["runtimeFingerprint"] = fingerprint
            changed["health"] = .string(health.rawValue)
            let value = JSONValue.object(changed)
            try development.validate(value, definition: "installationRecord")
            let typed = try value.decode(RegisteredInstallation.self)
            let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(typed))
            check(encoded == value && typed.health == health,
                  "Runtime binding and registry health remain independent explicit fields")
        }
        var missing = record
        missing.removeValue(forKey: "runtimeFingerprint")
        var unknownHealth = record
        unknownHealth["health"] = .string("futureUnrecognizedHealth")
        let wrongTypes: [JSONValue] = [.bool(false), .integer(1), .array([]), .object([:])]
        var invalid = [JSONValue.object(missing), .object(unknownHealth)]
        invalid += wrongTypes.map { value in
            var changed = record
            changed["runtimeFingerprint"] = value
            return .object(changed)
        }
        for value in invalid {
            do {
                try development.validate(value, definition: "installationRecord")
                check(false, "Development schema rejects missing/type-invalid runtime and unknown health")
            } catch { check(true, "Development schema rejects missing/type-invalid runtime and unknown health") }
            do {
                _ = try value.decode(RegisteredInstallation.self)
                check(false, "Typed registry decoding rejects missing/type-invalid runtime and unknown health")
            } catch {
                check(error as? ManagementError == .invalidPayload,
                      "Typed registry decoding rejects missing/type-invalid runtime and unknown health")
            }
        }
        let failures: [(String, Bool, String)] = [
            ("REGISTRY_RECOVERY_REQUIRED", false, "Local staging transaction requires explicit recovery. No active version or saves were replaced."),
            ("STATE_LOCKED", true, "Local staging scope is being modified. Retry its snapshot later."),
            ("STATE_LOCKED", true, "Local staging scope changed during observation. Retry its snapshot later."),
            ("REGISTRY_RECOVERY_REQUIRED", true, "Local registry snapshot did not finish within its bounded deadline. No files were modified."),
            ("REGISTRY_RECOVERY_REQUIRED", true, "Local registry snapshot worker is unavailable. No files were modified."),
            ("INTERNAL_ERROR", false, "Read-only local worker failed unexpectedly. No files were modified.")
        ]
        for (code, retryable, message) in failures {
            let error: JSONValue = .object(["code": .string(code), "retryable": .bool(retryable),
                                           "message": .string(message)])
            let frame: JSONValue = .object(["kind": .string("result"), "protocol": .object([
                "major": .integer(1), "minor": .integer(0)]), "requestID": .string("fixture-registry-failure"),
                "ok": .bool(false), "error": error])
            try development.validate(frame)
            try production.validate(frame)
            let failure = try error.decode(WireFailure.self)
            check(failure.code == code && failure.retryable == retryable && failure.nativeConsentFailure == nil,
                  "Busy/recovery/corrupt-worker failures retain code and retryability without invented details")
            check(frame["data"] == nil && frame["ok"] == .bool(false),
                  "Registry read failure is not successful empty registry evidence")
            do {
                _ = try error.decode(InstalledSnapshot.self)
                check(false, "Failure payload cannot decode as a successful empty snapshot")
            } catch {
                check(error as? ManagementError == .invalidPayload,
                      "Failure payload cannot decode as a successful empty snapshot")
            }
            check(ManagementError.backendError(failure.code, retryable: failure.retryable)
                .localizedDescription == "Xodus reported \(code). No success was assumed.",
                  "Existing generic failure copy preserves explicit failure, not raw diagnostics")
        }
    }
}
