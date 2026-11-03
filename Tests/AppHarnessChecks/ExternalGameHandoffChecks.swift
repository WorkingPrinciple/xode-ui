// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import XCTest

@testable import XodusPreview

final class ExternalGameHandoffChecks: XCTestCase {
    func testHighballInstalledVersionGameLinkContract() throws {
        for link in [
            "highball://play/steam/620",
            "highball://play/epic/AnExistingGame",
            "highball://play/pin/Gaming/12345678-1234-1234-1234-123456789abc",
            "highball://play/pin/My%20Games/12345678-1234-1234-1234-123456789abc",
        ] {
            XCTAssertEqual(try ExternalGameHandoff.highballURL(link).absoluteString, link)
            let handoff = ExternalGameHandoff(provider: .highball, target: link)
            try handoff.validate()
            XCTAssertEqual(
                try JSONDecoder().decode(
                    ExternalGameHandoff.self,
                    from: JSONEncoder().encode(handoff)), handoff)
        }
    }

    func testHighballRefusesNonGameActionsCredentialsAndAmbiguousPaths() {
        for link in [
            "", "/bin/sh", "https://play/steam/620", "highball://open/launcher/steam",
            "highball://play/steam/0", "highball://play/steam/-1",
            "highball://play/steam/99999999999999999999999999",
            "highball://play/steam/620/extra", "highball://play/steam/620/",
            "highball://play/steam//620", "highball://play/steam/%2f620",
            "highball://play/steam/620?t=must-not-import-a-token",
            "highball://play/steam/620?", "highball://play/steam/620#fragment",
            "highball://user:password@play/steam/620", "highball://play:42/steam/620",
            "highball://play/pin/Gaming/not-a-uuid", "highball://play/epic/%00",
            "highball://play/epic/%0a", "highball://play/epic/%2e%2e",
            "highball://play/epic/a%5cb", "highball://play/epic/a%2fb",
            "highball://play/gog/123", "highball://play/battlenet/wow",
        ] {
            XCTAssertThrowsError(try ExternalGameHandoff.highballURL(link), link)
        }
        XCTAssertThrowsError(
            try ExternalGameHandoff.highballURL(
                "highball://play/epic/" + String(repeating: "x", count: 2_049)))
    }

    func testWrapperSelectionIsNotAnArbitraryExecutableOrManager() throws {
        for path in [
            "relative.app", "/bin/sh", "/Applications/Porting Kit.app\n", "/Applications/Game.exe",
        ] {
            XCTAssertThrowsError(
                try ExternalGameHandoff(provider: .portingKit, target: path).validate())
        }
        for path in [
            "/Applications/Porting Kit.app", "/Applications/Highball.app",
            "/Applications/No-Such-Ode-Game-Wrapper.app",
        ] {
            XCTAssertThrowsError(
                try ExternalGameHandoff.portingKitWrapper(URL(fileURLWithPath: path)))
        }
    }

    func testHeroicRequiresExactStoreAndGameWithoutLaunchOptions() throws {
        for runner in ["legendary", "gog", "nile", "sideload"] {
            let expected = "heroic://launch/\(runner)/123-ABC_xyz"
            XCTAssertEqual(try ExternalGameHandoff.heroicURL(expected).absoluteString, expected)
            XCTAssertEqual(
                try ExternalGameHandoff.heroicURL(
                    "heroic://launch?appName=123-ABC_xyz&runner=\(runner)"
                ).absoluteString, expected)
            let handoff = ExternalGameHandoff(provider: .heroic, target: expected)
            try handoff.validate()
            XCTAssertEqual(
                try JSONDecoder().decode(
                    ExternalGameHandoff.self,
                    from: JSONEncoder().encode(handoff)), handoff)
        }
        for link in [
            "heroic://launch/Game", "heroic://launch/steam/123", "heroic://launch/gog/123/extra",
            "heroic://launch/gog/123?arg=--help", "heroic://launch?appName=123",
            "heroic://launch?appName=123&runner=gog&runner=legendary",
            "heroic://launch?appName=123&runner=gog&arg=extra",
            "heroic://launch?appName=123&runner=gog&altExe=/bin/sh",
            "heroic://launch?appName=123&runner=gog&gui=false",
            "heroic://launch?appName=%00&runner=gog",
            "heroic://launch?appName=..&runner=sideload",
            "heroic://launch/sideload/%2fbin%2fsh", "heroic://launch/gog/123/",
            "heroic://user:password@launch/gog/123", "heroic://launch:123/gog/123",
            "heroic://launch/gog/123#fragment", "heroic://launch/gog/123?",
            "https://launch/gog/123", "heroic://ping",
        ] {
            XCTAssertThrowsError(try ExternalGameHandoff.heroicURL(link), link)
        }
    }
    func testCredentialsAreRejectedForBothLinkProviders() throws {
        for (provider, text) in [
            (ExternalGameProvider.highball, "highball://play/steam/620"),
            (.heroic, "heroic://launch/gog/123"),
        ] {
            var components = try XCTUnwrap(URLComponents(string: text))
            components.user = "example"
            components.password = "not-a-real-credential"
            let handoff = ExternalGameHandoff(
                provider: provider, target: try XCTUnwrap(components.string))
            XCTAssertThrowsError(try handoff.validate())
        }
    }

    func testRegistryPersistsAssociationsWithoutChangingNativeGameHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ode-handoff-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installed-games.json")
        let store = InstalledGameStore(file: file)
        let playedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let game = InstalledGame(
            id: UUID(), title: "Registry check", identityName: "Example.Game",
            version: "1.0", storeId: "example-store-id", folder: "/Unavailable/ExampleGame",
            launcher: "", importedAt: playedAt, lastPlayedAt: playedAt,
            lastSessionSeconds: 42, usesNativeLifecycle: true)
        try await store.save([game])
        let legacy =
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        XCTAssertNil(try XCTUnwrap(legacy?.first)["externalHandoffs"])
        let decoded = try await store.load()
        XCTAssertEqual(decoded, [game])

        for handoff in [
            ExternalGameHandoff(provider: .highball, target: "highball://play/steam/620"),
            .init(provider: .heroic, target: "heroic://launch/gog/123"),
            .init(provider: .portingKit, target: "/Unavailable/ExampleGame.app"),
        ] {
            _ = try await store.setExternalHandoff(
                id: game.id, provider: handoff.provider, target: handoff.target)
        }
        let saved = try await store.load()
        var linked = try XCTUnwrap(saved.first)
        XCTAssertEqual(linked.externalHandoffs?.count, 3)
        linked.externalHandoffs = nil
        XCTAssertEqual(linked, game)
        let upserted = try await store.upsert(game)
        XCTAssertEqual(upserted.first?.externalHandoffs, saved.first?.externalHandoffs)
        for provider in ExternalGameProvider.allCases {
            _ = try await store.setExternalHandoff(id: game.id, provider: provider, target: nil)
        }
        let removed = try await store.load()
        XCTAssertEqual(removed, [game])

        var invalid = game
        let duplicate = ExternalGameHandoff(provider: .heroic, target: "heroic://launch/gog/123")
        invalid.externalHandoffs = [duplicate, duplicate]
        do {
            try await store.save([invalid])
            XCTFail("Duplicate provider associations must not be persisted")
        } catch InstalledGameError.invalidRegistry {}
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, [game])
    }

    @MainActor
    func testExpiredAuthorizationRefusesRealProviderHandoff() async throws {
        guard case .detected = ExternalApplicationDetector.detect(.heroic) else {
            throw XCTSkip("No signed Heroic installation available for the freshness-refusal check")
        }
        let handoff = ExternalGameHandoff(provider: .heroic, target: "heroic://launch/gog/123")
        do {
            try await handoff.open { false }
            XCTFail("An expired authorization must not reach Launch Services")
        } catch is CancellationError {}
    }

    func testPinnedPublisherRequirementsParseAndRealAppObservation() throws {
        for provider in ExternalGameProvider.allCases {
            var requirement: SecRequirement?
            XCTAssertEqual(
                SecRequirementCreateWithString(
                    provider.signingRequirement as CFString,
                    [], &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
            let state = ExternalApplicationDetector.detect(provider)
            // This reads the real host, without constructing or launching an app.
            print("\(provider.label): \(state.label)")
            switch state {
            case .detected(let app):
                XCTAssertFalse(app.version.isEmpty)
                XCTAssertEqual(
                    ExternalApplicationDetector.inspect(app.location, provider: provider), state)
                let other: ExternalGameProvider = provider == .highball ? .portingKit : .highball
                XCTAssertEqual(
                    ExternalApplicationDetector.inspect(app.location, provider: other), .unverified)
            case .missing, .unverified: break
            case .notChecked, .checking: XCTFail("Synchronous observation must settle")
            }
        }
    }

    @MainActor
    func testExternalHandoffsDoNotChangeNativeProviderChoices() {
        XCTAssertEqual(RuntimeProviderSettings.providerChoices.map(\.rawValue), ["calimocho"])
        XCTAssertEqual(
            ExternalGameProvider.allCases.map(\.rawValue), ["highball", "portingKit", "heroic"])
    }
}
