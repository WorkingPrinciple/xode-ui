// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

// This verifier has no production trust anchors or activation path.
enum CalimochoIndexVerifier {
    static let payloadType = "application/vnd.calimocho.engine-index+json; version=1"
    static let teamID = "M62Z4M5EUY"
    static let digestPattern = "[0-9a-f]{64}"
    static let enginePattern = #"calimocho-[0-9]+\.[0-9]+-[0-9A-Za-z.]+-[0-9]{2,}"#
    static let tagPattern = #"engine-[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.]+)*"#

    struct HighWater: Equatable, Codable, Sendable {
        let epoch: Int
        let version: Int
        let payloadSHA256: String
        let keyIDs: [String]

        enum CodingKeys: String, CodingKey {
            case epoch
            case version = "index_version"
            case payloadSHA256 = "payload_sha256"
            case keyIDs = "keyids"
        }
    }

    struct Revocation: Equatable, Codable, Sendable {
        let engineID: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case engineID = "engine_id"
            case reason
        }
    }

    struct State: Equatable, Codable, Sendable {
        let schema: String
        let highWater: HighWater
        let revokedEngines: [Revocation]

        enum CodingKeys: String, CodingKey {
            case schema
            case highWater = "high_water"
            case revokedEngines = "revoked_engines"
        }

        static func decode(_ raw: Data) throws -> Self {
            let fields = try CalimochoIndexJSON.parse(raw, limit: 8_388_608).object(
                ["schema", "high_water", "revoked_engines"])
            try fields.field("schema").equals("calimocho-engine-index-state/1")
            let high = try fields.field("high_water").object(["epoch", "index_version", "payload_sha256", "keyids"])
            let mark = try HighWater(
                epoch: high.field("epoch").integer(), version: high.field("index_version").integer(),
                payloadSHA256: high.field("payload_sha256").text(digestPattern),
                keyIDs: high.field("keyids").array(min: 1, max: 4).map { try $0.text(digestPattern) })
            guard Set(mark.keyIDs).count == mark.keyIDs.count else {
                throw CalimochoIndexError.invalid("duplicate high-water signer")
            }
            return State(schema: "calimocho-engine-index-state/1", highWater: mark,
                         revokedEngines: try revocations(fields.field("revoked_engines"), max: 1024))
        }
    }

    struct Engine: Equatable, Sendable {
        let id: String
        let version: String
        let minimumAppVersion: String
        let fields: [String: CalimochoIndexJSON]
    }

    struct Verified {
        let engines: [Engine]
        let highWater: HighWater
        let declaredRevocations: [Revocation]
        let embeddedRevocations: [Revocation]

        // Persisted revocations must be supplied independently of resettable high-water state.
        func eligible(appVersion: String, installedVersion: String?,
                      persistedRevocations: Set<String>) throws -> [Engine] {
            let app = try version(appVersion, engine: false)
            let installed = try installedVersion.map { try version($0, engine: true) }
            let revoked = Set((declaredRevocations + embeddedRevocations).map(\.engineID))
                .union(persistedRevocations)
            return try engines.filter {
                let minimum = try version($0.minimumAppVersion, engine: false)
                let candidate = try version($0.version, engine: true)
                return !revoked.contains($0.id) && !app.lexicographicallyPrecedes(minimum)
                    && (installed.map { $0.lexicographicallyPrecedes(candidate) } ?? true)
            }

        }
    }

    struct Accepted {
        let verified: Verified
        let state: State

        func eligible(appVersion: String, installedVersion: String?) throws -> [Engine] {
            try verified.eligible(appVersion: appVersion, installedVersion: installedVersion,
                                  persistedRevocations: Set(state.revokedEngines.map(\.engineID)))
        }
    }

    static func verify(envelope: Data, trust: Data, state rawState: Data?, now: Date) throws -> Accepted {
        let state = try rawState.map(State.decode)
        let verified = try verify(envelope: envelope, trust: trust, highWater: state?.highWater, now: now)
        var revocations: [String: Revocation] = [:]
        // A revoked signer resets only high-water, never the revocation history.
        for item in verified.embeddedRevocations + (state?.revokedEngines ?? []) + verified.declaredRevocations {
            if revocations[item.engineID] == nil { revocations[item.engineID] = item }
        }
        guard revocations.count <= 1024 else { throw CalimochoIndexError.rejected("revocation_overflow") }
        return Accepted(verified: verified, state: State(
            schema: "calimocho-engine-index-state/1", highWater: verified.highWater,
            revokedEngines: revocations.values.sorted { $0.engineID < $1.engineID }))
    }

    private struct Key {
        let id: String
        let publicKey: Curve25519.Signing.PublicKey
        let epoch: Int
        let active: Bool
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64(_ value: CalimochoIndexJSON, size: Int? = nil) throws -> Data {
        let text = try value.text("[A-Za-z0-9+/]*={0,2}", min: 0, max: 1_398_104)
        guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text,
              size.map({ bytes.count == $0 }) ?? true else {
            throw CalimochoIndexError.rejected("noncanonical_base64")
        }
        return bytes
    }

    static func pae(_ payload: Data) -> Data {
        Data("DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payload.count) ".utf8) + payload
    }

    static func verify(envelope raw: Data, trust rawTrust: Data, highWater: HighWater?,
                       now: Date) throws -> Verified {
        let trust = try CalimochoIndexJSON.parse(rawTrust, limit: 65_536).object(
            ["schema", "keys", "revoked_keyids", "floor", "revoked_engines"], optional: ["description"])
        try trust.field("schema").equals("calimocho-engine-index-trust/1")
        if let description = trust["description"] { _ = try description.text(min: 0, max: 2000) }
        let revokedKeys = try Set(trust.field("revoked_keyids").array(max: 64).map {
            try $0.text(digestPattern)
        })
        let floor = try trust.field("floor").object(["epoch", "index_version"])
        let floorEpoch = try floor.field("epoch").integer()
        let floorVersion = try floor.field("index_version").integer()
        var keys: [String: Key] = [:]
        for item in try trust.field("keys").array(min: 1, max: 8) {
            let fields = try item.object(["keyid", "public_key", "epoch", "status", "created"], optional: ["note"])
            let id = try fields.field("keyid").text(digestPattern)
            let bytes = try base64(fields.field("public_key"), size: 32)
            let status = try fields.field("status").text("active|retired")
            _ = try fields.field("created").text("[0-9]{4}-[0-9]{2}-[0-9]{2}")
            if let note = fields["note"] { _ = try note.text(min: 0, max: 500) }
            guard digest(bytes) == id, keys[id] == nil else {
                throw CalimochoIndexError.invalid("trust key identity")
            }
            keys[id] = try Key(id: id, publicKey: .init(rawRepresentation: bytes),
                               epoch: fields.field("epoch").integer(),
                               active: status == "active" && !revokedKeys.contains(id))
        }
        let embeddedRevocations = try revocations(trust.field("revoked_engines"))
        let envelope = try CalimochoIndexJSON.parse(raw, limit: 1_572_864).object(
            ["payloadType", "payload", "signatures"])
        guard try envelope.field("payloadType").text() == payloadType else {
            throw CalimochoIndexError.rejected("payload_type")
        }
        let payloadBytes = try base64(envelope.field("payload"))
        guard payloadBytes.count <= 1_048_576 else { throw CalimochoIndexError.invalid("payload size") }
        var verified: [String: Int] = [:]
        for item in try envelope.field("signatures").array(min: 1, max: 4) {
            let signature = try item.object(["keyid", "sig"])
            let id = try signature.field("keyid").text(digestPattern)
            let bytes = try base64(signature.field("sig"), size: 64)
            if let key = keys[id], key.active,
               key.publicKey.isValidSignature(bytes, for: pae(payloadBytes)) {
                verified[id] = key.epoch
            }
        }
        guard !verified.isEmpty else { throw CalimochoIndexError.rejected("no_trusted_signature") }
        let payload = try CalimochoIndexJSON.parse(payloadBytes, limit: 1_048_576).object(
            ["schema", "epoch", "index_version", "generated_at", "expires_at", "publisher", "engines", "revoked"])
        try payload.field("schema").equals("calimocho-engine-index/1")
        try payload.field("publisher").equals("WorkingPrinciple/calimocho")
        let epoch = try payload.field("epoch").integer()
        let indexVersion = try payload.field("index_version").integer()
        let signers = verified.filter { $0.value == epoch }.keys.sorted()
        guard !signers.isEmpty else { throw CalimochoIndexError.rejected("key_epoch") }
        let generated = try timestamp(payload.field("generated_at"))
        let expires = try timestamp(payload.field("expires_at"))
        guard expires > generated, expires.timeIntervalSince(generated) <= 90 * 86_400 else {
            throw CalimochoIndexError.invalid("validity interval")
        }
        guard now <= expires.addingTimeInterval(300) else { throw CalimochoIndexError.rejected("expired") }
        guard now >= generated.addingTimeInterval(-300) else { throw CalimochoIndexError.rejected("not_yet_valid") }
        let engines = try payload.field("engines").array(max: 64).map(engine)
        let declaredRevocations = try revocations(payload.field("revoked"))
        guard Set(engines.map(\.id)).count == engines.count,
              Set(declaredRevocations.map(\.engineID)).isDisjoint(with: engines.map(\.id)) else {
            throw CalimochoIndexError.invalid("duplicate or revoked engine")
        }
        guard epoch > floorEpoch || (epoch == floorEpoch && indexVersion >= floorVersion) else {
            throw CalimochoIndexError.rejected("below_floor")
        }
        let payloadDigest = digest(payloadBytes)
        var previous = highWater
        if let mark = previous {
            guard (1...2_147_483_647).contains(mark.epoch), (1...2_147_483_647).contains(mark.version),
                  !mark.keyIDs.isEmpty, mark.keyIDs.count <= 4,
                  Set(mark.keyIDs).count == mark.keyIDs.count else {
                throw CalimochoIndexError.invalid("high-water state")
            }
            _ = try CalimochoIndexJSON.string(mark.payloadSHA256).text(digestPattern)
            for key in mark.keyIDs { _ = try CalimochoIndexJSON.string(key).text(digestPattern) }
            if !revokedKeys.isDisjoint(with: mark.keyIDs) { previous = nil }
        }
        if let mark = previous {
            guard epoch > mark.epoch || (epoch == mark.epoch && indexVersion >= mark.version) else {
                throw CalimochoIndexError.rejected("rollback")
            }
            if epoch == mark.epoch && indexVersion == mark.version && payloadDigest != mark.payloadSHA256 {
                throw CalimochoIndexError.rejected("equivocation")
            }
        }
        let retainedKeys: [String]
        if let mark = previous, mark.epoch == epoch, mark.version == indexVersion {
            retainedKeys = mark.keyIDs
        } else { retainedKeys = signers }
        return Verified(engines: engines,
                        highWater: HighWater(epoch: epoch, version: indexVersion,
                                             payloadSHA256: payloadDigest, keyIDs: retainedKeys),
                        declaredRevocations: declaredRevocations, embeddedRevocations: embeddedRevocations)
    }

    static func version(_ text: String, engine: Bool) throws -> [UInt64] {
        let component = "(?:0|[1-9][0-9]*)"
        let pattern = engine ? "0\\.\(component)\\.\(component)\\.\(component)"
                             : "\(component)\\.\(component)\\.\(component)"
        _ = try CalimochoIndexJSON.string(text).text(pattern)
        return try text.split(separator: ".").map {
            guard let value = UInt64($0) else { throw CalimochoIndexError.invalid("version overflow") }
            return value
        }
    }

    private static func timestamp(_ value: CalimochoIndexJSON) throws -> Date {
        let text = try value.text("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw CalimochoIndexError.invalid("timestamp")
        }
        return date
    }

    private static func revocations(_ value: CalimochoIndexJSON, max: Int = 256) throws -> [Revocation] {
        var ids = Set<String>()
        var result: [Revocation] = []
        for item in try value.array(max: max) {
            let fields = try item.object(["engine_id", "reason"])
            let id = try fields.field("engine_id").text(enginePattern)
            let reason = try fields.field("reason").text(max: 500)
            guard ids.insert(id).inserted else { throw CalimochoIndexError.invalid("duplicate revocation") }
            result.append(Revocation(engineID: id, reason: reason))
        }
        return result
    }

    private static func releaseURL(_ value: CalimochoIndexJSON, path: String) throws {
        let text = try value.text()
        guard let url = URLComponents(string: text), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil,
              url.fragment == nil, url.percentEncodedPath == path,
              text == "https://github.com" + path else {
            throw CalimochoIndexError.rejected("url")
        }
    }

    private static func engine(_ value: CalimochoIndexJSON) throws -> Engine {
        let fields = try value.object(["engine_id", "version", "provider", "channel", "min_xode_version",
            "release_tag", "release_notes_url", "asset", "unpacked", "source", "source_commit",
            "install", "hashes", "signing", "apple_d3dmetal", "components"])
        let id = try fields.field("engine_id").text(enginePattern)
        let engineVersion = try fields.field("version").text()
        _ = try version(engineVersion, engine: true)
        let minimum = try fields.field("min_xode_version").text()
        _ = try version(minimum, engine: false)
        let provider = try fields.field("provider").object(["id", "contract_version"])
        try provider.field("id").equals("calimocho")
        _ = try provider.field("contract_version").integer(max: 1)
        _ = try fields.field("channel").text("prerelease|release")
        let tag = try fields.field("release_tag").text(tagPattern)
        try releaseURL(fields.field("release_notes_url"), path: "/WorkingPrinciple/calimocho/releases/tag/\(tag)")
        for name in ["asset", "source"] {
            let file = try fields.field(name).object(["name", "url", "size", "sha256"])
            let filename = try file.field("name").text("[A-Za-z0-9_-][A-Za-z0-9._-]*", max: 128)
            _ = try file.field("size").integer(max: 4_294_967_296)
            _ = try file.field("sha256").text(digestPattern)
            try releaseURL(file.field("url"), path: "/WorkingPrinciple/calimocho/releases/download/\(tag)/\(filename)")
        }
        let unpacked = try fields.field("unpacked").object(["size", "entries"])
        _ = try unpacked.field("size").integer(max: 8_589_934_592)
        _ = try unpacked.field("entries").integer(max: 200_000)
        _ = try fields.field("source_commit").text("[0-9a-f]{40}")
        let install = try fields.field("install").object(["directory"])
        try install.field("directory").equals(id)
        let hashes = try fields.field("hashes").object(
            ["wine_sha256", "wineserver_sha256", "loader_sha256", "manifest_sha256", "engine_json_sha256"])
        for hash in hashes.values { _ = try hash.text(digestPattern) }
        let signing = try fields.field("signing").object(["team_id", "notarization_id"])
        try signing.field("team_id").equals(teamID)
        _ = try signing.field("notarization_id").text("[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
        let apple = try fields.field("apple_d3dmetal").object(["version", "binary_sha256"])
        _ = try apple.field("version").text("[0-9A-Za-z._+-]+", max: 32)
        _ = try apple.field("binary_sha256").text(digestPattern)
        let components = try fields.field("components").object(["wine", "d3dmetal", "moltenvk"])
        for component in components.values { _ = try component.text("[0-9A-Za-z._+-]+", max: 32) }
        return Engine(id: id, version: engineVersion, minimumAppVersion: minimum, fields: fields)
    }
}
