// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(name)")
}

func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); check(false, name) }
    catch { check(true, name) }
}

for invalid in [
    #"{"a":1,"a":2}"#, #"{"a":null,"\u0061":2}"#, #"{"nested":{"a":1,"a":2}}"#,
    #"{"a":NaN}"#, #"{"a":Infinity}"#, #"{"a":01}"#, #"{"a":1,}"#, #"[1,]"#,
    #"{"a":"\uD800"}"#, #"{"a":true}{}"#, #"{"a":tru}"#
] {
    rejects("Strict JSON rejects \(invalid)") {
        _ = try CalimochoIndexJSON.parse(Data(invalid.utf8), limit: 1024)
    }
}
check(try CalimochoIndexJSON.parse(Data(#"{"a":"quote\"slash\\","b":[null,true,-1.2e3]}"#.utf8),
                                   limit: 1024).object(["a", "b"]).count == 2,
      "Strict JSON accepts escaped strings and ordinary JSON literals")
rejects("JSON depth is bounded") {
    _ = try CalimochoIndexJSON.parse(Data((String(repeating: "[", count: 34) + "0"
        + String(repeating: "]", count: 34)).utf8), limit: 1024)
}
rejects("Invalid UTF-8 is refused") {
    _ = try CalimochoIndexJSON.parse(Data([34, 255, 34]), limit: 1024)
}
rejects("JSON bytes are bounded") {
    _ = try CalimochoIndexJSON.parse(Data("{}".utf8), limit: 1)
}
for invalid in ["1\n", "1\u{0}", "01", "1.0"] {
    rejects("Full-string integer pattern rejects \(invalid.debugDescription)") {
        _ = try CalimochoIndexJSON.string(invalid).text("[0-9]+")
        _ = try CalimochoIndexJSON.number(invalid).integer()
    }
}
rejects("Boolean cannot stand in for integer") {
    _ = try CalimochoIndexJSON.boolean(true).integer()
}
for invalid in ["Zh==", "Zg", "Zg==\n", " Zg=="] {
    rejects("Base64 must be canonical: \(invalid.debugDescription)") {
        _ = try CalimochoIndexVerifier.base64(.string(invalid))
    }
}
check(try CalimochoIndexVerifier.version("0.1120.4.6", engine: true)
    .lexicographicallyPrecedes(CalimochoIndexVerifier.version("0.1120.4.10", engine: true)),
      "Engine versions compare numerically")
rejects("Version integer overflow fails closed") {
    _ = try CalimochoIndexVerifier.version("0.1120.4.9999999999999999999999999999", engine: true)
}

struct Vector: Decodable {
    struct Case: Decodable {
        let name: String
        let envelope: String
        let trust: String
        let now: String
        let expect: String
        let eligible: [String]?
        let xode_version: String?
        let installed_version: String?
        let state: CalimochoIndexVerifier.State?
        let new_state: CalimochoIndexVerifier.State?
        let reason: String?
    }
    let payload_sha256: String
    let pae_sha256: String
    let cases: [Case]
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: calimocho-index-checks <frozen REQ124 tests/engine-index directory>")
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("vector.json")))
let payload = try Data(contentsOf: root.appendingPathComponent("payload.json"))
check(CalimochoIndexVerifier.digest(payload) == vector.payload_sha256, "Known-answer payload digest")
check(CalimochoIndexVerifier.digest(CalimochoIndexVerifier.pae(payload)) == vector.pae_sha256,
      "Known-answer byte-exact DSSE PAE digest")
let formatter = ISO8601DateFormatter()
for test in vector.cases {
    guard let now = formatter.date(from: test.now) else { fatalError("Invalid vector date") }
    let envelope = try Data(contentsOf: root.appendingPathComponent(test.envelope))
    let trust = try Data(contentsOf: root.appendingPathComponent(test.trust))
    do {
        let accepted = try CalimochoIndexVerifier.verify(
            envelope: envelope, trust: trust, state: test.state.map { try JSONEncoder().encode($0) }, now: now)
        let eligible = try accepted.eligible(appVersion: test.xode_version ?? "0.2.0",
                                            installedVersion: test.installed_version)
        check(test.expect == "valid", "\(test.name): accepted only when expected")
        check(eligible.map(\.id) == (test.eligible ?? []), "\(test.name): exact eligible engines")
        if let expected = test.new_state {
            check(accepted.state == expected, "\(test.name): exact state including durable revocations")
        }
    } catch {
        check(test.expect == "invalid", "\(test.name): \(error.localizedDescription)")
        if let expected = test.reason {
            check((error as? CalimochoIndexError)?.reasonCode == expected, "\(test.name): reason \(expected)")
        }
    }
}
let validEnvelope = try Data(contentsOf: root.appendingPathComponent("envelope.json"))
let validTrust = try Data(contentsOf: root.appendingPathComponent("trust.test.json"))
let now = formatter.date(from: "2026-10-27T00:00:00Z")!
for malformedTrust in [
    Data(#"{"schema":"calimocho-engine-index-trust/1","keys":[],"keys":[]}"#.utf8),
    Data(validTrust.prefix(validTrust.count / 2)),
    Data(repeating: 32, count: 65_537)
] {
    rejects("Malformed or oversized trust cannot be accepted") {
        _ = try CalimochoIndexVerifier.verify(envelope: validEnvelope, trust: malformedTrust,
                                             highWater: nil, now: now)
    }
}
for invalid in [
    CalimochoIndexVerifier.HighWater(epoch: 0, version: 1, payloadSHA256: vector.payload_sha256, keyIDs: ["a"]),
    .init(epoch: 1, version: 0, payloadSHA256: vector.payload_sha256, keyIDs: ["a"]),
    .init(epoch: 1, version: 1, payloadSHA256: "bad", keyIDs: ["a"]),
    .init(epoch: 1, version: 1, payloadSHA256: vector.payload_sha256, keyIDs: [])
] {
    rejects("Invalid high-water state fails closed") {
        _ = try CalimochoIndexVerifier.verify(envelope: validEnvelope, trust: validTrust,
                                             highWater: invalid, now: now)
    }
}
let accepted = try CalimochoIndexVerifier.verify(envelope: validEnvelope, trust: validTrust,
                                                highWater: nil, now: now)
check(try accepted.eligible(appVersion: "0.2.0", installedVersion: "0.1120.4.4",
                           persistedRevocations: Set(accepted.engines.map(\.id))).isEmpty,
      "Persisted revocations independently suppress all revoked offerings")
check(try accepted.eligible(appVersion: "0.1.0", installedVersion: "0.1120.4.4", persistedRevocations: []).isEmpty
      && accepted.announced(installedVersion: "0.1120.4.4", persistedRevocations: []).map(\.id)
        == accepted.engines.map(\.id)
      && accepted.announced(installedVersion: accepted.engines.first?.version, persistedRevocations: []).isEmpty
      && accepted.announced(installedVersion: "0.1120.4.4",
                            persistedRevocations: Set(accepted.engines.map(\.id))).isEmpty,
      "Engines needing a newer app are announced but not eligible; nothing newer than installed is announced")
rejects("Oversized envelope fails before parsing") {
    _ = try CalimochoIndexVerifier.verify(envelope: Data(repeating: 32, count: 1_572_865),
                                         trust: validTrust, highWater: nil, now: now)
}
let fullRevocations = (0..<1024).map {
    CalimochoIndexVerifier.Revocation(engineID: "calimocho-11.20-test-\(1000 + $0)", reason: "test")
}
let fullState = CalimochoIndexVerifier.State(schema: "calimocho-engine-index-state/1",
                                           highWater: accepted.highWater, revokedEngines: fullRevocations)
var overflowTrust = try JSONSerialization.jsonObject(with: validTrust) as! [String: Any]
overflowTrust["revoked_engines"] = [["engine_id": "calimocho-11.20-test-9999", "reason": "new"]]
let oldStateBytes = try JSONEncoder().encode(fullState)
do {
    _ = try CalimochoIndexVerifier.verify(envelope: validEnvelope,
                                         trust: JSONSerialization.data(withJSONObject: overflowTrust),
                                         state: oldStateBytes, now: now)
    check(false, "Revocation union overflow fails closed")
} catch {
    check((error as? CalimochoIndexError)?.reasonCode == "revocation_overflow",
          "Revocation union overflow fails closed with exact reason")
}
check(try CalimochoIndexVerifier.State.decode(oldStateBytes) == fullState,
      "Refusing an overflowing candidate leaves the input state intact")
print("\(checks) signed index checks, \(failures) failures. Frozen public test vectors only; no network or activation.")
exit(failures == 0 ? 0 : 1)
