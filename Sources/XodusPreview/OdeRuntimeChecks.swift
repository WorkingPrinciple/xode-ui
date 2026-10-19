// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
enum OdeRuntimeChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ode-rps-check-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Private runtime synthetic files are cleaned") }
        }
        for scenario in ["ready", "bad", "slow"] {
            let valid = scenario != "bad"
            let script = root.appendingPathComponent(scenario + ".py")
            let source = """
                #!/usr/bin/python3
                import os, socket, sys, time
                path = sys.argv[sys.argv.index('--socket') + 1]
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                peer.bind(path)
                os.chmod(path, 0o600)
                peer.listen(1)
                try:
                    time.sleep(\(scenario == "slow" ? "0.2" : "0"))
                    print('\(valid ? #"{"kind":"ready","version":1}"# : #"{"kind":"ready","version":2}"#)', flush=True)
                    sys.stdin.buffer.read()
                finally:
                    peer.close()
                    os.unlink(path)
                """
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let runtime = OdeRuntimeProcess(parentDirectory: root)
            if scenario == "slow" {
                let startup = Task {
                    do {
                        try await runtime.start(BackendConfiguration(executable: script, stateDirectory: root))
                        return false
                    } catch { return (error as? ManagementError) != .shutdownFailed }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while runtime.socket.map({ FileManager.default.fileExists(atPath: $0.path) }) != true,
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let first = Task { await runtime.shutdown() }
                let second = Task { await runtime.shutdown() }
                let firstResult = await first.value
                let secondResult = await second.value
                let joinedStartup = await startup.value
                check(firstResult && secondResult && joinedStartup,
                      "Concurrent shutdown joins one cleanup during startup, without spurious account-removal failure")
                check(await runtime.shutdown(), "Completed runtime shutdown is idempotent")
                continue
            }
            do {
                try await runtime.start(BackendConfiguration(executable: script, stateDirectory: root))
                check(valid && runtime.socket != nil, "Private runtime readiness is accepted only after a real owned socket exists")
                let endpoint = runtime.socket
                check(await runtime.shutdown(), "Private runtime EOF shutdown joins its owned child")
                check(endpoint.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                      "Private runtime normal shutdown removes its own endpoint")
            } catch {
                check(!valid, "Malformed runtime readiness cannot establish an account connection")
                check(await runtime.shutdown(), "Rejected runtime startup is fully joined and retry-safe")
            }
        }
    }
}
