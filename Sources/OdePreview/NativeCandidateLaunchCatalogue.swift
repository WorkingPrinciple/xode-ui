// SPDX-License-Identifier: GPL-3.0-only
import OdeLegacyCompatibility
import CryptoKit
import Foundation
import OdeManagement

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
                    LegacyCompatibility.RuntimePinPending.runtimeComSTA, LegacyCompatibility.RuntimePinPending.callerOwnsCOM,
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
                    LegacyCompatibility.RuntimePinPending.runtimeComSTA, LegacyCompatibility.RuntimePinPending.callerOwnsCOM,
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
        let bytes = try Data(contentsOf: LaunchRecipeResources.candidateLaunchCatalogueURL())
        guard bytes.count <= 1_048_576,
            SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                == "df8e3892eec9355ed78b0a90b9b2f50296cfc4f6670872c160b1fb95e88a8351"
        else { throw NativeLaunchError.invalidProfile }
        let catalogue = try JSONDecoder().decode(Self.self, from: bytes)
        guard catalogue.schema_version == 1 else { throw NativeLaunchError.invalidProfile }
        let rows = catalogue.profiles
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
            if productID == "9NMNMS626R59" {
                guard let profile = try NativeTitleLaunchProfile.bundledProfiles()
                        .first(where: { $0.productID == productID && $0.provider == nil }),
                      let engine = profile.engine, let pin = CalimochoReleasePin.named(engine),
                      profile.wineSha256 == pin.wineSha256,
                      profile.wineserverSha256 == pin.wineserverSha256 else {
                    return "Halls of Torment's launch profile doesn't match a pinned Calimocho release."
                }
                return nil
            }
            if productID == "9MT5NJ5W7B8Z" {
                return NativeWorkingLaunchRecipe.admitted(productID: productID, evidence: evidence) != nil
                    ? nil : "The exact qualified Hogwarts recipe requires its matching Working, save and normal-quit evidence."
            }
            guard let row = try row(productID: productID), !row.admitted else { return nil }
            if NativeWorkingLaunchRecipe.admitted(productID: productID, evidence: evidence) != nil { return nil }
            return row.blocker
                ?? "This title's candidate launch recipe is not approved for a launch attempt."
        } catch {
            return
                "The published candidate launch recipes couldn't be verified. Restore the approved app before playing."
        }
    }
}

struct NativeWorkingLaunchRecipe {
    let productID: String
    let executable: String
    let prefixName: String
    let initialRun: String
    let retentionRun: String
    let quitRun: String?
    let timeout: UInt
    let environment: [String: String]
    static let engine = "apple-gptk-4.0b3"
    private static let recipes = [
        Self(productID: "9NMNMS626R59", executable: "Halls of Torment.exe",
             prefixName: "s2-9NMNMS626R59-apple4-passive-v1",
             initialRun: "8d7ea6ba-ec75-4cb1-8b96-7300bd467159",
             retentionRun: "5b39beb9-62b4-4241-9330-33422bbccafd", quitRun: nil,
             timeout: 300, environment: [:]),
        Self(productID: "9MT5NJ5W7B8Z", executable: "Phoenix/Binaries/WinGDK/HogwartsLegacy.exe",
             prefixName: "s3-hogwarts-apple4-v1",
             initialRun: "891d061f-4820-4cd3-9b61-efefa5700be9",
             retentionRun: "86e8da68-f4b0-48f8-bf7a-46e577ff3488",
             quitRun: "f2471368-2523-4578-8eb8-75c8d4db7040",
             timeout: 600, environment: [LegacyCompatibility.RuntimePinPending.runtimeComSTA: "1"])
    ]

    var prefix: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Ode to X/CLI/prefixes/\(prefixName)")
    }

    static func admitted(productID: String, evidence: MacGameEvidence.Game?) -> Self? {
        guard let recipe = recipes.first(where: { $0.productID == productID }),
              let evidence, evidence.productId == productID, evidence.verdict == .working,
              evidence.engine == engine, evidence.hasVerifiedWorkingQualification,
              evidence.verifiedWorkingEvidence != nil,
              evidence.runId == recipe.initialRun, evidence.retentionRunId == recipe.retentionRun,
              recipe.quitRun.map({ evidence.normalQuitRunId == $0 }) ?? true,
              evidence.saveObservation?.retentionVerified == true,
              evidence.saveObservation?.normalMenuQuitObserved == true else { return nil }
        return recipe
    }

    func validate(
        _ profile: NativeTitleLaunchProfile, entry: NativeEngineRegistry.Entry,
        fallback: String?
    ) throws {
        let unset = [LegacyCompatibility.RuntimePinPending.callerOwnsCOM, "CX_APPLEGPTK_LIBD3DSHARED_PATH"]
            + (environment.isEmpty ? [LegacyCompatibility.RuntimePinPending.runtimeComSTA] : [])
        guard profile.productID == productID, profile.engine == Self.engine, entry.name == Self.engine,
            profile.executable == executable, profile.environment == environment,
            profile.dllOverrides == nil,
            profile.arguments == ["--exe", executable, "--timeout-seconds", String(timeout), "--no-auto-dismiss"],
            Set(profile.unsetEnvironment ?? []) == Set(unset),
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
