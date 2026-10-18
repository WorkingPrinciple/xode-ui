// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import XodusProcessIdentity

@MainActor
enum LaunchAssociationChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("association-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Foreground fixtures clean only their owned source-check root") }
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        var seconds: UInt64 = 0, micros: UInt64 = 0
        guard xodus_process_start(child.processIdentifier, &seconds, &micros) == 1 else {
            throw AssociationError.unavailable
        }
        let identity = LaunchProcessIdentity(pid: child.processIdentifier, start_sec: seconds, start_usec: micros)
        check(identity.matchesKernel(), "Foreground typed kernel shim accepts the actual owned fixture process instance")
        check(!LaunchProcessIdentity(pid: identity.pid, start_sec: seconds + 1, start_usec: micros).matchesKernel()
              && !LaunchProcessIdentity(pid: -1, start_sec: seconds, start_usec: micros).matchesKernel()
              && !LaunchProcessIdentity(pid: identity.pid, start_sec: seconds, start_usec: 1_000_000).matchesKernel(),
              "Foreground typed kernel shim rejects stale/invalid PID and invalid microseconds")
        let adapter = root.appendingPathComponent("adapter.py")
        let assets = LaunchAssociationAssets(adapter: adapter, library: root.appendingPathComponent("peer.dylib"))
        let valid = #"{"pid":\#(identity.pid),"start_sec":\#(seconds),"start_usec":\#(micros)}"#
        var active = true
        var current = true
        var usable = true
        var requests = 0
        var diagnostics = 0
        func write(_ body: String) throws { try Data(body.utf8).write(to: adapter) }
        func handoff() throws -> LaunchAssociationHandoff {
            try LaunchAssociationHandoff(assets: assets, runID: InstalledGamesController.runID(),
                root: root.appendingPathComponent(UUID().uuidString), donorActive: { active },
                ready: { _ in usable }, activate: { _ in requests += 1; return true })
        }
        try write("""
            import json, os, sys
            assert '--run-nonce' not in sys.argv
            assert len(os.environ['XODUS_LAUNCH_RUN_NONCE']) == 64
            assert '--run-nonce-env' in sys.argv
            assert sys.argv[sys.argv.index('--trusted-broker-path') + 1] == '\(LaunchAssociationAssets.broker)'
            assert os.environ['XODUS_LAUNCH_EXPECTED_BROKER_SHA256'] == '\(LaunchAssociationAssets.brokerSHA256)'
            print('\(valid)')
            """)
        let first = try handoff()
        check(first.environment["XODUS_LAUNCH_RUN_NONCE"]?.count == 64
              && first.environment["XODUS_LAUNCH_RUN_ID"] != nil
              && first.environment["XODUS_LAUNCH_PEER_LIBRARY"] == assets.library.path,
              "Foreground per-launch options bind fresh private nonce, exact run and pinned helper library")
        first.start(current: { current }, diagnostic: { diagnostics += 1 }, duration: .seconds(2))
        for _ in 0..<40 {
            if requests > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        check(requests == 1 && diagnostics == 0,
              "Foreground actual consumer command/env and kernel recheck reach one injected cooperative request")
        first.start(current: { current }, diagnostic: { diagnostics += 1 })
        try await Task.sleep(for: .milliseconds(100))
        check(requests == 1, "Foreground handoff makes at most one request per launch")
        let noGUI = try LaunchAssociationHandoff(assets: assets, runID: InstalledGamesController.runID(),
            root: root.appendingPathComponent(UUID().uuidString), donorActive: { true },
            activate: { _ in requests += 1; return true })
        check(noGUI.environment["XODUS_LAUNCH_RUN_NONCE"] != first.environment["XODUS_LAUNCH_RUN_NONCE"],
              "Foreground separate launches never reuse a private nonce")
        noGUI.start(current: { true }, diagnostic: { diagnostics += 1 }, duration: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(450))
        check(await noGUI.cancelAndWait() && requests == 1,
              "Foreground real AppKit/window readiness rejects attested owned sleep process without a usable GUI")
        for mode in ["inactive", "stale-run", "cancelled", "no-window", "wrong-instance", "extra-identity",
                     "duplicate-identity", "oversize", "failed"] {
            active = true; current = true; usable = true
            let candidate = try handoff()
            let previous = requests
            switch mode {
            case "inactive": active = false
            case "stale-run": current = false
            case "cancelled": candidate.cancel()
            case "no-window": usable = false
            case "wrong-instance":
                try write("print('{\"pid\":\(identity.pid),\"start_sec\":0,\"start_usec\":0}')")
            case "extra-identity":
                try write("print('\(valid.dropLast()),\"other_pid\":2}')")
            case "duplicate-identity":
                try write("print('\(valid.dropLast()),\"pid\":\(identity.pid)}')")
            case "oversize": try write("print('x' * 2048)")
            case "failed": try write("raise SystemExit(1)")
            default: break
            }
            candidate.start(current: { current }, diagnostic: { diagnostics += 1 }, duration: .milliseconds(180))
            try await Task.sleep(for: .milliseconds(400))
            check(await candidate.cancelAndWait(), "Foreground \(mode) retires its owned consumer command")
            check(requests == previous, "Foreground actual consumer lifecycle rejects \(mode) without activation")
            try write("print('\(valid)')")
        }
        active = true; current = true; usable = true
        try write("import time\ntime.sleep(0.3)\nprint('\(valid)')")
        let loss = try handoff()
        let previous = requests
        loss.start(current: { current }, diagnostic: { diagnostics += 1 })
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(450))
        check(requests == previous, "Foreground active-donor loss permanently cancels pending consumer, even if donor becomes active again")
        check(await loss.cancelAndWait(), "Foreground deactivation joins its exact pending command")
        for mode in ["replacement", "stop", "termination"] {
            active = true; current = true
            let pending = try handoff()
            pending.start(current: { current }, diagnostic: { diagnostics += 1 })
            try await Task.sleep(for: .milliseconds(60))
            current = false
            check(await pending.cancelAndWait() && requests == previous,
                  "Foreground \(mode) during actual command consumption joins it and fences late callbacks")
        }
        active = false
        do { _ = try handoff(); check(false, "Foreground inactive donor cannot arm a launch handoff") }
        catch { check(true, "Foreground inactive donor cannot arm a launch handoff") }
        let absent = root.appendingPathComponent("Absent.app")
        try FileManager.default.createDirectory(at: absent, withIntermediateDirectories: true)
        if let bundle = Bundle(url: absent) {
            check(try LaunchAssociationAssets.bundled(bundle) == nil,
                  "Foreground absent optional capsule leaves ordinary Play unchanged")
            let capsule = absent.appendingPathComponent("Contents/Resources/LaunchAssociation")
            try FileManager.default.createDirectory(at: capsule, withIntermediateDirectories: true)
            do { _ = try LaunchAssociationAssets.bundled(bundle)
                check(false, "Foreground unsigned/mismatched capsule is rejected before helper execution")
            } catch { check(true, "Foreground unsigned/mismatched capsule is rejected before helper execution") }
        } else { check(false, "Foreground synthetic bundle is available for admission checks") }
    }
}
