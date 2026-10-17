// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

@MainActor
enum LibraryStatsChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".xodus-stats-checks-\(UUID().uuidString)")
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("games"), journal: root.appendingPathComponent("private/operation.json"))
        for directory in [root, paths.scripts, paths.processed, paths.logs, paths.journal.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Synthetic stats fixtures are cleaned after their owned jobs join") }
        }
        let hash = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        func status(_ hash: String?) -> GameServiceStatus {
            GameServiceStatus(serviceRunning: true, signedIn: hash != nil, accountHash: hash)
        }
        func cache(_ hash: String, date: Date = Date()) -> Data {
            Data("""
                {"accountHash":"\(hash)","checkedAt":"\(ISO8601DateFormatter().string(from: date))","friends":0,"games":{}}
                """.utf8)
        }
        let ledger = GameStatsRefreshLedger(file: paths.statsRefreshLedger)
        let now = Date()
        check(try await ledger.claim(accountHash: hash, now: now), "First stats refresh acquires a durable account-bound slot")
        check(try await !ledger.claim(accountHash: hash, now: now.addingTimeInterval(899)),
              "Stats refresh cannot repeat inside fifteen minutes")
        check(try await GameStatsRefreshLedger(file: paths.statsRefreshLedger)
            .claim(accountHash: hash, now: now.addingTimeInterval(900)),
              "The exact fifteen-minute boundary permits a refresh across controller restart")
        check(try await ledger.claim(accountHash: other, now: now.addingTimeInterval(901)),
              "A new Xbox account receives a new slot without reusing the previous account's throttle")
        try FileManager.default.removeItem(at: paths.statsRefreshLedger)
        let countFile = root.appendingPathComponent("requests")
        let modeFile = root.appendingPathComponent("mode")
        let argumentsFile = root.appendingPathComponent("arguments")
        let output = paths.processed.path
        let script = """
            #!/bin/bash
            umask 077
            if [ "$1" != game-stats ] || [ "$#" != 2 ]; then exit 1; fi
            r="$2"
            printf '%s\\n' "$@" > '\(argumentsFile.path)'
            printf 'requested\\n' >> '\(countFile.path)'
            publish() { cat > "$1.tmp"; mv "$1.tmp" "$1"; }
            mode="$(cat '\(modeFile.path)')"
            trap 'printf "14\\n" | publish "\(output)/$r.status"; exit 14' TERM
            if [ "$mode" = slow ]; then while :; do sleep 0.1; done; fi
            if [ "$mode" = failed ]; then printf '11\\n' | publish "\(output)/$r.status"; exit 11; fi
            if [ "$mode" = wrong ]; then hash='\(other)'; else hash='\(hash)'; fi
            checked="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            printf '{"accountHash":"%s","checkedAt":"%s","friends":0,"games":{}}' "$hash" "$checked" | publish '\(paths.gameStats.path)'
            printf '{"accountHash":"%s","games":0,"friends":0}' "$hash" | publish "\(output)/$r.result.json"
            printf '0\\n' | publish "\(output)/$r.status"
            """
        try GameScriptFiles.writePrivate(Data(script.utf8), to: paths.scripts.appendingPathComponent(GameScriptCommand.gameStats.file))
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
            ofItemAtPath: paths.scripts.appendingPathComponent(GameScriptCommand.gameStats.file).path)
        try GameScriptFiles.writePrivate(Data("success".utf8), to: modeFile)
        let controller = LibraryXboxStats(paths: paths)
        await controller.refresh(for: status(nil))
        check(controller.cache == nil && !FileManager.default.fileExists(atPath: countFile.path),
              "Signed-out stats entry neither trusts the cache nor starts a refresh")
        try GameScriptFiles.writePrivate(cache(other), to: paths.gameStats)
        async let first: Void = controller.refresh(for: status(hash))
        async let duplicate: Void = controller.refresh(for: status(hash))
        _ = await (first, duplicate)
        let calls = try String(contentsOf: countFile, encoding: .utf8).split(separator: "\n").count
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n")
        check(calls == 1 && arguments.count == 2 && arguments.first == "game-stats" &&
              GameScriptPaths.validRunID(String(arguments[1])),
              "Concurrent stats requests coalesce into the exact manage.py game-stats RUN_ID contract")
        check(controller.cache?.accountHash == hash && controller.error == nil,
              "Stats publish only after receipt, current service and cache account bindings agree")
        await controller.refresh(for: status(hash))
        await LibraryXboxStats(paths: paths).refresh(for: status(hash))
        check(try String(contentsOf: countFile, encoding: .utf8).split(separator: "\n").count == 1,
              "A fresh same-account cache is reused on launch and manual refresh across restart")
        await controller.refresh(for: status(nil))
        check(controller.cache == nil, "Confirmed signed-out state hides all prior account stats")
        try FileManager.default.removeItem(at: paths.statsRefreshLedger)
        try GameScriptFiles.writePrivate(cache(other, date: Date().addingTimeInterval(-1800)), to: paths.gameStats)
        try GameScriptFiles.writePrivate(Data("wrong".utf8), to: modeFile)
        let mismatch = LibraryXboxStats(paths: paths)
        await mismatch.refresh(for: status(hash))
        check(mismatch.cache == nil && mismatch.error?.contains("match") == true,
              "A successful command with another account's receipt/cache cannot publish stats")
        try FileManager.default.removeItem(at: paths.statsRefreshLedger)
        try GameScriptFiles.writePrivate(Data("failed".utf8), to: modeFile)
        let failed = LibraryXboxStats(paths: paths)
        await failed.refresh(for: status(hash))
        let failureCount = try String(contentsOf: countFile, encoding: .utf8).split(separator: "\n").count
        await LibraryXboxStats(paths: paths).refresh(for: status(hash))
        let repeatedFailureCount = try String(contentsOf: countFile, encoding: .utf8).split(separator: "\n").count
        check(failed.error?.contains("sign-in") == true && repeatedFailureCount == failureCount,
              "Code11 is explicit and failed refreshes remain throttled after app restart")
        try FileManager.default.removeItem(at: paths.statsRefreshLedger)
        try GameScriptFiles.writePrivate(Data("slow".utf8), to: modeFile)
        try GameScriptFiles.writePrivate(cache(hash, date: Date().addingTimeInterval(-1800)), to: paths.gameStats)
        let slow = LibraryXboxStats(paths: paths)
        let pending = Task { await slow.refresh(for: status(hash)) }
        for _ in 0..<100 where !slow.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        check(slow.cache?.accountHash == hash && slow.refreshing,
              "Confirmed same-account cached stats remain visible while a refresh is in flight")
        await slow.refresh(for: status(nil))
        await pending.value
        check(slow.cache == nil && slow.error == nil && !slow.refreshing,
              "Account retirement joins the owned stats child and refuses its late result")
        await slow.shutdown()
        let before = try String(contentsOf: countFile, encoding: .utf8)
        await slow.refresh(for: status(hash))
        check(try String(contentsOf: countFile, encoding: .utf8) == before,
              "Application termination fences new stats jobs")
        for invalid in ["", String(repeating: "A", count: 64), hash + "0"] {
            check(!XboxAccountBinding.valid(invalid), "Account binding accepts only the fixed64-lowercase-hex contract")
        }
    }
}
