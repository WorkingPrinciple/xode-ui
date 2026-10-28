// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import OdeManagement

extension Checks {
    func installPlanDevelopmentChecks() throws {
        for (name, expectedHash, expectedBytes) in [
            ("install-plan-development.schema", "06afc66d0a2e46cc68b4d4fe93d4b50ecaf24dfa791aed83f97904c03e9d5a6d", 117847),
            ("install-plan-development-positive", "8784b094a37c1a5171d7e15335d6158563c4dd97e1b13022ea0903189039c498", 57368),
            ("install-plan-development-negative", "d5aa70a80b0e047bda8f3ad29f0aa51e133bac65d2209709360359250a8864b1", 124954)
        ] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
                throw ManagementError.invalidPayload
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            check(hash == expectedHash && data.count == expectedBytes,
                  "Development plan artifact remains exact producer-qualified bytes: \(name)")
        }
        guard let schema = Bundle.module.url(forResource: "install-plan-development.schema",
                                             withExtension: "json", subdirectory: "Fixtures"),
              let positive = try fixture("install-plan-development-positive").array,
              let negative = try fixture("install-plan-development-negative").array,
              let alternatives = try fixture("install-plan-development.schema")["$defs"]?["installPlanError"]?["oneOf"]?.array else {
            throw ManagementError.invalidPayload
        }
        let development = try ContractValidator(schemaURL: schema, schemaIdentifier: "urn:ode:management:1.0")
        check(positive.count == 119 && negative.count == 172 && alternatives.count == 17,
              "Exact plan contract has 119 positive frames, 172 negatives and 17 complete tuple alternatives")
        for (index, frame) in positive.enumerated() {
            do { try development.validate(frame); check(true, "Producer positive frame plan \(index + 1)") }
            catch { check(false, "Producer positive frame plan \(index + 1)") }
        }
        for (index, entry) in negative.enumerated() {
            guard let frame = entry["frame"] else { throw ManagementError.invalidPayload }
            do { try development.validate(frame); check(false, "Plan development negative frame \(index + 1) rejected") }
            catch { check(true, "Plan development negative frame \(index + 1) rejected") }
        }
        let failureFrames = positive.filter { $0["error"]?["details"]?["category"]?.string == "installPlanFailure" }
        check(failureFrames.count == 17 && InstallPlanFailure.allCases.count == 17,
              "Typed cases cover the actual qualified producer's complete 17 failure witnesses")
        var decoded: [InstallPlanFailure] = []
        for frame in failureFrames {
            guard let error = frame["error"], let failure = InstallPlanFailure(error: error) else {
                throw ManagementError.invalidPayload
            }
            try development.validate(error, definition: "installPlanError")
            check(!decoded.contains(failure), "Each exact producer tuple identifies a distinct paired failure")
            decoded.append(failure)
            check(try error.decode(InstallPlanFailure.self) == failure,
                  "Strict Codable decoding agrees with complete-tuple classification")
            let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(failure))
            check(encoded == error, "Typed encoding retains the exact complete producer tuple")
            check(frame["ok"] == .bool(false) && frame["data"] == nil,
                  "Specific plan failure cannot become success, a ready plan or cached authorization")
        }
        check(InstallPlanFailure.allCases.allSatisfy { decoded.contains($0) },
              "Every typed case is backed by an actual qualified producer witness")
        check(decoded.filter(\.retryable) == [.providerUnavailable],
              "Only the exact provider/unavailable tuple is retryable")

        func reject(_ error: JSONValue) {
            do {
                try development.validate(error, definition: "installPlanError")
                check(false, "Invalid full plan tuple fails the authoritative development definition")
            } catch {
                check(error as? ManagementError == .invalidPayload,
                      "Invalid full plan tuple fails the authoritative development definition")
            }
            check(InstallPlanFailure(error: error) == nil,
                  "Malformed or mismatched tuple is never promoted to a typed plan failure")
            do {
                _ = try error.decode(InstallPlanFailure.self)
                check(false, "Invalid plan tuple fails Codable decoding")
            } catch {
                check(error as? ManagementError == .invalidPayload,
                      "Invalid plan tuple fails Codable decoding")
            }
        }
        for entry in negative {
            if let error = entry["frame"]?["error"],
               entry["name"]?.string?.hasPrefix("plan") == true {
                reject(error)
            }
        }
        for frame in failureFrames {
            guard let error = frame["error"]?.object, let details = error["details"]?.object else {
                throw ManagementError.invalidPayload
            }
            for key in ["code", "message", "retryable", "details"] {
                var missing = error
                missing.removeValue(forKey: key)
                reject(.object(missing))
                var wrongType = error
                wrongType[key] = .null
                reject(.object(wrongType))
            }
            for key in ["category", "stage", "reason"] {
                var missing = details
                missing.removeValue(forKey: key)
                var changed = error
                changed["details"] = .object(missing)
                reject(.object(changed))
                var wrongType = details
                wrongType[key] = .integer(1)
                changed["details"] = .object(wrongType)
                reject(.object(changed))
            }
            var extra = details
            extra["unexpected"] = .null
            var changed = error
            changed["details"] = .object(extra)
            reject(.object(changed))
            for other in failureFrames where other["error"]?["details"] != .object(details) {
                changed["details"] = other["error"]?["details"]
                reject(.object(changed))
            }
        }
        check(ManagementCommand.plan.resultDefinition == nil,
              "Planning still has no accepted ready Data variant or new result route")
        check(!positive.contains { $0["data"]?["planID"] != nil },
              "Development positive corpus contains no live ready plan")
        check(negative.contains { $0["name"]?.string == "reservedReadyPlanNotLiveSuccess" },
              "Reserved codec-only plan remains rejected as a live success frame")
    }
}
