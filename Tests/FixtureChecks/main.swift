// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(description: message) }
}

func decision(_ game: Game, inventory: InventoryState = .complete,
              now: Date = Fixtures.checkedAt,
              fingerprint: RuntimeFingerprint = Fixtures.fingerprint) -> InstallDecision {
    ActionPolicy.evaluate(game, inventory: inventory, now: now, fingerprint: fingerprint)
}

// CLT does not ship XCTest/Testing. This executable makes checks portable without dependencies.
let checks: [(String, () throws -> Void)] = [
    ("Owned verified and experimental fixtures can plan", {
        for game in Fixtures.games.prefix(3) {
            try require(decision(game) == .allowed, "\(game.title) should be eligible")
        }
    }),
    ("Catalog-only and unverified access cannot install", {
        try require(decision(Fixtures.games[4]).reason != nil, "Catalog must not imply access")
        try require(decision(Fixtures.games[5]).reason != nil, "Unknown access must block")
    }),
    ("Purchased unsupported title remains blocked", {
        let game = Fixtures.games[3]
        try require(game.entitlement == .purchase && game.compatibility == .unsupported,
                    "Four facets must stay independent")
        try require(decision(game).reason != nil, "Purchase must not imply installability")
    }),
    ("Partial inventory retains fresh per-product authority", {
        try require(decision(Fixtures.games[2], inventory: .partial) == .allowed,
                    "Partial snapshot must not discard confirmed product evidence")
    }),
    ("Stale offline failed and empty inventory block new installs", {
        for state in [InventoryState.stale, .offline, .failed, .empty] {
            try require(decision(Fixtures.games[2], inventory: state).reason != nil,
                        "\(state) must block")
        }
    }),
    ("Expired subscription is explicit", {
        let result = decision(Fixtures.games[1], now: Fixtures.checkedAt.addingTimeInterval(8 * 86400))
        try require(result.reason == "Subscription access has expired.", "Expiry must not become purchase")
    }),
    ("Old and future-dated access are not trusted", {
        try require(decision(Fixtures.games[0], now: Fixtures.checkedAt.addingTimeInterval(86401)).reason != nil,
                    "Old evidence must block")
        try require(decision(Fixtures.games[0], now: Fixtures.checkedAt.addingTimeInterval(-1)).reason != nil,
                    "Future evidence must block")
    }),
    ("Fingerprint mismatch invalidates verified", {
        let other = RuntimeFingerprint(os: "Other OS", architecture: "arm64", runtime: "other")
        try require(decision(Fixtures.games[0], fingerprint: other).reason != nil, "Pair mismatch must block")
    }),
    ("Architecture mismatch blocks package", {
        let other = RuntimeFingerprint(os: "Fixture macOS", architecture: "x86_64", runtime: "fixture-xodus-pair-1")
        try require(decision(Fixtures.games[2], fingerprint: other).reason ==
                    "This package architecture does not match the current configuration.",
                    "Architecture must not be guessed")
    }),
    ("Disk space is checked at the exact byte threshold", {
        let game = Fixtures.games[2]
        guard let package = game.package else { throw CheckFailure(description: "Fixture package missing") }
        let required = game.expandedBytes + game.downloadBytes + 2 * Fixtures.gigabyte
        try require(InstallPlan(game: game, package: package, availableBytes: required).hasEnoughSpace,
                    "Exact capacity should pass")
        try require(!InstallPlan(game: game, package: package, availableBytes: required - 1).hasEnoughSpace,
                    "One byte less must fail")
    }),
    ("Cancelled jobs cannot resurrect", {
        var job = FixtureJob(gameID: Fixtures.games[2].id)
        job.advance()
        job.cancel()
        job.advance()
        job.retry()
        try require(job.phase == .cancelled, "Terminal cancellation must persist")
    }),
    ("Completed jobs cannot regress", {
        var job = FixtureJob(gameID: Fixtures.games[2].id)
        for _ in 0..<5 { job.advance() }
        try require(job.phase == .completed, "Five explicit phases must complete")
        job.cancel()
        job.fail()
        job.advance()
        try require(job.phase == .completed, "Completed job must stay completed")
    }),
    ("Pause and failure recovery are explicit", {
        var job = FixtureJob(gameID: Fixtures.games[2].id)
        job.advance()
        job.togglePause()
        job.advance()
        try require(job.phase == .paused, "Paused job must not advance")
        job.togglePause()
        try require(job.phase == .downloading, "Resume should return to downloading")
        job.fail()
        try require(job.phase == .failed, "Failure should be visible")
        job.retry()
        try require(job.phase == .queued, "Retry should create no fictional completed bytes")
    }),
    ("All four user-directed provider choices retain separate typed identities", {
        try require(Set(RuntimeProviderKind.allCases.map(\.rawValue)) ==
                    ["gptk3", "gptk4", "crossover", "standaloneWine"],
                    "No provider may be replaced by the external trial default")
        try require(Set(RuntimeProviderKind.allCases.map(\.label)).count == 4,
                    "Every provider needs its own native setting label")
        let bytes = try JSONEncoder().encode(RuntimeProviderKind.allCases)
        try require(try JSONDecoder().decode([RuntimeProviderKind].self, from: bytes) ==
                    RuntimeProviderKind.allCases, "Provider identities must round trip")
    }),
    ("Identity separation and typed JSON round trip", {
        for game in Fixtures.games {
            try require(game.id != game.editionID, "Product and edition are distinct")
            if let package = game.package {
                try require(package.id != game.id && package.id != game.editionID, "Package identity is distinct")
            }
        }
        let data = try JSONEncoder().encode(Fixtures.games)
        let roundTrip = try JSONDecoder().decode([Game].self, from: data)
        try require(roundTrip == Fixtures.games, "Typed evidence must round trip")
    })
]

var failures = 0
for (name, run) in checks {
    do {
        try run()
        print("PASS: \(name)")
    } catch {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
    }
}
print("\(checks.count) core checks, \(failures) failures.")
exit(failures == 0 ? 0 : 1)
