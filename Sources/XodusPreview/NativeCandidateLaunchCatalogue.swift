// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusManagement

struct NativeCandidateLaunchCatalogue: Decodable {
    struct Row: Decodable {
        let title: String
        let store_id: String
        let manifest_executable: String
        let manifest_sha256: String
        let profile: String
        let game_arguments: [String]
        let title_environment: [String: String]
        let status: String
        let ready_for_launch: Bool?
        let blocker: String?

        var admitted: Bool {
            status == "candidate, not game-qualified" && ready_for_launch != false
                && title_environment.isEmpty && game_arguments.isEmpty
                && ["creation-dx11-d3dmetal", "queue-winecx-nativejson"].contains(profile)
        }

        var launchProfile: NativeTitleLaunchProfile {
            NativeTitleLaunchProfile(
                version: 1, productID: store_id, engine: profile,
                shimDirectory: nil, environment: [:],
                unsetEnvironment: [
                    "XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM",
                    "CX_APPLEGPTK_LIBD3DSHARED_PATH",
                ],
                executable: manifest_executable)
        }

        func validateManifest(folder: URL) throws {
            let file = folder.appendingPathComponent("MicrosoftGame.config")
            try GameScriptFiles.checkPath(file)
            let bytes = try InstalledGameFiles.readRegular(file, maximumBytes: 1_048_576)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest_sha256
            else {
                throw NativeLaunchError.invalidProfile
            }
        }

        func validateEngine(_ entry: NativeEngineRegistry.Entry, fallback: String?) throws {
            guard admitted, fallback == nil, entry.name == profile,
                [
                    "XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM",
                    "CX_APPLEGPTK_LIBD3DSHARED_PATH",
                ].allSatisfy({ entry.environment?[$0] == nil })
            else {
                throw NativeLaunchError.invalidProfile
            }
        }
    }

    let schema_version: Int
    let profiles: [Row]

    private static let published: Result<[Row], Error> = Result {
        let sources = [
            ("small-game-candidates", "6a0b6d77f5b8e1d12f6dbc4c92effd55233a3a41adbfe9578d007a0a89188849"),
            (
                "preflight-game-candidates",
                "e761862f7326e80a9591115730d1e3a56747e633e6442e87138c6f64cc2ab024"
            ),
        ]
        var rows: [Row] = []
        for (name, sha256) in sources {
            let bytes = try Data(contentsOf: LaunchRecipeResources.candidateProfilesURL(name))
            guard bytes.count <= 1_048_576,
                SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256
            else {
                throw NativeLaunchError.invalidProfile
            }
            let catalogue = try JSONDecoder().decode(Self.self, from: bytes)
            guard catalogue.schema_version == 1 else { throw NativeLaunchError.invalidProfile }
            rows += catalogue.profiles
        }
        guard rows.count == 12, Set(rows.map(\.store_id)).count == rows.count,
            rows.allSatisfy({
                PCGamesClient.validProductID($0.store_id)
                    && $0.manifest_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            })
        else { throw NativeLaunchError.invalidProfile }
        return rows
    }

    static func rows() throws -> [Row] { try published.get() }

    static func row(productID: String) throws -> Row? {
        try rows().first { $0.store_id == productID }
    }

    static func issue(productID: String, evidence: MacGameEvidence.Game? = nil) -> String? {
        do {
            guard let row = try row(productID: productID), !row.admitted else { return nil }
            if NativeHallsLaunchRecipe.admits(productID: productID, evidence: evidence) { return nil }
            return row.blocker
                ?? "This title's candidate launch recipe is not approved for a launch attempt."
        } catch {
            return
                "The published candidate launch recipes couldn't be verified. Restore the approved app before playing."
        }
    }
}

enum NativeHallsLaunchRecipe {
    static let productID = "9NMNMS626R59"
    static let engine = "apple-gptk-4.0b3"
    static let executable = "Halls of Torment.exe"
    static let prefix = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support/XodusCLI/prefixes/s2-9NMNMS626R59-apple4-passive-v1")

    static func admits(productID: String, evidence: MacGameEvidence.Game?) -> Bool {
        guard productID == Self.productID, let evidence else { return false }
        return evidence.productId == productID && evidence.verdict == .working
            && evidence.engine == engine && evidence.verifiedWorkingEvidence != nil
            && evidence.runId == "8d7ea6ba-ec75-4cb1-8b96-7300bd467159"
            && evidence.retentionRunId == "5b39beb9-62b4-4241-9330-33422bbccafd"
            && evidence.saveObservation?.retentionVerified == true
            && evidence.saveObservation?.normalMenuQuitObserved == true
    }

    static func validate(
        _ profile: NativeTitleLaunchProfile, entry: NativeEngineRegistry.Entry,
        fallback: String?
    ) throws {
        guard profile.productID == productID, profile.engine == engine, entry.name == engine,
            profile.executable == executable, profile.environment.isEmpty,
            profile.dllOverrides == nil,
            profile.arguments == ["--exe", executable, "--timeout-seconds", "300", "--no-auto-dismiss"],
            Set(profile.unsetEnvironment ?? [])
                == Set([
                    "XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM",
                    "CX_APPLEGPTK_LIBD3DSHARED_PATH",
                ]),
            (profile.unsetEnvironment ?? []).allSatisfy({ entry.environment?[$0] == nil }),
            fallback == nil,
            profile.runtime?.primarySHA256
                == "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8",
            profile.runtime?.legacySHA256
                == "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96"
        else {
            throw NativeLaunchError.invalidProfile
        }
    }
}
