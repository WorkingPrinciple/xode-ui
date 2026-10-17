// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum Fixtures {
    public static let gigabyte: Int64 = 1_000_000_000
    public static let checkedAt = Date(timeIntervalSince1970: 1_791_014_400)
    public static let fingerprint = RuntimeFingerprint(
        os: "Fixture macOS", architecture: "arm64", runtime: "fixture-xodus-pair-1"
    )
    public static let games: [Game] = [
        make("harbor", title: "Lumen Harbor", subtitle: "A quiet adventure beyond the tide.",
             summary: "Follow a chain of lanterns across an imagined archipelago. Restore its beacons, chart unfamiliar shores, and find your way home.",
             art: "harbor", entitlement: .purchase, compatibility: .verified, size: 8,
             installed: true),
        make("orbit", title: "Orbit Almanac", subtitle: "Find a new rhythm among the stars.",
             summary: "A fictional exploration game about tiny observatories, distant moons and the maps we leave behind.",
             art: "orbit", entitlement: .subscription, compatibility: .experimental, size: 14),
        make("ridge", title: "Paper Ridge", subtitle: "One trail. A thousand folded horizons.",
             summary: "Travel through a landscape assembled from paper. Unfold paths and follow the weather through a world that changes with every turn.",
             art: "ridge", entitlement: .purchase, compatibility: .verified, size: 4),
        make("signal", title: "The Last Signal", subtitle: "Some messages take the long way home.",
             summary: "Explore an invented desert relay network. This fixture demonstrates a purchased title with an unavailable package and unsupported configuration.",
             art: "signal", entitlement: .purchase, compatibility: .unsupported, size: 18,
             installability: .blocked),
        make("moss", title: "Moss & Meridian", subtitle: "Small wonders, patiently discovered.",
             summary: "An imaginary woodland puzzle collection. Its catalog listing demonstrates that discovery does not establish account access.",
             art: "moss", entitlement: .none, compatibility: .unknown, size: 3),
        make("tide", title: "Tidal Atlas", subtitle: "A map is only the beginning.",
             summary: "A fictional seafaring journey used to demonstrate unverified access. No entitlement or gameplay claim is made.",
             art: "tide", entitlement: .unknown, compatibility: .experimental, size: 10)
    ]

    private static func make(_ id: String, title: String, subtitle: String, summary: String,
                             art: String, entitlement: Entitlement,
                             compatibility: Compatibility, size: Int64,
                             installed: Bool = false,
                             installability: Installability = .downloadable) -> Game {
        Game(
            id: "fixture-\(id)", editionID: "fixture-\(id)-standard", title: title,
            subtitle: subtitle, summary: summary, art: art, entitlement: entitlement,
            accessEvidence: Evidence(
                source: "Invented fixture; not an account", checkedAt: checkedAt,
                expiresAt: entitlement == .subscription ? checkedAt.addingTimeInterval(7 * 86400) : nil
            ),
            installability: installability,
            package: installability == .downloadable
                ? PackageIdentity(id: "fixture-\(id)-pc", version: "1.0-demo",
                                  language: "English (fixture)", architecture: "arm64") : nil,
            downloadReason: "No eligible PC package in this fixture.",
            compatibility: compatibility,
            compatibilityEvidence: Evidence(
                source: "Invented demonstration, not a runtime test", checkedAt: checkedAt,
                fingerprint: fingerprint
            ),
            downloadBytes: size * gigabyte, expandedBytes: size * 2 * gigabyte,
            initiallyInstalled: installed
        )
    }
}
