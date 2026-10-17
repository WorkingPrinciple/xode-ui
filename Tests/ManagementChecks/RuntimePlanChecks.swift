// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import XodusCore
import XodusManagement

extension Checks {
    func runtimePlanChecks() async throws {
        let contract = try RuntimePlanContract()
        let corpus = try fixture("runtime-providers-v1")
        let positives = corpus["configurations"]?.array ?? []
        check(positives.count == 5, "Separate provider corpus pins four presets and Wine11/D3DMetal4 composition")
        for value in positives {
            let configuration = try value.decode(RuntimeProviderConfiguration.self)
            let encoded = try contract.request(configuration)
            check(try JSONDecoder().decode(JSONValue.self, from: encoded) == value,
                  "Provider configurations encode every required nullable field without inventing versions")
        }
        for (index, provider) in RuntimeProviderKind.allCases.enumerated() {
            check(try JSONDecoder().decode(JSONValue.self, from: contract.request(.preset(provider))) == positives[index],
                  "Four native preset declarations equal their canonical configurations")
        }
        for value in corpus["invalidConfigurations"]?.array ?? [] {
            do {
                _ = try contract.request(value.decode(RuntimeProviderConfiguration.self))
                check(false, "Canonical invalid provider configuration is rejected")
            } catch { check(true, "Canonical invalid provider configuration is rejected") }
        }
        let planValue = corpus["plans"]?.array?.first ?? .null
        let requested = try planValue["configuration"]?.decode(RuntimeProviderConfiguration.self)
        guard let requested else { throw ManagementError.invalidPayload }
        check(try requested.identity() == "1db702dead8f09d31d472d171910185758cd8c197e91d35d3dc78aabae745830",
              "Declared configuration identity matches the independent Rust field-order SHA256 fixture")
        var changed = requested
        changed.graphics.version = "4.1"
        check(try changed.identity() != requested.identity(), "Graphics changes cannot reuse the old configuration identity")
        changed = requested
        changed.engine.version = "11.1"
        check(try changed.identity() != requested.identity(), "Engine changes cannot reuse the old configuration identity")
        let data = try JSONEncoder().encode(planValue) + Data([10])
        check(try contract.response(data, requested: requested).configuration == requested,
              "Canonical pure plan is correlated to exact requested typed configuration and safe generation path")
        var invalid: [(String, JSONValue)] = []
        func mutate(_ key: String, _ value: JSONValue, _ name: String) {
            var fields = planValue.object ?? [:]
            fields[key] = value
            invalid.append((name, .object(fields)))
        }
        mutate("extra", .bool(false), "Extra output field")
        mutate("version", .bool(true), "Wrong-type version")
        mutate("launchable", .bool(true), "Success promotion")
        mutate("launchable", .string("false"), "Wrong-type launchable")
        mutate("installation", .string("installed"), "Installation evidence promotion")
        mutate("devicePreflight", .string("verified"), "Device evidence promotion")
        mutate("gameVerification", .string("verified"), "Game evidence promotion")
        mutate("generationID", .string("00000000-0000-4000-8000-000000000002"), "Generation/path suffix mismatch")
        mutate("prefixRelativePath", .string("/tmp/runtime-prefixes"), "Absolute prefix path")
        mutate("prefixRelativePath", .string("../runtime-prefixes"), "Escaping prefix path")
        mutate("prefixRelativePath", .string("runtime-prefixes/v1/\(String(repeating: "a", count: 64))/00000000-0000-4000-8000-000000000001"),
               "Different configuration path digest")
        mutate("configuration", positives[0], "Different configuration echo")
        for (name, value) in invalid {
            do {
                _ = try contract.response(JSONEncoder().encode(value) + Data([10]), requested: requested)
                check(false, "\(name) cannot be accepted as a pure configuration plan")
            } catch { check(error as? RuntimePlanningError == .invalidPlan, "\(name) cannot be accepted as a pure configuration plan") }
        }
        let text = String(decoding: data, as: UTF8.self)
        for bad in [
            Data(("{\"version\":1," + text.dropFirst()).utf8),
            Data(("{\"\\u0076ersion\":1," + text.dropFirst()).utf8),
            data + data, data.dropLast(), data + Data([10]),
            Data(repeating: 32, count: RuntimePlanContract.maximumOutputBytes + 1), Data([0xff, 10])
        ] {
            do {
                _ = try contract.response(Data(bad), requested: requested)
                check(false, "Duplicate/escaped-duplicate/multiple/truncated/oversized/nonUTF8 output fails closed")
            } catch { check(error as? RuntimePlanningError == .invalidPlan,
                          "Duplicate/escaped-duplicate/multiple/truncated/oversized/nonUTF8 output fails closed") }
        }
        for invalidVersion in [" ", " v1", "v1 ", "v1\n", "v1\u{7f}", "vérsion", String(repeating: "a", count: 65)] {
            var value = requested
            value.engine.version = invalidVersion
            do { _ = try contract.request(value); check(false, "Invalid declared component version is rejected") }
            catch { check(error as? RuntimePlanningError == .invalidConfiguration, "Invalid declared component version is rejected") }
        }
        var incomplete = requested
        incomplete.graphics.provenance = nil
        do { _ = try contract.request(incomplete); check(false, "A declared graphics backend requires provenance via schema else branch") }
        catch { check(error as? RuntimePlanningError == .invalidConfiguration,
                      "A declared graphics backend requires provenance via schema else branch") }
        let encodedConfiguration = try JSONDecoder().decode(JSONValue.self, from: contract.request(requested))
        for (component, keys) in [
            ("", ["providerVersion"]),
            ("engine", ["version", "artifactSha256"]),
            ("graphics", ["backend", "provenance", "version", "artifactSha256"])
        ] {
            for key in keys {
                var object = encodedConfiguration.object ?? [:]
                if component.isEmpty { object.removeValue(forKey: key) }
                else {
                    var nested = object[component]?.object ?? [:]
                    nested.removeValue(forKey: key)
                    object[component] = .object(nested)
                }
                do {
                    _ = try contract.request(JSONValue.object(object).decode(RuntimeProviderConfiguration.self))
                    check(false, "Every required nullable \(component).\(key) rejects omission")
                } catch { check(true, "Every required nullable \(component).\(key) rejects omission") }
            }
        }
        for hash in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            var value = requested
            value.graphics.artifactSha256 = hash
            do { _ = try contract.request(value); check(false, "Declared component digest is strict lowercase SHA256 or null") }
            catch { check(error as? RuntimePlanningError == .invalidConfiguration,
                          "Declared component digest is strict lowercase SHA256 or null") }
        }
        try await runtimeSubprocessChecks()
    }

    private func runtimeSubprocessChecks() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let client = RuntimePlanClient()
        var request = RuntimeProviderConfiguration.preset(.gptk4)
        let first = try await client.plan(executable: executable, configuration: request)
        let second = try await client.plan(executable: executable, configuration: request)
        check(first.configuration == request && first.generationID != second.generationID && !first.launchable,
              "Actual neutral subprocess waits for stdin EOF and returns fresh non-launchable generations")
        check(!(await client.hasOwnedProcess), "Successful planning drains EOF and observes clean owned child exit")
        for mode in ["old-engine", "nonzero-valid", "extra", "duplicate", "wrong-type", "mismatch",
                     "generation-mismatch", "oversized", "stderr-overflow", "truncated", "multiple", "signal"] {
            request.providerVersion = "mock:\(mode)"
            do {
                _ = try await client.plan(executable: executable, configuration: request)
                check(false, "Neutral \(mode) never promotes stdout into a plan")
            } catch {
                let expected: RuntimePlanningError = ["old-engine", "nonzero-valid", "signal"].contains(mode)
                    ? .unavailable : .invalidPlan
                check(error as? RuntimePlanningError == expected, "Neutral \(mode) never promotes stdout into a plan")
            }
            check(!(await client.hasOwnedProcess), "Neutral \(mode) leaves no owned planning child")
        }
        request.providerVersion = "mock:timeout"
        do {
            _ = try await client.plan(executable: executable, configuration: request, timeoutSeconds: 0.15)
            check(false, "Planning deadline stops a neutral retained-open child")
        } catch { check(error as? RuntimePlanningError == .timedOut,
                      "Planning deadline stops a neutral retained-open child") }
        check(!(await client.hasOwnedProcess), "Deadline cleanup reaps the owned child without any runtime/auth fallback")
        let cancelledRequest = request
        let pending = Task { try await client.plan(executable: executable, configuration: cancelledRequest) }
        try await Task.sleep(for: .milliseconds(75))
        pending.cancel()
        do { _ = try await pending.value; check(false, "Caller cancellation cannot accept a late plan") }
        catch { check(error as? RuntimePlanningError == .cancelled, "Caller cancellation cannot accept a late plan") }
        check(!(await client.hasOwnedProcess), "Cancelled planning reaps its owned child")
    }
}

enum MockRuntimePlan {
    static func run() -> Never {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty, input.count <= RuntimePlanContract.maximumInputBytes else { exit(2) }
            let configuration = try JSONDecoder().decode(RuntimeProviderConfiguration.self, from: input)
            let request = try RuntimePlanContract().request(configuration)
            guard try JSONDecoder().decode(JSONValue.self, from: request)
                == JSONDecoder().decode(JSONValue.self, from: input) else { exit(2) }
            let mode = configuration.providerVersion?.replacingOccurrences(of: "mock:", with: "") ?? ""
            if mode == "old-engine" { exit(2) }
            if mode == "timeout" {
                signal(SIGTERM, SIG_IGN)
                while true { usleep(10_000) }
            }
            if mode == "signal" { raise(SIGKILL); exit(2) }
            let generation = UUID().uuidString.lowercased()
            var fields: [String: JSONValue] = [
                "version": .integer(1),
                "configuration": try JSONDecoder().decode(JSONValue.self, from: input),
                "generationID": .string(generation),
                "prefixRelativePath": .string("runtime-prefixes/v1/\(try configuration.identity())/\(generation)"),
                "installation": .string("notInspected"), "devicePreflight": .string("notPerformed"),
                "gameVerification": .string("notVerified"), "launchable": .bool(false)
            ]
            if mode == "extra" { fields["extra"] = .null }
            if mode == "wrong-type" { fields["launchable"] = .string("false") }
            if mode == "mismatch" { fields["configuration"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(RuntimeProviderConfiguration.preset(.gptk3))) }
            if mode == "generation-mismatch" { fields["generationID"] = .string(UUID().uuidString.lowercased()) }
            var output = try JSONEncoder().encode(JSONValue.object(fields)) + Data([10])
            if mode == "duplicate" { output = Data(("{\"version\":1," + String(decoding: output.dropFirst(), as: UTF8.self)).utf8) }
            if mode == "oversized" { output = Data(repeating: 32, count: RuntimePlanContract.maximumOutputBytes + 1) }
            if mode == "stderr-overflow" { try FileHandle.standardError.write(contentsOf: Data(repeating: 32, count: 8_193)) }
            if mode == "truncated" { output.removeLast() }
            if mode == "multiple" { output += output }
            try FileHandle.standardOutput.write(contentsOf: output)
            exit(mode == "nonzero-valid" ? 2 : 0)
        } catch { exit(2) }
    }
}
