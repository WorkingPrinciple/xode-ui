// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin
@testable import XodusManagement

@main
enum ManagementChecks {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "runtime-plan" { MockRuntimePlan.run() }
        if CommandLine.arguments.dropFirst().first == "manage" { MockBackend.run() }
        let checks = Checks()
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--probe-backend"),
               CommandLine.arguments.indices.contains(index + 1),
               let stateIndex = CommandLine.arguments.firstIndex(of: "--state-dir"),
               CommandLine.arguments.indices.contains(stateIndex + 1) {
                try await checks.probe(BackendConfiguration(
                    executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                    stateDirectory: URL(fileURLWithPath: CommandLine.arguments[stateIndex + 1])),
                    discover: CommandLine.arguments.contains("--probe-discovery"),
                    query: CommandLine.arguments.contains("--probe-query"),
                    inspect: CommandLine.arguments.contains("--probe-inspect"))
            } else if CommandLine.arguments.contains("--descriptor-metrics-checks") {
                try await checks.descriptorMetricsChecks()
            } else if CommandLine.arguments.contains("--overflow-checks") {
                try await checks.overflowChecks()
            } else if let index = CommandLine.arguments.firstIndex(of: "--contract-schema-checks") {
                guard CommandLine.arguments.indices.contains(index + 1) else {
                    throw ManagementError.invalidPayload
                }
                try await checks.contractSchemaChecks(canonicalURL:
                    URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } else if CommandLine.arguments.contains("--install-plan-development-checks") {
                try await checks.registryDevelopmentChecks()
                try await checks.installPlanDevelopmentChecks()
            } else if CommandLine.arguments.contains("--registry-development-checks") {
                try await checks.registryDevelopmentChecks()
            } else { try await checks.run() }
        } catch { await checks.check(false, "Check harness: \(safeMessage(error))") }
        exit(await checks.finish() ? 0 : 1)
    }
}

func fixture(_ name: String) throws -> JSONValue {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw ManagementError.invalidPayload
    }
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

func safeMessage(_ error: Error) -> String {
    (error as? ManagementError)?.localizedDescription ?? "The fixture check could not complete."
}

actor Checks {
    var count = 0
    var failures = 0

    func check(_ condition: Bool, _ name: String) {
        count += 1
        if condition {
            if !name.hasPrefix("Producer positive frame") { print("PASS: \(name)") }
        }
        else {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
        }
    }

    func finish() -> Bool {
        print("\(count) management checks, \(failures) failures.")
        return failures == 0
    }

    func overflowChecks() async throws {
        let diagnostics = try ManagementClient()
        for _ in 0..<256 {
            try await diagnostics.consumeDiagnostics(Data(repeating: 10, count: 4096))
        }
        check(await diagnostics.lastOverflow == nil,
              "Cumulative diagnostics admit exactly the unchanged 1MiB lifetime boundary")
        do {
            try await diagnostics.consumeDiagnostics(Data([10]))
            check(false, "Cumulative stderr overflow is distinguished")
        } catch {
            let failure = await diagnostics.lastOverflow
            check(error as? ManagementError == .outputOverflow
                  && failure?.origin == .diagnosticLifetime
                  && failure?.count == JSONLineFramer.maximumBytes + 1,
                  "Cumulative stderr overflow is distinguished without logging payload")
        }
        do {
            try await diagnostics.consumeDiagnostics(Data([10, 10]))
            check(false, "First overflow origin/count is retained once")
        } catch {
            check(await diagnostics.lastOverflow?.count == JSONLineFramer.maximumBytes + 1,
                  "First overflow origin/count is retained once")
        }
        check(await diagnostics.close(), "Isolated diagnostic client closes")
        let stderrClient = try ManagementClient()
        _ = try await stderrClient.connect(mockConfiguration("diagnosticlifetime"))
        do {
            _ = try await stderrClient.request(.jobs)
            check(false, "Actual fixture stderr lifetime overflow retires the owned transport")
        } catch {
            let failure = await stderrClient.lastOverflow
            check(error as? ManagementError == .outputOverflow && failure?.origin == .diagnosticLifetime,
                  "Actual fixture stderr lifetime overflow retires the owned transport")
        }
        check(await stderrClient.close(), "Owned cumulative-stderr fixture joins")

        guard let eventValue = try fixture("positive").array?.first(where: { $0["kind"]?.string == "event" }) else {
            throw ManagementError.invalidPayload
        }
        let event = try eventValue.decode(ManagementEvent.self)
        let events = try ManagementClient()
        for _ in 0..<128 { try await events.enqueueEvent(event) }
        do {
            try await events.enqueueEvent(event)
            check(false, "Unread events retain their unchanged bounded queue")
        } catch {
            let failure = await events.lastOverflow
            check(error as? ManagementError == .outputOverflow
                  && failure?.origin == .eventQueue,
                  "Unread events retain their unchanged bounded queue")
        }
        check(await events.close(), "Isolated event client closes")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagementOverflowChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Owned overflow fixtures cleaned") }
        }
        let burstFile = root.appendingPathComponent("delayed-consumer-stdout")
        guard let value = try fixture("positive").array?.first else { throw ManagementError.invalidFrame }
        var frame = try JSONEncoder().encode(value)
        frame.append(10)
        var burst = Data()
        var expectedFrames = 0
        while burst.count < 3 * JSONLineFramer.maximumBytes {
            burst.append(frame)
            expectedFrames += 1
        }
        try burst.write(to: burstFile)
        let burstHandle = try FileHandle(forReadingFrom: burstFile)
        let burstStream = ManagementClient.chunks(burstHandle, origin: .stdoutQueue)
        var receivedBytes = 0
        var receivedHash = SHA256()
        var receivedFrames = 0
        var framer = JSONLineFramer()
        let validator = try ContractValidator()
        do {
            for try await bytes in burstStream {
                try await Task.sleep(for: .milliseconds(1))
                receivedBytes += bytes.count
                receivedHash.update(data: bytes)
                for line in try framer.append(bytes) {
                    try validator.validate(JSONDecoder().decode(JSONValue.self, from: line))
                    receivedFrames += 1
                }
            }
            try framer.finish()
            check(receivedBytes == burst.count && receivedFrames == expectedFrames
                  && receivedHash.finalize() == SHA256.hash(data: burst),
                  "REQ94: A delayed stdout consumer receives every byte beyond 128 chunks without overflow or loss")
        } catch {
            check(false, "REQ94: A delayed stdout consumer receives every byte beyond 128 chunks without overflow or loss")
        }
        try await pressuredPipeChecks(file: burstFile, expected: burst, expectedFrames: expectedFrames)
        for origin in [ManagementClient.OverflowOrigin.stdoutQueue, .stderrQueue] {
            let file = root.appendingPathComponent(origin.rawValue)
            try Data(repeating: 32, count: 2 * JSONLineFramer.maximumBytes).write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            let stream = ManagementClient.chunks(handle, origin: origin)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while stream.bufferedChunkCount < 128, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            check(stream.bufferedChunkCount == 128
                  && (try? handle.offset()) == UInt64(128 * 8192),
                  "REQ94: Unread \(origin.rawValue) pauses its reader at the unchanged 128-chunk limit")
            stream.cancel()
            while (try? handle.offset()) != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            check((try? handle.offset()) == nil,
                  "REQ94: Cancelling a full \(origin.rawValue) queue wakes and closes its owned reader")
        }

        try await requestPressureChecks()
    }

    private func pressuredPipeChecks(file: URL, expected: Data, expectedFrames: Int) async throws {
        for cancelling in [false, true] {
            let pipe = Pipe()
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let stream = ManagementClient.chunks(pipe.fileHandleForReading, origin: .stdoutQueue)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.arguments = [file.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = pipe
            child.standardError = FileHandle.nullDevice
            try child.run()
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                stream.cancel()
                if child.isRunning { child.terminate() }
            }
            defer {
                watchdog.cancel()
                stream.cancel()
                if child.isRunning { child.terminate() }
            }
            let fullDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while stream.bufferedChunkCount < 128, child.isRunning, ContinuousClock.now < fullDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try await Task.sleep(for: .milliseconds(25))
            check(stream.bufferedChunkCount == 128 && child.isRunning,
                  "REQ94 pipe \(cancelling ? "cancel" : "drain"): A live writer is backpressured at exactly 128 unread chunks")
            if cancelling {
                stream.cancel()
            } else {
                var count = 0, frames = 0, chunks = 0
                var shortRead = false
                var hash = SHA256()
                var framer = JSONLineFramer()
                let validator = try ContractValidator()
                do {
                    for try await bytes in stream {
                        try await Task.sleep(for: .milliseconds(1))
                        count += bytes.count
                        chunks += 1
                        shortRead = shortRead || bytes.count < 8192
                        hash.update(data: bytes)
                        for line in try framer.append(bytes) {
                            try validator.validate(JSONDecoder().decode(JSONValue.self, from: line))
                            frames += 1
                        }
                    }
                    try framer.finish()
                    check(count == expected.count && chunks > 128 && shortRead && frames == expectedFrames
                          && hash.finalize() == SHA256.hash(data: expected),
                          "REQ94 pipe drain: Short reads preserve every byte/hash and validated frame beyond 128 chunks through EOF")
                } catch {
                    check(false, "REQ94 pipe drain: Short reads preserve every byte/hash and validated frame beyond 128 chunks through EOF")
                    stream.cancel()
                }
            }
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while child.isRunning, ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            check(!child.isRunning && (cancelling ? child.terminationStatus != 0 : child.terminationStatus == 0),
                  "REQ94 pipe \(cancelling ? "cancel" : "drain"): The owned writer exits within the bound without hanging or replay")
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while fcntl(descriptor, F_GETFD) != -1, ContinuousClock.now < closeDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            check(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF,
                  "REQ94 pipe \(cancelling ? "cancel" : "drain"): The owned pipe reader closes after full-queue cancellation or orderly EOF")
        }
    }

    func descriptorMetricsChecks() async throws {
            let prefix = "Ode descriptor metrics v1 "
            let enabled = prefix + "enabled seq=1 budget=65536\n"
            let valid = enabled + prefix + "checkpoint seq=2\n"
                + prefix + "lookup seq=3 hit=0 forced=1 coalesced=1\n"
                + prefix + "attempt seq=4 fetch=1\n"
                + prefix + "terminal seq=5 fetch=1 ok=1\n"
                + prefix + "lookup seq=6 hit=1 forced=0 coalesced=0\n"
                + prefix + "checkpoint seq=7\n"
            let bytes = Data(valid.utf8)
            for split in 0...bytes.count {
                var framer = ManagementClient.DescriptorMetricsFramer()
                let first = framer.append(bytes.prefix(split))
                let second = framer.append(bytes.dropFirst(split))
                check(first.count + second.count == 7 && framer.status == .provisional
                      && framer.checkpoint == 7 && framer.lookups == 2 && framer.hits == 1
                      && framer.attempts == 1 && framer.terminals == 1 && framer.successes == 1
                      && framer.active.isEmpty,
                      "Count-only metrics preserve arbitrary cross-pipe chunk split \(split)")
            }
            for invalid in [
                prefix + "lookup seq=1 hit=1 forced=0 coalesced=0\n",
                enabled + prefix + "checkpoint seq=3\n",
                enabled + prefix + "checkpoint seq=02\n",
                enabled + prefix + "terminal seq=2 fetch=1 ok=1\n",
                enabled + prefix + "attempt seq=2 fetch=2\n",
                enabled + prefix + "lookup seq=2 hit=1 forced=1 coalesced=0\n",
                enabled + prefix + "lookup seq=2 hit=1 forced=0 coalesced=1\n",
                enabled + prefix + "attempt seq=2 fetch=1\n" + prefix + "checkpoint seq=3\n",
                enabled + prefix + "enabled seq=2 budget=65536\n",
                enabled + prefix + "checkpoint seq=2 extra=private\n",
                enabled + prefix + "checkpoint seq=18446744073709551616\n",
                enabled + "Ode descriptor metrics v2 checkpoint seq=2\n",
                enabled + prefix + "checkpoint seq=2\r\n",
                enabled + prefix + String(repeating: "x", count: 256) + "\n",
                enabled + prefix + "attempt seq=2 fetch=1\n"
                    + prefix + "terminal seq=3 fetch=1 ok=0\n"
                    + prefix + "terminal seq=4 fetch=1 ok=0\n"
            ] {
                var framer = ManagementClient.DescriptorMetricsFramer()
                _ = framer.append(Data(invalid.utf8))
                check(framer.status == .invalid, "Malformed/uncorrelated metrics invalidate proof without retaining payload")
            }
            var absent = ManagementClient.DescriptorMetricsFramer()
            check(absent.append(Data("untrusted arbitrary stderr\n".utf8)).isEmpty && absent.status == .unavailable,
                  "Missing enabled marker is unavailable, never zero")
            _ = absent.append(Data(enabled.utf8))
            _ = absent.append(Data((prefix + "attempt seq=2 fetch=1\n").utf8))
            absent.finish()
            check(absent.status == .invalid, "Unfinished upstream fetch cannot complete count proof")
            var exhausted = ManagementClient.DescriptorMetricsFramer()
            _ = exhausted.append(Data((enabled + prefix + "exhausted seq=2\n").utf8))
            check(exhausted.status == .exhausted, "Explicit exhausted marker invalidates measurement completeness")
            var bounded = ManagementClient.DescriptorMetricsFramer()
            _ = bounded.append(Data(enabled.utf8))
            for sequence in 2...3000 {
                _ = bounded.append(Data((prefix + "lookup seq=\(sequence) hit=1 forced=0 coalesced=0\n").utf8))
            }
            check(bounded.status == .invalid, "Metrics enforce the independent 64KiB lifetime budget")
            for value in [nil, "", "0", "true", "01", "1 ", "1"] as [String?] {
                var environment = ["HOME": "/neutral", "SECRET": "never-forward", "RUST_LOG": "trace"]
                environment["XODUS_DESCRIPTOR_METRICS"] = value
                let selected = ManagementClient.operationalEnvironment(environment)
                check(selected["HOME"] == "/neutral" && selected["SECRET"] == nil && selected["RUST_LOG"] == "error"
                      && selected["XODUS_DESCRIPTOR_METRICS"] == (value == "1" ? "1" : nil),
                      "Owned launcher permits only exact metrics opt-in and preserves environment restrictions")
            }
            let savedOptIn = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_METRICS"]
            setenv("XODUS_DESCRIPTOR_METRICS", "true", 1)
            let disabled = try ManagementClient()
            do { _ = try await disabled.connect(mockConfiguration("metricsearly")) }
            catch {
                if let savedOptIn { setenv("XODUS_DESCRIPTOR_METRICS", savedOptIn, 1) }
                else { unsetenv("XODUS_DESCRIPTOR_METRICS") }
                throw error
            }
            if let savedOptIn { setenv("XODUS_DESCRIPTOR_METRICS", savedOptIn, 1) }
            else { unsetenv("XODUS_DESCRIPTOR_METRICS") }
            do {
                _ = try await disabled.descriptorMetricsCheckpoint()
                check(false, "Nonexact opt-in keeps actual owned transport measurement disabled")
            } catch {
                check(error as? ManagementError == .invalidRequest,
                      "Nonexact opt-in keeps actual owned transport measurement disabled")
            }
            _ = try await disabled.request(.jobs)
            check(await disabled.close(), "Disabled measurement preserves ordinary owned transport")
            for scenario in ["metricsearly", "metricslate", "metricsmissing", "metricsstale", "metricsdrainfail",
                             "metricsbusy", "metricsbusytimeout", "metricsbusycap", "metricsbarrier"] {
                let previous = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_METRICS"]
                setenv("XODUS_DESCRIPTOR_METRICS", "1", 1)
                let client = try ManagementClient()
                do { _ = try await client.connect(mockConfiguration(scenario)) }
                catch {
                    if let previous { setenv("XODUS_DESCRIPTOR_METRICS", previous, 1) }
                    else { unsetenv("XODUS_DESCRIPTOR_METRICS") }
                    throw error
                }
                if let previous { setenv("XODUS_DESCRIPTOR_METRICS", previous, 1) }
                else { unsetenv("XODUS_DESCRIPTOR_METRICS") }
                if scenario == "metricsbarrier" {
                    let prior = Task { try await client.request(.jobs) }
                    while await client.pendingRequestCount == 0 { await Task.yield() }
                    let fence = Task { try await client.descriptorMetricsCheckpoint() }
                    while await !client.descriptorCheckpointPending, !fence.isCancelled {
                        if await client.pendingRequestCount == 0 { break }
                        await Task.yield()
                    }
                    let later = Task { try await client.request(.jobs) }
                    do {
                        let counts = try await fence.value
                        check(counts.checkpoint == 2,
                              "Checkpoint drains prior work and fences later request admission")
                    } catch {
                        check(false, "Checkpoint drains prior work and fences later request admission")
                    }
                    _ = try await prior.value
                    _ = try await later.value
                    check(await client.close(), "Owned admission boundary fixture closes")
                    continue
                } else if scenario.hasPrefix("metricsbusy") {
                    let held = Task { try await client.request(.jobs) }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while await client.pendingRequestCount == 0, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let fence = Task { try await client.descriptorMetricsCheckpoint() }
                    while await !client.descriptorCheckpointPending { await Task.yield() }
                    if scenario == "metricsbusytimeout" {
                        do {
                            _ = try await client.request(.jobs, timeout: .milliseconds(20))
                            check(false, "Queued request retains its original timeout budget")
                        } catch {
                            check(error as? ManagementError == .requestTimedOut,
                                  "Queued request retains its original timeout budget")
                        }
                        _ = try? await fence.value
                        _ = try? await held.value
                        check(await client.close(), "Timed-out boundary transport closes")
                        continue
                    }
                    if scenario == "metricsbusycap" {
                        let queued = (0..<63).map { _ in Task { try await client.request(.jobs) } }
                        while await client.descriptorQueuedRequestCount < 63 { await Task.yield() }
                        do {
                            _ = try await client.request(.jobs)
                            check(false, "Boundary waiters share the unchanged 64-request limit")
                        } catch {
                            check(error as? ManagementError == .outputOverflow,
                                  "Boundary waiters share the unchanged 64-request limit")
                        }
                        for task in queued { task.cancel() }
                        for task in queued { _ = try? await task.value }
                        fence.cancel()
                        _ = try? await fence.value
                        check(await client.close(), "Capped boundary fixture closes")
                        _ = try? await held.value
                        continue
                    }
                    let cancelled = Task { try await client.request(.jobs) }
                    cancelled.cancel()
                    do { _ = try await cancelled.value; check(false, "Queued boundary request preserves cancellation") }
                    catch { check(error is CancellationError, "Queued boundary request preserves cancellation") }
                    fence.cancel()
                    do { _ = try await fence.value; check(false, "Cancelled boundary cannot certify pending work") }
                    catch { check(error is CancellationError, "Cancelled boundary cannot certify pending work") }
                    let disconnectFence = Task { try await client.descriptorMetricsCheckpoint() }
                    while await !client.descriptorCheckpointPending { await Task.yield() }
                    let queued = Task { try await client.request(.jobs) }
                    check(await client.close(), "Owned busy metrics fixture closes")
                    do { _ = try await queued.value; check(false, "Disconnect releases queued boundary requests") }
                    catch { check(error as? ManagementError == .disconnected, "Disconnect releases queued boundary requests") }
                    _ = try? await disconnectFence.value
                    _ = try? await held.value
                    continue
                }
                if scenario == "metricsstale" {
                    _ = try await client.request(.diagnostics)
                    do {
                        _ = try await client.descriptorMetricsCheckpoint()
                        check(false, "Delayed prior export marker cannot certify a new missing checkpoint")
                    } catch {
                        check(error as? ManagementError == .invalidPayload,
                              "Delayed prior export marker cannot certify a new missing checkpoint")
                    }
                } else if scenario == "metricsdrainfail" {
                    do {
                        _ = try await client.descriptorMetricsCheckpoint()
                        check(false, "Drain failure cannot certify a checkpoint")
                    } catch {
                        check(error as? ManagementError == .backendError("NETWORK_UNAVAILABLE", retryable: false),
                              "Drain failure cannot certify a checkpoint")
                    }
                } else {
                    let first = try await client.descriptorMetricsCheckpoint()
                    check(first.checkpoint == 2 && first.lookups == 0 && first.attempts == 0,
                          "Actual owned fixture correlates checkpoint and result across \(scenario) pipes")
                    if scenario == "metricsmissing" {
                        do {
                            _ = try await client.descriptorMetricsCheckpoint()
                            check(false, "An earlier checkpoint cannot certify a later export with a missing marker")
                        } catch {
                            check(error as? ManagementError == .invalidPayload,
                                  "An earlier checkpoint cannot certify a later export with a missing marker")
                        }
                    } else if scenario == "metricslate" {
                        let second = Task { try await client.descriptorMetricsCheckpoint() }
                        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                        while await !client.descriptorCheckpointPending, ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                        do {
                            _ = try await client.descriptorMetricsCheckpoint()
                            check(false, "Concurrent exports cannot share one fresh checkpoint")
                        } catch {
                            check(error as? ManagementError == .invalidRequest,
                                  "Concurrent exports cannot share one fresh checkpoint")
                        }
                        check(try await second.value.checkpoint == 3,
                              "Late stderr marker still certifies only its own completed export")
                    } else {
                        let second = try await client.descriptorMetricsCheckpoint()
                        check(second.checkpoint == 3, "Multiple exports require fresh monotonic checkpoints")
                    }
                }
                check(await client.close(), "Owned count-only metrics fixture closes")
            }
        }

    func requestPressureChecks() async throws {
        let requests = try ManagementClient()
        _ = try await requests.connect(mockConfiguration("requestpressure"))
        let held = (0..<64).map { _ in Task {
            do { _ = try await requests.request(.jobs); return false }
            catch { return error as? ManagementError == .disconnected }
        } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await requests.pendingRequestCount < 64, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(await requests.pendingRequestCount == 64, "Fixture holds sixty-four actual requests")
        do {
            _ = try await requests.request(.jobs)
            check(false, "Request pressure is distinguished before dispatch")
        } catch {
            let failure = await requests.lastOverflow
            check(error as? ManagementError == .outputOverflow
                  && failure?.origin == .requestBudget,
                  "Request pressure is distinguished before dispatch")
        }
        check(await requests.close(), "Owned request-pressure fixture closes")
        for task in held { check(await task.value, "Held read terminates on owned close") }
    }

    func contractSchemaChecks(canonicalURL: URL) throws {
        let bundledURL = try ContractValidator.bundledSchemaURL()
        let canonical = try Data(contentsOf: canonicalURL)
        let bundled = try Data(contentsOf: bundledURL)
        check(bundled == canonical, "App contract bytes exactly match the frozen canonical producer schema")
        let validator = try ContractValidator()
        let producer = try ContractValidator(schemaURL: canonicalURL, schemaIdentifier: "urn:xodus:management:1.0")
        let positive = try fixture("positive").array ?? []
        for frame in positive {
            try validator.validate(frame)
            try producer.validate(frame)
        }
        check(positive.count == 102, "App and canonical validators preserve all 102 supported producer frames")
        let sourceWarnings = try fixture("query-source-failure").array ?? []
        check(sourceWarnings.count == 2, "REQ100 retains both exact a31f63df producer source-warning fixtures")
        for frame in sourceWarnings {
            try validator.validate(frame)
            try producer.validate(frame)
            guard let payload = frame["data"] ?? frame["error"]?["details"] else {
                throw ManagementError.invalidPayload
            }
            let query = try payload.decode(CatalogQuery.self)
            check(query.sourceFailure?.code == .packageUnavailable && query.nextCursor != nil,
                  "REQ100 canonical \(frame["requestID"]?.string ?? "") retains warning and opaque cursor")
        }
        for definition in ["queryData", "failedQueryData"] {
            guard var page = positive.first(where: {
                let value = definition == "queryData" ? $0["data"] : $0["error"]?["details"]
                return value?["corpus"]?.string == "publicMicrosoftStoreSearch"
            }).flatMap({ definition == "queryData" ? $0["data"]?.object : $0["error"]?["details"]?.object }) else {
                throw ManagementError.invalidPayload
            }
            for source in ["MicrosoftStoreEdge:v9.0/searchResults",
                           "XboxComSearch+MicrosoftStoreEdge:v9.0/searchResults"] {
                page["source"] = .string(source)
                try validator.validate(.object(page), definition: definition)
                try producer.validate(.object(page), definition: definition)
                check(true, "Both contracts accept actual producer \(definition) source \(source)")
                if definition == "queryData", var product = page["products"]?.array?.first?.object {
                    let originalProducts = page["products"]
                    product["freshness"] = .string("cached")
                    page["products"] = .array([.object(product)])
                    try validator.validate(.object(page), definition: definition)
                    try producer.validate(.object(page), definition: definition)
                    check(true, "Both contracts preserve cached product descriptors under live query source \(source)")
                    for invalid in ["pageFreshness", "pcCandidate"] {
                        var rejected = page
                        if invalid == "pageFreshness" { rejected["freshness"] = .string("cached") }
                        else {
                            var nonPC = product
                            nonPC["pcCatalogCandidate"] = .bool(false)
                            rejected["products"] = .array([.object(nonPC)])
                        }
                        for contract in [validator, producer] {
                            do {
                                try contract.validate(.object(rejected), definition: definition)
                                check(false, "Query contract rejects \(invalid) despite cached descriptor compatibility")
                            } catch ManagementError.invalidPayload {
                                check(true, "Query contract rejects \(invalid) despite cached descriptor compatibility")
                            }
                        }
                    }
                    page["products"] = originalProducts
                }
            }
            for code in ["PACKAGE_UNAVAILABLE", "NETWORK_UNAVAILABLE"] {
                let warning: [String: JSONValue] = [
                    "code": .string(code), "message": .string(String(repeating: "x", count: 1_024)),
                    "retryable": .bool(code == "NETWORK_UNAVAILABLE")
                ]
                page["sourceFailure"] = .object(warning)
                for contract in [validator, producer] {
                    try contract.validate(.object(page), definition: definition)
                }
                let decoded = try JSONValue.object(page).decode(CatalogQuery.self)
                check(decoded.sourceFailure?.code.rawValue == code && decoded.sourceFailure?.message.count == 1_024,
                      "REQ100 \(definition) decodes bounded \(code) source warning")
                for invalid in ["null", "unknownCode", "emptyMessage", "longMessage", "extraField", "missingRetryable"] {
                    var rejected = page
                    var badWarning = warning
                    switch invalid {
                    case "unknownCode": badWarning["code"] = .string("AUTH_INVALID")
                    case "emptyMessage": badWarning["message"] = .string("")
                    case "longMessage": badWarning["message"] = .string(String(repeating: "x", count: 1_025))
                    case "extraField": badWarning["details"] = .object([:])
                    case "missingRetryable": badWarning.removeValue(forKey: "retryable")
                    default: break
                    }
                    rejected["sourceFailure"] = invalid == "null" ? .null : .object(badWarning)
                    for contract in [validator, producer] {
                        do {
                            try contract.validate(.object(rejected), definition: definition)
                            check(false, "REQ100 \(definition) refuses \(invalid) source warning")
                        } catch ManagementError.invalidPayload {
                            check(true, "REQ100 \(definition) refuses \(invalid) source warning")
                        }
                    }
                }
            }
            page.removeValue(forKey: "sourceFailure")
            if definition == "queryData", var product = page["products"]?.array?.first?.object {
                product["source"] = .string("syntheticPublicSource")
                var budgetPage = page
                budgetPage["products"] = .array([.object(product)])
                let failures: [JSONValue] = (0..<16).map { index in
                    .object(["productID": .string(String(format: "9REJ%08d", index)),
                        "error": .object(["code": .string("PACKAGE_UNAVAILABLE"),
                            "message": .string("Synthetic rejected candidate."), "retryable": .bool(false)])])
                }
                budgetPage["failures"] = .array(failures)
                for contract in [validator, producer] {
                    try contract.validate(.object(budgetPage), definition: definition)
                }
                let decoded = try JSONValue.object(budgetPage).decode(CatalogQuery.self)
                guard let product = decoded.products.first else { throw ManagementError.invalidPayload }
                try decoded.validatePublicScope(query: decoded.query, market: product.market,
                                                language: product.language, limit: 1)
                check(true, "REQ100 product page limit is independent of its sixteen rejected candidates")
                budgetPage["failures"] = .array(failures + [
                    .object(["productID": .string("9REJ00000016"),
                        "error": .object(["code": .string("PACKAGE_UNAVAILABLE"),
                            "message": .string("Synthetic overflow candidate."), "retryable": .bool(false)])])
                ])
                do {
                    try JSONValue.object(budgetPage).decode(CatalogQuery.self).validatePublicScope(
                        query: decoded.query, market: product.market, language: product.language, limit: 1)
                    check(false, "REQ100 rejects seventeen candidate failures")
                } catch ManagementError.invalidPayload {
                    check(true, "REQ100 rejects seventeen candidate failures")
                }
            }
            page["source"] = .string("untrustedSource")
            for contract in [validator, producer] {
                do {
                    try contract.validate(.object(page), definition: definition)
                    check(false, "Contract rejects unknown query source in \(definition)")
                } catch ManagementError.invalidPayload {
                    check(true, "Contract rejects unknown query source in \(definition)")
                }
            }
        }
        for item in try fixture("negative").array ?? [] {
            guard let frame = item["frame"] else { throw ManagementError.invalidPayload }
            for contract in [validator, producer] {
                do {
                    try contract.validate(frame)
                    check(false, "Contract retains negative fixture rejection")
                } catch ManagementError.invalidFrame {
                    check(true, "Contract retains negative fixture rejection")
                }
            }
        }
    }

    func run() async throws {
        try await descriptorMetricsChecks()
        try await overflowChecks()
        try odeAccountChecks()
        try accountTierChecks()
        try registryDevelopmentChecks()
        try installPlanDevelopmentChecks()
        try installLifecycleChecks()
        try await runtimePlanChecks()
        try packageTypeChecks()
        try engineRoutingChecks()
        try await hostBindingChecks()
        try await artworkChecks()
        let validator = try ContractValidator()
        let positive = try fixture("positive").array ?? []
        check(positive.count == 102, "Pinned producer corpus contains 102 positive frames")
        for (index, frame) in positive.enumerated() {
            do { try validator.validate(frame); check(true, "Producer positive frame \(index + 1)") }
            catch { check(false, "Producer positive frame \(index + 1)") }
        }

        func hostBindingChecks() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("XodusHostBindingChecks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { check(false, "Synthetic helper binding files are cleaned") }
            }
            let executable = root.appendingPathComponent("synthetic-helper")
            let bytes = Data("synthetic helper bytes, never executed".utf8)
            try bytes.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executable.path)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let binding = NativeAuthHostBinding(executable: executable, sha256: hash)
            check(try NativeAuthHostBinding.bundled(in: .module) == nil,
                  "Unpackaged anonymous checks do not require a bundled native helper")
            check(try binding.validatedArguments() == [
                "--native-auth-host", executable.path, "--native-auth-host-sha256", hash,
                "--native-auth-host-version", "1"
            ], "Reviewed nonsecret helper binding forwards all three explicit paired flags")
            for invalid in [
                NativeAuthHostBinding(executable: executable, sha256: String(repeating: "0", count: 64)),
                NativeAuthHostBinding(executable: executable, sha256: hash, version: 2),
                NativeAuthHostBinding(executable: root.appendingPathComponent("missing"), sha256: hash)
            ] {
                do { _ = try invalid.validatedArguments(); check(false, "Wrong helper hash/version/path fails cleanly") }
                catch { check(error as? ManagementError == .backendUnavailable,
                              "Wrong helper hash/version/path fails cleanly") }
            }
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
            do {
                _ = try NativeAuthHostBinding(executable: alias, sha256: hash).validatedArguments()
                check(false, "A helper symlink cannot substitute for the reviewed owned regular executable")
            } catch {
                check(error as? ManagementError == .backendUnavailable,
                      "A helper symlink cannot substitute for the reviewed owned regular executable")
            }
            let hardlink = root.appendingPathComponent("hardlink")
            try FileManager.default.linkItem(at: executable, to: hardlink)
            do { _ = try binding.validatedArguments(); check(false, "Hard-linked helper is rejected") }
            catch { check(error as? ManagementError == .backendUnavailable, "Hard-linked helper is rejected") }
            try FileManager.default.removeItem(at: hardlink)
            try FileManager.default.setAttributes([.posixPermissions: 0o522], ofItemAtPath: executable.path)
            do { _ = try binding.validatedArguments(); check(false, "Group/world-writable helper is rejected") }
            catch { check(error as? ManagementError == .backendUnavailable, "Group/world-writable helper is rejected") }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executable.path)
            let app = root.appendingPathComponent("Synthetic.app")
            let macOS = app.appendingPathComponent("Contents/MacOS")
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "invalid.example.synthetic", "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "XodusAuthHost"
            ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let helper = macOS.appendingPathComponent("XodusAuthHost")
            try FileManager.default.copyItem(at: executable, to: helper)
            guard let bundle = Bundle(url: app) else { throw ManagementError.backendUnavailable }
            let metadata = resources.appendingPathComponent("XodusAuthHost.json")
            try FileManager.default.removeItem(at: helper)
            do {
                _ = try NativeAuthHostBinding.bundled(in: bundle)
                check(false, "A packaged app missing both helper and receipt cannot silently omit the binding")
            } catch {
                check(error as? ManagementError == .nativeAuthHostUnavailable,
                      "A packaged app missing both helper and receipt cannot silently omit the binding")
            }
            try FileManager.default.copyItem(at: executable, to: helper)
            let source = String(repeating: "0", count: 40)
            let canonical = Data("{\"sha256\": \"\(hash)\", \"sourceCommit\": \"\(source)\", \"version\": 1}\n".utf8)
            try canonical.write(to: metadata)
            check(try NativeAuthHostBinding.bundled(in: bundle)?.validatedArguments().first == "--native-auth-host",
                  "Bundled helper metadata creates only the fixed owned executable binding")
            try FileManager.default.removeItem(at: helper)
            do { _ = try NativeAuthHostBinding.bundled(in: bundle); check(false, "Receipt alone cannot supply a helper") }
            catch { check(error as? ManagementError == .nativeAuthHostUnavailable, "Receipt alone cannot supply a helper") }
            try FileManager.default.copyItem(at: executable, to: helper)
            for malformed in [
                Data("{\"sha256\":\"\(hash)\",\"sha256\":\"\(hash)\",\"sourceCommit\":\"\(source)\",\"version\":1}".utf8),
                Data("{\"sha256\":\"\(hash)\",\"sourceCommit\":\"\(source)\",\"version\":1,\"unknown\":true}".utf8)
            ] {
                try malformed.write(to: metadata)
                do { _ = try NativeAuthHostBinding.bundled(in: bundle); check(false, "Noncanonical duplicate/extra binding metadata is rejected") }
                catch { check(error as? ManagementError == .nativeAuthHostUnavailable,
                              "Noncanonical duplicate/extra binding metadata is rejected") }
            }
            try FileManager.default.removeItem(at: metadata)
            do { _ = try NativeAuthHostBinding.bundled(in: bundle); check(false, "Incomplete bundle pairing cannot fall back") }
            catch { check(error as? ManagementError == .nativeAuthHostUnavailable, "Incomplete bundle pairing cannot fall back") }
            guard mkfifo(metadata.path, 0o600) == 0 else { throw ManagementError.backendUnavailable }
            do { _ = try NativeAuthHostBinding.bundled(in: bundle); check(false, "FIFO metadata is rejected without blocking") }
            catch { check(error as? ManagementError == .nativeAuthHostUnavailable, "FIFO metadata is rejected without blocking") }
            try FileManager.default.removeItem(at: metadata)
            let verificationValidator = try ContractValidator()
            let verificationRequest: JSONValue = .object([
                "kind": .string("request"), "protocol": .object(["major": .integer(1), "minor": .integer(0)]),
                "requestID": .string("neutral-authenticated-read"), "command": .string("auth.verify"),
                "params": .object(["contentID": .string("513710f5-ab8e-4d7c-9ed5-d0ba94dcfb33")])
            ])
            try verificationValidator.validate(verificationRequest)
            check(ManagementCommand.authVerify.defaultTimeout == .seconds(30),
                  "Authenticated read is an explicit negotiated operation with a 30-second deadline")
            for params: JSONValue in [
                .object([:]), .object(["contentID": .string("not-a-uuid")]),
                .object(["contentID": .string("513710F5-AB8E-4D7C-9ED5-D0BA94DCFB33")]),
                .object(["contentID": .string("513710f5-ab8e-4d7c-9ed5-d0ba94dcfb33"), "token": .string("synthetic")])
            ] {
                var request = verificationRequest.object ?? [:]; request["params"] = params
                do { try verificationValidator.validate(.object(request)); check(false, "Invalid authenticated-read input is rejected") }
                catch { check(true, "Invalid authenticated-read input is rejected") }
            }
            for data: JSONValue in [.object(["verified": .bool(false)]),
                .object(["verified": .integer(1)]), .object(["verified": .bool(true), "extra": .null])] {
                do { try verificationValidator.validate(data, definition: "authVerifiedData"); check(false, "Only exact verified:true is accepted") }
                catch { check(true, "Only exact verified:true is accepted") }
            }
            for stage in AuthenticatedReadFailure.allCases {
                let error: JSONValue = .object(["code": .string(stage.code), "retryable": .bool(stage.retryable),
                                               "message": .string(stage.message), "details": stage.details])
                check(AuthenticatedReadFailure(error: error) == stage, "Exact authenticated-read failure tuple decodes")
                for key in ["code", "message", "retryable", "details"] {
                    var wrong = error.object ?? [:]
                    wrong[key] = key == "retryable" ? .bool(!stage.retryable) : .string("synthetic-invalid")
                    check(AuthenticatedReadFailure(error: .object(wrong)) == nil,
                          "Wrong authenticated-read tuple member is never promoted")
                }
            }
            let verifier = try ManagementClient()
            _ = try await verifier.connect(mockConfiguration("verify"))
            let verified = try await verifier.request(.authVerify,
                params: ["contentID": .string("513710f5-ab8e-4d7c-9ed5-d0ba94dcfb33")])
                .decode(AuthenticationVerification.self)
            check(verified.verified, "Negotiated neutral authenticated read preserves the exact success result")
            check(await verifier.close(), "Neutral verification transport closes")
            for stage in AuthenticatedReadFailure.allCases {
                let verifier = try ManagementClient()
                _ = try await verifier.connect(mockConfiguration("verify-" + stage.rawValue))
                do {
                    _ = try await verifier.request(.authVerify,
                        params: ["contentID": .string("513710f5-ab8e-4d7c-9ed5-d0ba94dcfb33")])
                    check(false, "Authenticated-read failures remain typed closed stages")
                } catch {
                    check(error as? ManagementError == .authenticatedReadFailed(stage),
                          "Authenticated-read failures remain typed closed stages")
                }
                check(await verifier.close(), "Failed neutral verification transport closes")
            }
            let client = try ManagementClient()
            do {
                _ = try await client.connect(BackendConfiguration(
                    executable: executable, stateDirectory: root.appendingPathComponent("unused-state"),
                    nativeAuthHost: NativeAuthHostBinding(executable: helper, sha256: String(repeating: "0", count: 64))))
                check(false, "Invalid helper admission fails actionably before attempting engine launch")
            } catch {
                check(error as? ManagementError == .nativeAuthHostUnavailable,
                      "Invalid helper admission fails actionably before attempting engine launch")
            }
            check(await client.close(), "Failed helper preflight leaves no owned engine to retire")
            check(ManagementError.nativeAuthHostUnavailable.localizedDescription.contains("native sign-in helper")
                  && !ManagementError.nativeAuthHostUnavailable.localizedDescription.contains("passkey"),
                  "Helper recovery copy does not claim passkey support or diagnose a provider prompt")
        }
        let negative = try fixture("negative").array ?? []
        check(negative.count == 99, "Pinned producer corpus contains 99 negative frames")
        for item in negative {
            do {
                guard let frame = item["frame"] else { throw ManagementError.invalidPayload }
                try validator.validate(frame)
                check(false, "Reject \(item["name"]?.string ?? "negative fixture")")
            } catch { check(true, "Reject \(item["name"]?.string ?? "negative fixture")") }
        }
        let flowResults = positive.filter { $0["data"]?["flow"]?.object != nil }
        check(flowResults.count >= 2, "Producer corpus includes native authentication flow results")
        for frame in flowResults {
            guard let data = frame["data"] else { throw ManagementError.invalidPayload }
            let status = try data.decode(AuthenticationStatus.self)
            check(status.flow != nil && !status.entitlementAuthorized,
                  "Typed native authentication flow never promotes PC entitlement")
        }
        check(Set(NativeConsentFailure.allCases.map(\.rawValue)) == [
            "bootstrapInvalid", "clientUnavailable", "credentialStorageUnavailable", "storedCredentialInvalid",
            "providerRequestFailed", "providerProofInvalid", "proofUnavailable", "pipelineFailed", "proofInvalid",
            "workerOutcomeUnavailable", "registrationProofInvalid", "tokenResponseInvalid", "tokenProofInvalid",
            "tokenStructureInvalid", "tokenKindInvalid", "tokenAudienceInvalid", "tokenCipherInvalid", "tokenSecretInvalid",
            "tokenXmlBoundInvalid", "tokenXmlParseInvalid", "tokenCipherEncodingInvalid"
        ], "Static subsite allowlist contains exactly twenty-one reasons and preserves all eighteen older reasons")
        for diagnostic in NativeConsentFailure.allCases {
            let frame: JSONValue = .object(["code": .string("AUTH_INVALID"), "retryable": .bool(false),
                "message": .string("Original upstream diagnostic sentinel is not UI copy."), "details": diagnostic.details])
            try validator.validate(frame, definition: "error")
            let typed = try frame.decode(WireFailure.self)
            check(typed.nativeConsentFailure == diagnostic,
                  "Closed native-consent stage/reason pair decodes without arbitrary details")
            check(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(typed)) == frame,
                  "Typed native-consent diagnostics round-trip without altering their allowlist")
        }
        let invalidDetails: [JSONValue] = [
            .object(["category": .string("nativeConsentFailure"), "stage": .string("devicePreparation"),
                     "reason": .string("providerRequestFailed"), "secret": .string("Original extra-field sentinel")]),
            .object(["category": .string("nativeConsentFailure"), "stage": .string("unknownStage"),
                     "reason": .string("providerRequestFailed")]),
            .object(["category": .string("nativeConsentFailure"), "stage": .string("devicePreparation"),
                     "reason": .string("unknownReason")]),
            .object(["category": .string("nativeConsentFailure"), "stage": .string("storeProof"),
                     "reason": .string("providerRequestFailed")]),
            .object(["category": .string("anotherCategory"), "stage": .string("devicePreparation"),
                     "reason": .string("providerRequestFailed")]),
            .object(["category": .string("nativeConsentFailure"), "stage": .integer(1),
                     "reason": .string("providerRequestFailed")]),
            .object(["category": .string("nativeConsentFailure"), "stage": .string("devicePreparation")]),
            .array([]), .null
        ]
        for details in invalidDetails {
            let frame: JSONValue = .object(["code": .string("AUTH_INVALID"), "retryable": .bool(false),
                "message": .string("Original upstream diagnostic sentinel is not UI copy."), "details": details])
            let typed = try frame.decode(WireFailure.self)
            let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(typed))
            check(typed.nativeConsentFailure == nil && encoded["details"] == nil,
                  "Unknown/malformed/extra diagnostic fields are discarded, never retained as safe stage evidence")
        }
        for code in ["AUTH_CANCELLED", "AUTH_EXPIRED", "INTERNAL_ERROR"] {
            let frame: JSONValue = .object(["code": .string(code), "retryable": .bool(false),
                "message": .string("Original upstream diagnostic sentinel is not UI copy."),
                "details": NativeConsentFailure.pipelineFailed.details])
            check(try frame.decode(WireFailure.self).nativeConsentFailure == nil,
                  "Cancellation/expiry/non-auth codes cannot borrow AUTH_INVALID diagnostic stage evidence")
        }
        for diagnostic in [NativeConsentFailure.registrationProofInvalid, .tokenResponseInvalid,
                           .tokenProofInvalid, .tokenStructureInvalid, .tokenKindInvalid,
                           .tokenAudienceInvalid, .tokenCipherInvalid, .tokenSecretInvalid,
                           .tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid] {
            var extra = diagnostic.details.object ?? [:]
            extra["secret"] = .string("Original refined-device private sentinel")
            var mismatched = diagnostic.details.object ?? [:]
            mismatched["stage"] = .string("storeProof")
            var unknown = diagnostic.details.object ?? [:]
            unknown["reason"] = .string("\(diagnostic.rawValue)Unsupported")
            var category = diagnostic.details.object ?? [:]
            category["category"] = .string("unrecognizedCategory")
            var malformed = diagnostic.details.object ?? [:]
            malformed["reason"] = .integer(1)
            var incomplete = diagnostic.details.object ?? [:]
            incomplete.removeValue(forKey: "stage")
            let rejected: [(String, JSONValue)] = [
                ("AUTH_INVALID", .object(extra)), ("AUTH_INVALID", .object(mismatched)),
                ("AUTH_INVALID", .object(unknown)), ("AUTH_INVALID", .object(category)),
                ("AUTH_INVALID", .object(malformed)), ("AUTH_INVALID", .object(incomplete)),
                ("AUTH_CANCELLED", diagnostic.details), ("AUTH_EXPIRED", diagnostic.details),
                ("INTERNAL_ERROR", diagnostic.details)
            ]
            var discarded = true
            for (code, details) in rejected {
                let frame: JSONValue = .object(["code": .string(code), "retryable": .bool(false),
                    "message": .string("Original refined upstream sentinel"), "details": details])
                let typed = try frame.decode(WireFailure.self)
                let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(typed))
                discarded = discarded && typed.nativeConsentFailure == nil && encoded["details"] == nil
            }
            check(discarded, "Refined device diagnostics require exact keys/stage/AUTH_INVALID without private-field retention")
        }
        let registryResults = positive.filter { $0["data"]?["installations"]?.array != nil }
        check(!registryResults.isEmpty, "Producer corpus includes installed-registry evidence")
        for frame in registryResults {
            guard let data = frame["data"] else { throw ManagementError.invalidPayload }
            let snapshot = try data.decode(InstalledSnapshot.self)
            check(snapshot.scope == "managementRegistryOnly" && snapshot.registryVersion.major == 1,
                  "Typed installed evidence remains explicitly scoped to its management registry")
        }
        guard let inspectionData = positive.first(where: {
            $0["data"]?["scope"]?.string == "userSelectedDirectory"
        })?["data"] else { throw ManagementError.invalidPayload }
        try validator.validate(inspectionData, definition: "inspectionData")
        let inspection = try inspectionData.decode(InstallationInspection.self)
        try inspection.validateSelection(directory: inspection.directory)
        check(!inspection.assessment.registered && !inspection.assessment.launchable
              && inspection.assessment.retailIdentity == "unknown",
              "Observed header identifiers never become retail identity, registration or launch permission")
        do {
            try inspection.validateSelection(directory: "/different/selected/folder")
            check(false, "Inspection must correlate exactly to the explicitly selected directory")
        } catch { check(true, "Inspection must correlate exactly to the explicitly selected directory") }
        for id in ["00000000-0000-0000-0000-000000000000", "not-a-uuid"] {
            var changed = inspectionData.object ?? [:]
            var marker = inspectionData["marker"]?.object ?? [:]
            marker["contentID"] = .string(id)
            changed["marker"] = .object(marker)
            do {
                try validator.validate(.object(changed), definition: "inspectionData")
                check(false, "Inspection rejects zero or malformed content identity")
            } catch { check(true, "Inspection rejects zero or malformed content identity") }
        }
        guard let discoveryData = positive.first(where: { $0["data"]?["corpus"]?.string == "pcGamePassDiscovery" })?["data"],
              let failedPage = positive.first(where: { $0["error"]?["details"]?["corpus"]?.string == "pcGamePassDiscovery" })?["error"]?["details"] else {
            throw ManagementError.invalidPayload
        }
        let discovery = try discoveryData.decode(CatalogDiscovery.self)
        check(discovery.products.first?.resolvedLanguage == "en" && discovery.failures.count == 1,
              "Typed mixed discovery exposes actual source language and per-product failure")
        try validator.validate(failedPage, definition: "failedDiscoveryData")
        check(try failedPage.decode(CatalogDiscovery.self).products.isEmpty,
              "All-failure details are distinct from success-shaped discovery")
        do {
            try validator.validate(failedPage, definition: "discoveryData")
            check(false, "Empty all-failure page cannot validate as success")
        } catch { check(true, "Empty all-failure page cannot validate as success") }
        guard var pageObject = discoveryData.object,
              var productObject = discoveryData["products"]?.array?.first?.object else {
            throw ManagementError.invalidPayload
        }
        productObject["source"] = .string("syntheticPublicSource")
        pageObject["products"] = .array([.object(productObject)])
        try JSONValue.object(pageObject).decode(CatalogDiscovery.self)
            .validatePublicScope(market: "US", language: "en-US", limit: 8)
        check(true, "Same-base neutral metadata language is explicit and allowed")
        productObject["pcCatalogCandidate"] = .bool(false)
        pageObject["products"] = .array([.object(productObject)])
        try JSONValue.object(pageObject).decode(CatalogDiscovery.self)
            .validatePublicScope(market: "US", language: "en-US", limit: 16)
        check(true, "B1: Validated PC Game Pass feed membership accepts a false candidate flag")
        do {
            try JSONValue.object(productObject).decode(CatalogProduct.self)
                .validatePublicScope(market: "US", language: "en-US")
            check(false, "B1: Cache search remains strict about the PC candidate flag")
        } catch { check(error as? ManagementError == .invalidPayload, "B1: Cache search remains strict about the PC candidate flag") }
        for change: (String, JSONValue) in [("market", .string("GB")), ("source", .string("fixture")),
                                           ("artworkStatus", .string("available"))] {
            var invalid = productObject
            invalid[change.0] = change.1
            if change.0 == "artworkStatus" { invalid["artwork"] = .array([]) }
            pageObject["products"] = .array([.object(invalid)])
            do {
                try JSONValue.object(pageObject).decode(CatalogDiscovery.self)
                    .validatePublicScope(market: "US", language: "en-US", limit: 16)
                check(false, "B1: Discovery retains scope/source/artwork checks with a false flag")
            } catch { check(true, "B1: Discovery retains scope/source/artwork checks with a false flag") }
        }
        for tag in ["en-GB", "fr"] {
            productObject["resolvedLanguage"] = .string(tag)
            pageObject["products"] = .array([.object(productObject)])
            do {
                try JSONValue.object(pageObject).decode(CatalogDiscovery.self)
                    .validatePublicScope(market: "US", language: "en-US", limit: 8)
                check(false, "Unrelated or other-region language is rejected")
            } catch { check(true, "Unrelated or other-region language is rejected") }
        }
        guard var queryProduct = discoveryData["products"]?.array?.first?.object else {
            throw ManagementError.invalidPayload
        }
        queryProduct["source"] = .string("syntheticPublicSource")
        var queryPage: [String: JSONValue] = [
            "corpus": .string("publicMicrosoftStoreSearch"), "completeness": .string("partial"),
            "source": .string("MicrosoftStoreEdge:v9.0/searchResults"),
            "checkedAt": discoveryData["checkedAt"] ?? .null, "freshness": .string("live"),
            "query": .string("original fixture query"), "products": .array([.object(queryProduct)]),
            "failures": discoveryData["failures"] ?? .array([]), "nextCursor": .null
        ]
        try JSONValue.object(queryPage).decode(CatalogQuery.self).validatePublicScope(
            query: "original fixture query", market: "US", language: "en-US", limit: 8)
        check(true, "Typed network query preserves source, PC scope and mixed failures")
        var combinedQuery = queryPage
        combinedQuery["source"] = .string("XboxComSearch+MicrosoftStoreEdge:v9.0/searchResults")
        var neutralProduct = queryProduct
        neutralProduct["market"] = .string("RO")
        neutralProduct["language"] = .string("ro-RO")
        neutralProduct["resolvedLanguage"] = .string("neutral")
        neutralProduct["gamePass"] = .object([
            "status": .string("known"),
            "plans": .array([.object([
                "id": .string("CFQ7TTC0KGQ8"),
                "name": .string("Game Pass pentru PC")
            ])]),
            "completeness": .string("partial"),
            "market": .string("RO"),
            "checkedAt": discoveryData["checkedAt"] ?? .null,
            "source": .string("xbox.com-search")
        ])
        combinedQuery["products"] = .array([.object(neutralProduct)])
        let tieredQuery = try JSONValue.object(combinedQuery).decode(CatalogQuery.self)
        try tieredQuery.validatePublicScope(
            query: "original fixture query", market: "RO", language: "ro-RO", limit: 8)
        try validator.validate(.object(combinedQuery), definition: "queryData")
        check(tieredQuery.products.first?.gamePass?.plans.first?.name == "Game Pass pentru PC",
              "#44: Xbox search plan ID and exact market-local label decode and validate without a tier inference")
        var invalidTierQuery = combinedQuery
        var knownEmptyTierProduct = neutralProduct
        knownEmptyTierProduct["gamePass"] = .object([
            "status": .string("known"), "plans": .array([]), "completeness": .string("partial"),
            "market": .string("RO"), "checkedAt": discoveryData["checkedAt"] ?? .null,
            "source": .string("xbox.com-search")
        ])
        var knownEmptyQueryFrame = combinedQuery
        knownEmptyQueryFrame["products"] = .array([.object(knownEmptyTierProduct)])
        try validator.validate(.object(knownEmptyQueryFrame), definition: "queryData")
        let knownEmptyQuery = try JSONValue.object(knownEmptyQueryFrame).decode(CatalogQuery.self)
        try knownEmptyQuery.validatePublicScope(query: "original fixture query", market: "RO",
                                                language: "ro-RO", limit: 8)
        check(knownEmptyQuery.products.first?.gamePass?.plans.isEmpty == true,
              "#44: Known-empty listings are accepted as partial observations, not exclusions")
        var invalidTierProduct = neutralProduct
        invalidTierProduct["gamePass"] = .object([
            "status": .string("unknown"),
            "plans": .array([.object(["id": .string("CFQ7TTC0KGQ8"), "name": .string("Game Pass for PC")])]),
            "completeness": .string("partial"), "market": .string("RO"),
            "checkedAt": discoveryData["checkedAt"] ?? .null, "source": .string("xbox.com-search")
        ])
        invalidTierQuery["products"] = .array([.object(invalidTierProduct)])
        do {
            try validator.validate(.object(invalidTierQuery), definition: "queryData")
            check(false, "#44: Unknown listing cannot claim plans")
        } catch { check(true, "#44: Unknown listing cannot claim plans") }
        invalidTierProduct["gamePass"] = .object([
            "status": .string("known"), "plans": .array([]), "completeness": .string("partial"),
            "market": .string("US"), "checkedAt": discoveryData["checkedAt"] ?? .null,
            "source": .string("xbox.com-search")
        ])
        invalidTierQuery["products"] = .array([.object(invalidTierProduct)])
        do {
            try JSONValue.object(invalidTierQuery).decode(CatalogQuery.self)
                .validatePublicScope(query: "original fixture query", market: "RO", language: "ro-RO", limit: 8)
            check(false, "#44: Tier listing cannot cross market boundaries")
        } catch { check(error as? ManagementError == .invalidPayload, "#44: Tier listing cannot cross market boundaries") }
        var edgeTierQuery = queryPage
        var edgeTierProduct = queryProduct
        edgeTierProduct["gamePass"] = neutralProduct["gamePass"]
        edgeTierQuery["products"] = .array([.object(edgeTierProduct)])
        try validator.validate(.object(edgeTierQuery), definition: "queryData")
        check(true, "#44: Shared service schema admits the additive product record; app scope validation rejects Store Edge listings")
        do {
            try JSONValue.object(edgeTierQuery).decode(CatalogQuery.self)
                .validatePublicScope(query: "original fixture query", market: "US", language: "en-US", limit: 8)
            check(false, "#44: Store Edge continuation cannot claim xbox.com listing metadata")
        } catch { check(error as? ManagementError == .invalidPayload,
                        "#44: Store Edge continuation cannot claim xbox.com listing metadata") }
        var discoveryWithTier = discoveryData.object ?? [:]
        var discoveryProductWithTier = productObject
        discoveryProductWithTier["gamePass"] = neutralProduct["gamePass"]
        discoveryWithTier["products"] = .array([.object(discoveryProductWithTier)])
        try validator.validate(.object(discoveryWithTier), definition: "discoveryData")
        do {
            try JSONValue.object(discoveryWithTier).decode(CatalogDiscovery.self)
                .validatePublicScope(market: "RO", language: "ro-RO", limit: 8)
            check(false, "#44: PC Game Pass discovery cannot use query-only Xbox search listing")
        } catch { check(error as? ManagementError == .invalidPayload,
                        "#44: PC Game Pass discovery cannot use query-only Xbox search listing") }
        try validator.validate(.object(["product": .object(discoveryProductWithTier)]),
                               definition: "productData")
        let cachedSearchWithTier: [String: JSONValue] = [
            "products": .array([.object(discoveryProductWithTier)]),
            "corpus": .string("observedPublicProducts"),
            "completeness": .string("partial"),
            "nextCursor": .null,
            "cacheRevision": .unsigned(0)
        ]
        try validator.validate(.object(cachedSearchWithTier), definition: "searchData")
        combinedQuery["source"] = .string("UnverifiedSearch")
        do {
            try JSONValue.object(combinedQuery).decode(CatalogQuery.self).validatePublicScope(
                query: "original fixture query", market: "RO", language: "ro-RO", limit: 8)
            check(false, "#40: Unknown network query source remains rejected")
        } catch { check(error as? ManagementError == .invalidPayload,
                        "#40: Unknown network query source remains rejected") }
        queryProduct["pcCatalogCandidate"] = .bool(false)
        queryPage["products"] = .array([.object(queryProduct)])
        do {
            try JSONValue.object(queryPage).decode(CatalogQuery.self).validatePublicScope(
                query: "original fixture query", market: "US", language: "en-US", limit: 8)
            check(false, "B1: Store network query still rejects a false PC candidate")
        } catch { check(error as? ManagementError == .invalidPayload, "B1: Store network query still rejects a false PC candidate") }
        queryProduct["pcCatalogCandidate"] = .bool(true)
        queryPage["products"] = .array([.object(queryProduct)])
        do {
            try JSONValue.object(queryPage).decode(CatalogQuery.self).validatePublicScope(
                query: "different query", market: "US", language: "en-US", limit: 8)
            check(false, "Network query echo must match its exact request")
        } catch { check(error as? ManagementError == .invalidPayload, "Network query echo must match its exact request") }
        queryPage["products"] = .array([])
        queryPage["failures"] = .array([])
        try JSONValue.object(queryPage).decode(CatalogQuery.self).validatePublicScope(
            query: "original fixture query", market: "US", language: "en-US", limit: 8)
        check(true, "Genuine empty query is distinct from failed product checks")
        queryPage["nextCursor"] = .string("synthetic-opaque-cursor")
        do {
            try JSONValue.object(queryPage).decode(CatalogQuery.self).validatePublicScope(
                query: "original fixture query", market: "US", language: "en-US", limit: 8)
            check(false, "Empty source matches cannot claim another query page")
        } catch { check(error as? ManagementError == .invalidPayload, "Empty source matches cannot claim another query page") }
        let queryResults = positive.compactMap { $0["data"] }.filter {
            $0["corpus"]?.string == "publicMicrosoftStoreSearch"
        }
        check(queryResults.count >= 2, "Pinned query corpus contains real-shape success and empty results")
        for data in queryResults {
            try validator.validate(data, definition: "queryData")
            guard var combined = data.object else { throw ManagementError.invalidPayload }
            combined["source"] = .string("XboxComSearch+MicrosoftStoreEdge:v9.0/searchResults")
            try validator.validate(.object(combined), definition: "queryData")
            let page = try data.decode(CatalogQuery.self)
            check(page.corpus == "publicMicrosoftStoreSearch" && page.completeness == "partial",
                  "Typed canonical query remains public and partial, not entitlement")
        }
        guard let failedQuery = positive.first(where: {
            $0["error"]?["details"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
        })?["error"]?["details"] else { throw ManagementError.invalidPayload }
        try validator.validate(failedQuery, definition: "failedQueryData")
        guard var combinedFailure = failedQuery.object else { throw ManagementError.invalidPayload }
        combinedFailure["source"] = .string("XboxComSearch+MicrosoftStoreEdge:v9.0/searchResults")
        try validator.validate(.object(combinedFailure), definition: "failedQueryData")
        check(true, "#40: Combined search source validates both successful and all-failure frames without weakening failure shape")
        check(try failedQuery.decode(CatalogQuery.self).products.isEmpty,
              "Canonical all-failure query details are strict and independently typed")
        do {
            try validator.validate(failedQuery, definition: "queryData")
            check(false, "All-failure query cannot masquerade as successful empty search")
        } catch { check(true, "All-failure query cannot masquerade as successful empty search") }
        let edges = try fixture("evidence-edge").array ?? []
        check(edges.count == 4, "Four independent evidence edge cases remain distinct")
        for (index, value) in edges.enumerated() {
            do {
                try validator.validate(value, definition: "productEvidence")
                _ = try value.decode(ProductEvidence.self)
                check(true, "Typed evidence edge \(index + 1)")
            } catch { check(false, "Typed evidence edge \(index + 1)") }
        }
        var framer = JSONLineFramer()
        let collectionCounts = "Ode collection read: records=12; activeGameRows=10; productIDs=9; subscriptionRows=3"
        for split in 0...collectionCounts.utf8.count {
            var diagnostic = ManagementClient.CollectionDiagnosticFramer()
            let bytes = Data((collectionCounts + "\n").utf8)
            check(diagnostic.append(bytes.prefix(split)).isEmpty,
                  "Collection count diagnostics hold split \(split) until a full line")
            check(diagnostic.append(bytes.dropFirst(split)) == [collectionCounts],
                  "Collection count diagnostics admit exact split \(split)")
        }
        var diagnostic = ManagementClient.CollectionDiagnosticFramer()
        for rejected in ["prefix " + collectionCounts, collectionCounts + " suffix",
                         collectionCounts + "\r", collectionCounts.replacingOccurrences(of: "=12", with: "=-12"),
                         String(repeating: "x", count: 513) + collectionCounts] {
            check(diagnostic.append(Data((rejected + "\n").utf8)).isEmpty,
                  "Nonexact or overlong collection diagnostics are discarded")
        }
        check(diagnostic.append(Data([0xff, 10])).isEmpty,
              "Invalid UTF8 diagnostics are discarded")
        check(diagnostic.append(Data((collectionCounts + "\n" + collectionCounts + "\n").utf8))
              == [collectionCounts, collectionCounts],
              "Count framing recovers after rejected lines and handles multiple lines")
        check(try framer.append(Data("{\"kind\"".utf8)).isEmpty, "Split frame is held, not decoded prematurely")
        check(try framer.append(Data(":\"fixture\"}\n".utf8)).count == 1, "Split frame completes in order")
        try framer.finish()
        do {
            var limit = JSONLineFramer()
            _ = try limit.append(Data(repeating: 32, count: JSONLineFramer.maximumBytes + 1))
            check(false, "Oversized frame is rejected")
        } catch { check(error as? ManagementError == .frameTooLarge, "Oversized frame is rejected") }
        do {
            var partial = JSONLineFramer()
            _ = try partial.append(Data("{".utf8))
            try partial.finish()
            check(false, "Truncated frame is rejected on EOF")
        } catch { check(error as? ManagementError == .truncatedFrame, "Truncated frame is rejected on EOF") }
        try activityChecks(positive)

        let client = try ManagementClient()
        let hello = try await client.connect(mockConfiguration("normal"))
        check(hello.supports(.authStatus) && !hello.supports(.launch), "Negotiation gates unsupported gameplay")
        async let auth = client.request(.authStatus)
        async let snapshot = client.request(.jobs)
        let status = try await auth.decode(AuthenticationStatus.self)
        let jobs = try await snapshot.decode(JobsSnapshot.self)
        check(status.state == .signedOut && !status.entitlementAuthorized, "Credentials never imply entitlement")
        check(jobs.jobs.isEmpty, "Concurrent results are correlated by unique request IDs")
        do {
            _ = try await client.request(.launch, params: ["installationID": .string("fixture-install"),
                                                          "expectedRevision": .integer(0)])
            check(false, "Unsupported command is rejected before transport")
        } catch {
            check(error as? ManagementError == .capabilityMissing("game.launch"),
                  "Unsupported command is rejected before transport")
        }
        do {
            _ = try await client.request(.authStatus, params: ["token": .string("synthetic-forbidden-field")])
            check(false, "Credential parameter is rejected before transport")
        } catch { check(error as? ManagementError == .invalidRequest, "Credential parameter is rejected before transport") }
        check(await client.close(), "Owned normal transport closes before reconnect")
        let denied = try ManagementClient()
        _ = try await denied.connect(mockConfiguration("keychain"))
        do {
            _ = try await denied.request(.authStatus)
            check(false, "Keychain permission failure is not treated as invalid credentials")
        } catch {
            check(error as? ManagementError == .credentialStoreUnavailable,
                  "Keychain permission failure is not treated as invalid credentials")
        }
        check(await denied.close(), "Owned inaccessible-store transport closes")
        check(ManagementCommand.authBegin.defaultTimeout == .seconds(600)
              && ManagementCommand.authLogout.defaultTimeout == .seconds(600)
              && ManagementCommand.authStatus.defaultTimeout == .seconds(130)
              && ManagementCommand.authVerify.defaultTimeout == .seconds(30)
              && ManagementCommand.hello.defaultTimeout == .seconds(30),
              "Foreground saved-status permits bounded human Keychain access; verification and other reads stay short")
        let human = try ManagementClient()
        _ = try await human.connect(mockConfiguration("humanwait"))
        async let preparing = human.request(.authBegin, params: ["accountScope": .string("default")])
        async let loggingOut = human.request(.authLogout)
        async let checkingSaved = human.request(.authStatus)
        let readStart = ContinuousClock.now
        _ = try await human.request(.jobs)
        check(ContinuousClock.now - readStart < .seconds(2),
              "Public snapshot answers while fake human preparation/logout remain in flight")
        _ = try await preparing.decode(AuthenticationStatus.self)
        _ = try await loggingOut.decode(AuthenticationStatus.self)
        _ = try await checkingSaved.decode(AuthenticationStatus.self)
        _ = try await human.request(.jobs)
        check(true, "Preparation, logout and foreground saved-status exceeding thirty seconds preserve the connection")
        check(await human.close(), "Owned human-wait transport closes")
        let uncertain = try ManagementClient()
        _ = try await uncertain.connect(mockConfiguration("hangmutation"))
        do {
            _ = try await uncertain.request(.authBegin, params: ["accountScope": .string("default")],
                                            timeout: .milliseconds(200))
            check(false, "Mutation deadline never synthesizes success or blindly retries")
        } catch {
            check(error as? ManagementError == .requestTimedOut,
                  "Mutation deadline never synthesizes success or blindly retries")
        }
        check(await uncertain.close(), "Owned uncertain-mutation transport closes")
        let reconciled = try ManagementClient()
        _ = try await reconciled.connect(mockConfiguration("normal"))
        let reconciledStatus = try await reconciled.request(.authStatus).decode(AuthenticationStatus.self)
        check(reconciledStatus.state == .signedOut,
              "After an uncertain mutation, reconnect reads authoritative status before another mutation")
        check(await reconciled.close(), "Owned reconciliation transport closes")
        let discoveryFailure = try ManagementClient()
        _ = try await discoveryFailure.connect(mockConfiguration("discoveryfail"))
        do {
            _ = try await discoveryFailure.request(.discover, params: [
                "market": .string("US"), "language": .string("en-US"), "limit": .integer(8), "cursor": .null
            ])
            check(false, "Transport preserves only schema-validated all-failure discovery details")
        } catch let error as ManagementError {
            if case .discoveryFailed(let page) = error {
                check(page.products.isEmpty && !page.failures.isEmpty,
                      "Transport preserves only schema-validated all-failure discovery details")
            } else { check(false, "Transport preserves only schema-validated all-failure discovery details") }
        }
        check(await discoveryFailure.close(), "Owned failed-discovery transport closes")
        for scenario in ["queryfail", "badqueryfail", "querynodetails", "querynulldetails"] {
            let queryFailure = try ManagementClient()
            _ = try await queryFailure.connect(mockConfiguration(scenario))
            do {
                _ = try await queryFailure.request(.query, params: [
                    "query": .string("original fixture query"), "market": .string("US"),
                    "language": .string("en-US"), "limit": .integer(8), "cursor": .null
                ])
                check(false, "Query failure transport \(scenario)")
            } catch let error as ManagementError {
                if scenario == "queryfail", case .queryFailed(let page) = error {
                    check(page.products.isEmpty && !page.failures.isEmpty,
                          "Transport preserves schema-validated failed query details only")
                } else if scenario == "querynodetails" {
                    check(error == .backendError("PACKAGE_UNAVAILABLE", retryable: false),
                          "Source-level query failure without details stays a recoverable typed error")
                    _ = try await queryFailure.request(.jobs).decode(JobsSnapshot.self)
                    check(true, "Source-level query failure preserves the same connection for snapshots")
                } else if scenario == "querynulldetails" {
                    check(error == .invalidFrame || error == .invalidPayload,
                          "Present null query details are rejected, not treated as absent")
                } else {
                    check(scenario == "badqueryfail" && error == .invalidPayload,
                          "Transport rejects malformed all-failure query details")
                }
            }
            check(await queryFailure.close(), "Owned query-error transport closes")
        }
        for scenario in ["prompt", "oversize", "partial", "mismatch", "wrongid", "wrongshape", "eof", "exit", "timeout"] {
            let bad = try ManagementClient()
            do {
                _ = try await bad.connect(mockConfiguration(scenario))
                _ = try await bad.request(.authStatus, timeout: .milliseconds(200))
                check(false, "Transport rejects \(scenario)")
            } catch { check(error is ManagementError, "Transport rejects \(scenario) without raw diagnostic text") }
            check(await bad.close(), "Owned rejected transport \(scenario) closes")
        }
    }

    func probe(_ configuration: BackendConfiguration, discover: Bool = false, query: Bool = false,
               inspect: Bool = false) async throws {
        let client = try ManagementClient()
        do {
            let hello = try await client.connect(configuration)
            check(hello.schema == "urn:xodus:management:1.0", "Actual Xodus hello/schema negotiation")
            check(!hello.supports(.launch) && !hello.supports(.plan),
                  "Uncertified runtime/packages remain capability-gated")
            if hello.supports(.authStatus) {
                do {
                    let status = try await client.request(.authStatus).decode(AuthenticationStatus.self)
                    check(status.credentialStore == "macOSKeychain" && !status.entitlementAuthorized,
                          "Actual native Keychain status is not ownership proof")
                } catch let error as ManagementError {
                    switch error {
                    case .backendError("AUTH_INVALID", _):
                        check(true, "Actual auth.status explicitly rejects invalid saved credentials; no valid sign-in claimed")
                    case .credentialStoreUnavailable:
                        check(true, "Actual auth.status reports inaccessible credential store; no permission or account assumed")
                    default: throw error
                    }
                }
            }
            if hello.supports(.search) {
                let search = try await client.request(.search, params: [
                    "query": .string(""), "market": .string("US"), "language": .string("en-US"),
                    "platform": .string("pc"), "limit": .integer(100), "cursor": .null
                ]).decode(CatalogSearch.self)
                check(search.corpus == "observedPublicProducts" && search.completeness == "partial",
                      "Actual catalog is explicitly partial, not an entitled library")
            }
            if hello.supports(.jobs) {
                let snapshot = try await client.request(.jobs).decode(JobsSnapshot.self)
                check(snapshot.sessionID == hello.sessionID,
                      "Actual activity snapshot belongs to the negotiated engine session")
                var activity = ActivityStore()
                try activity.apply(snapshot)
                check(!activity.needsSnapshot, "Actual authoritative durable activity snapshot")
            }
            if query {
                guard hello.supports(.query) else { throw ManagementError.capabilityMissing("catalog.query") }
                let params: [String: JSONValue] = [
                    "query": .string("Halo"), "market": .string("US"), "language": .string("en-US"),
                    "limit": .integer(8), "cursor": .null
                ]
                func queryPage(_ params: [String: JSONValue]) async throws -> CatalogQuery {
                    do {
                        return try await client.request(.query, params: params, timeout: .seconds(45))
                            .decode(CatalogQuery.self)
                    } catch ManagementError.queryFailed(let page) { return page }
                }
                let first = try await queryPage(params)
                try first.validatePublicScope(query: "Halo", market: "US", language: "en-US", limit: 8)
                check(!first.products.isEmpty, "Actual Store network query resolves source-backed PC candidates")
                if let cursor = first.nextCursor {
                    var next = params
                    next["cursor"] = .string(cursor)
                    let second = try await queryPage(next)
                    try second.validatePublicScope(query: "Halo", market: "US", language: "en-US", limit: 8)
                    let firstIDs = Set(first.products.map(\.id) + first.failures.map(\.id))
                    let secondIDs = Set(second.products.map(\.id) + second.failures.map(\.id))
                    check(!secondIDs.isEmpty && firstIDs.isDisjoint(with: secondIDs)
                          && second.nextCursor != cursor,
                          "Actual scoped Store cursor advances without merging edition/product identities")
                }
                _ = try await client.request(.jobs).decode(JobsSnapshot.self)
                check(true, "Actual connection survives bounded Store network query pages")
            }
            if hello.supports(.installed) {
                let registry = try await client.request(.installed).decode(InstalledSnapshot.self)
                check(registry.scope == "managementRegistryOnly"
                      && Set(registry.installations.map(\.id)).count == registry.installations.count,
                      "Actual registry does not import legacy game folders")
            }
            if inspect {
                guard hello.supports(.inspectInstallation) else {
                    throw ManagementError.capabilityMissing("installed.inspect")
                }
                try await probeInspection(client, configuration: configuration)
            }
            if hello.supports(.diagnostics) {
                let report = try await client.request(.diagnostics)
                check(report["redacted"] == .bool(true), "Actual diagnostic preview is explicitly redacted")
            }
            if discover {
                guard hello.supports(.discover) else { throw ManagementError.capabilityMissing("catalog.discover") }
                let first = try await client.request(.discover, params: [
                    "market": .string("US"), "language": .string("en-US"), "limit": .integer(2), "cursor": .null
                ], timeout: .seconds(45)).decode(CatalogDiscovery.self)
                try first.validatePublicScope(market: "US", language: "en-US", limit: 2)
                check(!first.products.isEmpty, "Actual source-backed PC discovery is partial and entitlement remains unknown")
                guard let cursor = first.nextCursor else { throw ManagementError.invalidPayload }
                let second = try await client.request(.discover, params: [
                    "market": .string("US"), "language": .string("en-US"), "limit": .integer(2), "cursor": .string(cursor)
                ], timeout: .seconds(45)).decode(CatalogDiscovery.self)
                try second.validatePublicScope(market: "US", language: "en-US", limit: 2)
                check(second.corpusRevision == first.corpusRevision
                      && Set(first.products.map(\.id) + first.failures.map(\.id))
                        .isDisjoint(with: Set(second.products.map(\.id) + second.failures.map(\.id))),
                      "Actual discovery cursor advances with stable provenance and distinct identities")
                guard let product = first.products.first else { throw ManagementError.invalidPayload }
                let searched = try await client.request(.search, params: [
                    "query": .string(product.title), "market": .string("US"), "language": .string("en-US"),
                    "platform": .string("pc"), "limit": .integer(100), "cursor": .null
                ]).decode(CatalogSearch.self)
                check(searched.products.contains { $0.id == product.id },
                      "Actual checked-catalog title search resolves a source-backed discovered product")
            }
            check(await client.close(), "Actual owned engine exits before its state directory can be reused")
        } catch {
            check(await client.close(), "Actual failed probe still closes its owned engine")
            throw error
        }
    }

    func probeInspection(_ client: ManagementClient, configuration: BackendConfiguration) async throws {
        let files = FileManager.default
        let root = configuration.stateDirectory
            .appendingPathComponent("inspection-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer {
            do { try files.removeItem(at: root) }
            catch { check(false, "Owned synthetic inspection fixture cleanup") }
        }
        let selected = root.appendingPathComponent("selected")
        let missing = root.appendingPathComponent("missing")
        for directory in [selected, missing] {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        }
        // Original sanitized header, matching the pinned public producer's synthetic layout.
        var marker = Data(repeating: 0, count: 4096)
        marker.replaceSubrange(0x200..<0x208, with: Data("msft-xvd".utf8))
        marker[0x20c] = 2
        marker[0x22f] = 1
        marker[0x284] = 1
        marker[0x3ab] = 2
        marker[0x3bb] = 3
        for (offset, value) in [(0x3bc, 4), (0x3be, 3), (0x3c0, 2), (0x3c2, 1)] {
            marker[offset] = UInt8(value)
        }
        let markerURL = selected.appendingPathComponent(".xodus-streaming.msixvc")
        try marker.write(to: markerURL, options: .withoutOverwriting)
        let registryURL = configuration.stateDirectory.appendingPathComponent("management.json")
        let registryBefore = try Data(contentsOf: registryURL)
        let observed = try await client.request(.inspectInstallation,
            params: ["directory": .string(selected.path)]).decode(InstallationInspection.self)
        try observed.validateSelection(directory: selected.path)
        let metadata = Data(marker[0x200..<0x29c]) + Data(marker[0x39c..<0x3c4])
        let digest = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        check(metadata.count == 196 && observed.marker.observedMetadataSHA256 == digest
              && observed.marker.observedPackageVersion == "1.2.3.4",
              "Actual selected synthetic marker reads exactly the declared metadata digest/version")
        check(observed.marker.contentID == "00000000-0000-0000-0000-000000000001"
              && !observed.assessment.registered && !observed.assessment.launchable
              && observed.assessment.entitlement == "unknown",
              "Actual observed container ID remains unknown access and unregistered, never a retail game")
        check(try Data(contentsOf: markerURL) == marker && Data(contentsOf: registryURL) == registryBefore,
              "Actual inspection leaves selected marker and management registry bytes unchanged")
        let alias = root.appendingPathComponent("alias")
        try files.createSymbolicLink(at: alias, withDestinationURL: selected)
        for (directory, code) in [(missing, "NOT_FOUND"), (alias, "UNSUPPORTED_CONFIGURATION")] {
            do {
                _ = try await client.request(.inspectInstallation, params: ["directory": .string(directory.path)])
                check(false, "Actual inspection rejects synthetic \(code) without an installed success")
            } catch {
                check(error as? ManagementError == .backendError(code, retryable: false),
                      "Actual inspection rejects synthetic \(code) without an installed success")
            }
        }
        marker[0x200] = 0
        try marker.write(to: markerURL)
        do {
            _ = try await client.request(.inspectInstallation, params: ["directory": .string(selected.path)])
            check(false, "Actual malformed synthetic marker returns explicit integrity failure")
        } catch {
            check(error as? ManagementError == .backendError("INTEGRITY_FAILED", retryable: false),
                  "Actual malformed synthetic marker returns explicit integrity failure")
        }
        _ = try await client.request(.installed).decode(InstalledSnapshot.self)
        check(true, "Actual connection remains usable after selected-folder inspection failures")
    }

    func activityChecks(_ positive: [JSONValue]) throws {
        guard let fixtureEvent = positive.first(where: { $0["kind"]?.string == "event" }),
              var event = fixtureEvent.object, var job = fixtureEvent["data"]?.object else {
            throw ManagementError.invalidPayload
        }
        let session = fixtureEvent["sessionID"] ?? .string("fixture-session")
        let cancelledJob = JSONValue.object(job)
        job["state"] = .string("running")
        job["revision"] = .integer(1)
        job["error"] = .null
        let snapshot = try JSONValue.object(["sessionID": session, "watermark": .integer(1),
                                             "jobs": .array([.object(job)])]).decode(JobsSnapshot.self)
        var activity = ActivityStore()
        try activity.apply(snapshot)
        event["sequence"] = .integer(2)
        event["revision"] = .integer(2)
        var terminal = cancelledJob.object ?? [:]
        terminal["revision"] = .integer(2)
        event["data"] = .object(terminal)
        let value = try JSONValue.object(event).decode(ManagementEvent.self)
        try activity.beginSnapshot()
        try activity.apply(value)
        check(activity.watermark == 1 && activity.isReconciling, "Live event is fenced during snapshot request")
        try activity.apply(snapshot)
        check(activity.watermark == 2 && !activity.isReconciling,
              "Snapshot applies before buffered events above its watermark")
        try activity.apply(value)
        check(activity.jobs.first?.state == .cancelled && activity.watermark == 2, "Contiguous event updates activity")
        try activity.apply(value)
        check(activity.jobs.count == 1 && activity.watermark == 2, "Duplicate replay event is idempotent")
        event["sequence"] = .integer(4)
        try activity.apply(JSONValue.object(event).decode(ManagementEvent.self))
        check(activity.needsSnapshot && activity.watermark == 2, "Sequence gap requires authoritative snapshot")
        do {
            try activity.apply(snapshot)
            check(false, "Regressive snapshot watermark is rejected")
        } catch { check(true, "Regressive snapshot watermark is rejected") }
        activity = ActivityStore()
        try activity.apply(snapshot)
        event["sessionID"] = .string("fixture-new-session")
        try activity.apply(JSONValue.object(event).decode(ManagementEvent.self))
        check(activity.needsSnapshot, "Changed session requires authoritative snapshot")
        var duplicate = try snapshot.jobs.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        duplicate += duplicate
        do {
            let invalid = try JSONValue.object(["sessionID": session, "watermark": .integer(2),
                                                "jobs": .array(duplicate)]).decode(JobsSnapshot.self)
            try activity.apply(invalid)
            check(false, "Duplicate installation/activity identities fail closed")
        } catch { check(true, "Duplicate installation/activity identities fail closed") }
    }

    func mockConfiguration(_ scenario: String) -> BackendConfiguration {
        BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            stateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("XodusManagementChecks-\(UUID().uuidString)")
                .appendingPathComponent(scenario))
    }
}

enum MockBackend {
    static func run() -> Never {
        guard let index = CommandLine.arguments.firstIndex(of: "--state-dir"),
              CommandLine.arguments.indices.contains(index + 1) else { exit(2) }
        let scenario = URL(fileURLWithPath: CommandLine.arguments[index + 1]).lastPathComponent
        let fixtureAccountHash = String(repeating: "a", count: 64)
        do {
            let lifecycleDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let lifecycleScenario = ["retireslow", "retirefailed", "retirehello", "retiresnapshot", "authgate",
                                     "savedpermission", "startupquery", "uifailures",
                                     "statuspermission", "foregroundexpired", "deadlinecompleted", "discoverybounded",
                                     "discoveryhundreds"].contains(scenario) || scenario.hasPrefix("recent") || scenario.hasPrefix("ode")
            func trace(_ entry: String) throws {
                guard lifecycleScenario else { return }
                try FileManager.default.createDirectory(at: lifecycleDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = lifecycleDirectory.appendingPathComponent("lifecycle.log")
                let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
                guard descriptor >= 0 else { throw ManagementError.writeFailed }
                let bytes = Data("\(entry)\n".utf8)
                let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                let closed = Darwin.close(descriptor)
                guard written == bytes.count, closed == 0 else { throw ManagementError.writeFailed }
            }
            func authStatus(_ state: String) -> JSONValue {
                var value: [String: JSONValue] = [
                    "state": .string(state), "credentialStore": .string("macOSKeychain"),
                    "audience": .null, "expiresAt": .null, "entitlementAuthorized": .bool(false)
                ]
                if state == "credentialPresent" { value["accountHash"] = .string(fixtureAccountHash) }
                return .object(value)
            }
            try trace("started")
            let frames: [JSONValue]
            if scenario == "shippingpair" {
                frames = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
                    lifecycleDirectory.appendingPathComponent("positive.json"))).array ?? []
            } else {
                frames = try fixture("positive").array ?? []
            }
            var hello = frames.first(where: { $0["data"]?["schema"] != nil })?["data"]?.object ?? [:]
            var supported: Set<ManagementCommand> = [.authStatus, .authLogout, .jobs]
            if scenario.hasPrefix("descriptors") { supported.insert(.descriptors) }
            if scenario.hasPrefix("ode") { supported.insert(.odeAccountRead) }
            if scenario.hasPrefix("recent") { supported.formUnion([.libraryRecent, .query]) }
            if scenario == "verify" || scenario.hasPrefix("verify-") { supported.insert(.authVerify) }
            if scenario == "diagnostics" || scenario.hasPrefix("metrics") { supported.insert(.diagnostics) }
            if ["discoveryfail", "discoveryrecover", "discoverypcflag", "discoveryrefresh",
                "discoveryhundreds", "discoveryrepeatedpage", "discoverybounded",
                "discoverypartialretry", "discoveryretryfailure"].contains(scenario) { supported.insert(.discover) }
            if ["querybudget", "querysourcewarning", "querysourcefailed", "queryfail", "badqueryfail", "queryempty", "queryslow", "querynodetails",
                "querynulldetails", "querycoalesce", "querypagination", "queryrefreshfailure",
                "startupquery", "publiccapture", "uifailures", "discoverypcflag"].contains(scenario) { supported.insert(.query) }
            if scenario == "startupquery" { supported.insert(.search) }
            if ["publiccapture", "registryempty", "registryunavailable", "uifailures"].contains(scenario) {
                supported.insert(.installed)
            }
            if ["inspection", "inspectionmissing", "inspectionmismatch"].contains(scenario) {
                supported.insert(.inspectInstallation)
            }
            if ["expired", "expiredpermission", "savedpermission", "welcomeretry", "transientauth", "latecancel", "humanwait", "hangmutation", "beginfail", "statuspermission", "deadlinecompleted",
                "failedflow", "failedflownocode", "authgate", "recentbootstrapsignedout"].contains(scenario) || scenario.hasPrefix("failedstage-") {
                supported.formUnion([.authBegin, .authCancel])
            }
            var loggedOut = false, flowStarted = false, cancelledLate = false
            var catalogQueryReads = 0
            var descriptorReads = 0
            var flowReads = 0, discoveryReads = 0, profileReads = 0
            var activityReads = 0, registryReads = 0
            var recentReads = 0, accountLibraryReads = 0
            var metricSequence = 1
            var gatedAttempts = 0
            hello["capabilities"] = .array(ManagementCommand.allCases.map { command in .object([
                "command": .string(command.rawValue), "supported": .bool(supported.contains(command)),
                "audience": command == .libraryRecent ? .string("http://xboxlive.com") : .null,
                "reason": supported.contains(command) ? .null : .string("Fixture gate.")
            ]) })
            while let line = readLine() {
                let request = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                let command = request["command"]?.string ?? ""
                if command == "hello" {
                    if scenario.hasPrefix("metrics"), ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_METRICS"] == "1" {
                        try FileHandle.standardError.write(contentsOf:
                            Data("Ode descriptor metrics v1 enabled seq=1 budget=65536\n".utf8))
                    }
                    if scenario == "welcomeretry" {
                        let marker = lifecycleDirectory.appendingPathComponent("hello-rejected")
                        if !FileManager.default.fileExists(atPath: marker.path) {
                            try FileManager.default.createDirectory(at: lifecycleDirectory,
                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            try Data("Neutral one-time hello rejection.".utf8).write(to: marker)
                            var rejected = result(request, data: .object(hello))
                            rejected["protocol"] = .object(["major": .integer(2), "minor": .integer(0)])
                            try emit(.object(rejected))
                            continue
                        }
                    }
                    if scenario == "retirehello" {
                        try trace("hello.wait")
                        Thread.sleep(forTimeInterval: 0.4)
                    }
                    if scenario == "prompt" { print("Synthetic interactive prompt"); fflush(stdout); continue }
                    if scenario == "oversize" { print(String(repeating: "x", count: JSONLineFramer.maximumBytes + 1)); fflush(stdout); continue }
                    if scenario == "partial" { FileHandle.standardOutput.write(Data("{\"kind\":".utf8)); exit(0) }
                    var result = result(request, data: .object(hello))
                    if scenario == "mismatch" { result["protocol"] = .object(["major": .integer(2), "minor": .integer(0)]) }
                    try emit(.object(result))
                } else {
                    if scenario == "metricsbarrier", command == ManagementCommand.jobs.rawValue {
                        activityReads += 1
                        usleep(100_000)
                    }
                    if scenario.hasPrefix("metricsbusy"), command == ManagementCommand.jobs.rawValue { continue }
                    if scenario.hasPrefix("metrics"), command == ManagementCommand.diagnostics.rawValue {
                        if scenario == "metricsdrainfail" {
                            try emitFailure(request, code: "NETWORK_UNAVAILABLE")
                            continue
                        }
                        let marker = Data("Ode descriptor metrics v1 checkpoint seq=\(metricSequence + 1)\n".utf8)
                        if scenario == "metricsearly" { try FileHandle.standardError.write(contentsOf: marker) }
                        guard let diagnostic = frames.first(where: { $0["data"]?["reportVersion"] != nil })?["data"] else {
                            throw ManagementError.invalidPayload
                        }
                        try emit(.object(result(request, data: diagnostic)))
                        if scenario == "metricslate" || scenario == "metricsstale" { usleep(100_000) }
                        if scenario != "metricsearly",
                           scenario != "metricsbarrier" || activityReads == 1,
                           !["metricsmissing", "metricsstale"].contains(scenario) || metricSequence == 1 {
                            try FileHandle.standardError.write(contentsOf: marker)
                        }
                        metricSequence += 1
                        continue
                    }
                    if scenario == "requestpressure", command == ManagementCommand.jobs.rawValue { continue }
                    if scenario == "diagnosticlifetime", command == ManagementCommand.jobs.rawValue {
                        for _ in 0..<257 {
                            try FileHandle.standardError.write(contentsOf: Data(repeating: 10, count: 4096))
                            usleep(2_000)
                        }
                    }
                    if scenario.hasPrefix("ode") {
                        try trace(command)
                        if command == "auth.status" {
                            try emit(.object(result(request, data: authStatus(loggedOut ? "signedOut" : "credentialPresent"))))
                            continue
                        }
                        if command == "ode.account.read.v1" {
                            let section = request["params"]?["section"]?.string ?? ""
                            if section == "library" { accountLibraryReads += 1 }
                            let warm = scenario.hasPrefix("odelibrary")
                            if warm, accountLibraryReads > 1 { Thread.sleep(forTimeInterval: 0.15) }
                            if scenario == "odefailure"
                                || (scenario == "odelibraryfailure" && accountLibraryReads > 1) {
                                let failure = AuthenticatedReadFailure.authRejected
                                var response = result(request, data: .null)
                                response["ok"] = .bool(false)
                                response.removeValue(forKey: "data")
                                response["error"] = .object(["code": .string(failure.code),
                                    "message": .string(failure.message), "retryable": .bool(failure.retryable),
                                    "details": failure.details])
                                try emit(.object(response))
                                continue
                            }
                            let items: [JSONValue] = warm
                                && !(scenario == "odelibraryempty" && accountLibraryReads > 1)
                                ? [.object(["productID": .string("FIXTURE00001"), "acquisitionKind": .string("purchased")])] : []
                            let payload: JSONValue
                            if section == "license" {
                                payload = .object([
                                    "productID": request["params"]?["productID"] ?? .null,
                                    "access": .string("permitted"), "expiresAt": .string("2030-01-01T00:00:00Z"),
                                    "reason": .null
                                ])
                            } else {
                                payload = section == "library" ? .object(["items": .array(items)])
                                    : .object(["gamertag": .string("Fixture"), "displayName": .null,
                                        "avatarURL": .null, "gamerscore": .integer(42), "bio": .null, "location": .null])
                            }
                            let response = result(request, data: .object([
                                "section": .string(section),
                                "accountHash": .string(String(repeating: scenario == "odemismatch" ? "b" : "a", count: 64)),
                                "checkedAt": .string("2026-10-19T12:00:00Z"), "payload": payload
                            ]))
                            if scenario == "odeslow" {
                                DispatchQueue.global().async {
                                    Thread.sleep(forTimeInterval: 0.3)
                                    do { try emit(.object(response)) } catch { exit(3) }
                                }
                            } else { try emit(.object(response)) }
                            continue
                        }
                    }
                    if scenario.hasPrefix("recent") {
                        try trace(command)
                        if command == "auth.status" {
                            profileReads += 1
                            if scenario == "recentbootstrapstatusfailure", profileReads == 1 {
                                try emitFailure(request, code: "AUTH_INVALID", category: "credentialStoreUnavailable")
                                continue
                            }
                            let state = loggedOut ? "signedOut"
                                : scenario == "recentbootstrapsignedout" ? "signedOut"
                                : scenario == "recentbootstrapexpired" ? "expired"
                                : scenario == "recentbootstrapinvalid" ? "invalid" : "credentialPresent"
                            let response = result(request, data: authStatus(state))
                            if (scenario == "recentstatusslow" && profileReads > 1)
                                || scenario == "recentbootstrapstatusslow" {
                                DispatchQueue.global().async {
                                    Thread.sleep(forTimeInterval: 0.5)
                                    do { try emit(.object(response)) } catch { exit(3) }
                                }
                            } else { try emit(.object(response)) }
                            continue
                        }
                        if command == "auth.logout" { loggedOut = true }
                        if command == "library.recent" {
                            recentReads += 1
                            if (recentReads > 1 && ["recentstale", "recentprofilechanged"].contains(scenario))
                                || (recentReads == 1 && scenario == "recentbootstraptransport") {
                                let stage: RecentLibraryFailure = scenario == "recentprofilechanged" ? .profileChanged : .transportFailed
                                var response = result(request, data: .null)
                                response["ok"] = .bool(false)
                                response.removeValue(forKey: "data")
                                response["error"] = .object([
                                    "code": .string(stage.code), "message": .string(stage.message),
                                    "retryable": .bool(stage.retryable), "details": stage.details
                                ])
                                try emit(.object(response))
                            } else {
                                guard var page = frames.first(where: {
                                    $0["data"]?["scope"]?.string == "recentlyPlayed"
                                        && $0["data"]?["titles"]?.array?.isEmpty == ["recentzero", "recentbootstrapzero"].contains(scenario)
                                })?["data"] else { exit(3) }
                                if scenario.hasPrefix("recentsemantics"),
                                   var data = page.object, var title = data["titles"]?.array?.first?.object {
                                    title["platform"] = .string(String(scenario.dropFirst("recentsemantics".count)))
                                    data["titles"] = .array([.object(title)])
                                    page = .object(data)
                                }
                                let response = result(request, data: page)
                                if ["recentslow", "recentbootstrapretire"].contains(scenario) {
                                    DispatchQueue.global().async {
                                        Thread.sleep(forTimeInterval: 0.6)
                                        do { try emit(.object(response)) } catch { exit(3) }
                                    }
                                } else { try emit(.object(response)) }
                            }
                            continue
                        }
                        if command == "catalog.query" {
                            if scenario == "recentstorefailure" {
                                guard var response = frames.first(where: {
                                    $0["error"]?["details"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                })?.object, var error = response["error"]?.object,
                                      var details = error["details"]?.object else { exit(3) }
                                response["requestID"] = request["requestID"]
                                details["query"] = request["params"]?["query"]
                                error["details"] = .object(details)
                                response["error"] = .object(error)
                                try emit(.object(response))
                                continue
                            }
                            if scenario == "recentstoreempty" {
                                guard var page = frames.first(where: {
                                    $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                        && $0["data"]?["products"]?.array?.isEmpty == true
                                })?["data"]?.object else { exit(3) }
                                page["query"] = request["params"]?["query"]
                                try emit(.object(result(request, data: .object(page))))
                                continue
                            }
                            guard var page = frames.first(where: {
                                $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                    && $0["data"]?["products"]?.array?.isEmpty == false
                            })?["data"]?.object, var product = page["products"]?.array?.first?.object else { exit(3) }
                            page["query"] = request["params"]?["query"]
                            product["source"] = .string("syntheticPublicSource")
                            page["products"] = .array([.object(product)])
                            page["failures"] = .array([])
                            try emit(.object(result(request, data: .object(page))))
                            continue
                        }
                    }
                    if command == "auth.verify", scenario == "verify" || scenario.hasPrefix("verify-") {
                        if scenario == "verify" {
                            try emit(.object(result(request, data: .object(["verified": .bool(true)]))))
                        } else {
                            guard let stage = AuthenticatedReadFailure(rawValue: String(scenario.dropFirst(7))) else { exit(3) }
                            var response = result(request, data: .null)
                            response["ok"] = .bool(false)
                            response.removeValue(forKey: "data")
                            response["error"] = .object(["code": .string(stage.code),
                                "retryable": .bool(stage.retryable), "message": .string(stage.message),
                                "details": stage.details])
                            try emit(.object(response))
                        }
                        continue
                    }
                    if ["savedpermission", "startupquery", "uifailures", "statuspermission", "foregroundexpired",
                        "discoveryhundreds", "discoverybounded"].contains(scenario) { try trace(command) }
                    if scenario == "foregroundexpired", command == "auth.status" {
                        profileReads += 1
                        try emit(.object(result(request, data: authStatus(
                            profileReads == 1 ? "credentialPresent" : "expired"))))
                        continue
                    }
                    if scenario == "statuspermission", command == "auth.status" {
                        let response = result(request, data: authStatus("credentialPresent"))
                        DispatchQueue.global().async {
                            Thread.sleep(forTimeInterval: 0.5)
                            do { try emit(.object(response)) } catch { exit(3) }
                        }
                        continue
                    }
                    if scenario == "uifailures" {
                        if command == "auth.status" {
                            profileReads += 1
                            if profileReads == 2 {
                                try emitFailure(request, code: "AUTH_INVALID", category: "credentialStoreUnavailable")
                            } else {
                                let status = frames.first { $0["data"]?["state"]?.string == "credentialPresent" }?["data"]
                                guard let status else { exit(3) }
                                try emit(.object(result(request, data: status)))
                            }
                            continue
                        }
                        if command == "auth.logout" {
                            try emitFailure(request, code: "INTERNAL_ERROR")
                            continue
                        }
                        if command == "catalog.query" {
                            try emitFailure(request, code: "PACKAGE_UNAVAILABLE")
                            continue
                        }
                        if command == "jobs.snapshot" {
                            activityReads += 1
                            if activityReads == 2 { try emitFailure(request, code: "NETWORK_UNAVAILABLE") }
                            else {
                                try emit(.object(result(request, data: .object([
                                    "sessionID": .string("fixture-session"), "watermark": .integer(0), "jobs": .array([])
                                ]))))
                            }
                            continue
                        }
                    }
                    if scenario == "startupquery", command == "jobs.snapshot" {
                        let response = result(request, data: .object([
                            "sessionID": .string("fixture-session"), "watermark": .integer(0), "jobs": .array([])
                        ]))
                        DispatchQueue.global().async {
                            Thread.sleep(forTimeInterval: 0.6)
                            do { try emit(.object(response)) } catch { exit(3) }
                        }
                        continue
                    }
                    if scenario == "startupquery", command == "catalog.query" {
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                && $0["data"]?["products"]?.array?.isEmpty == false
                        })?["data"]?.object, var product = page["products"]?.array?.first?.object else { exit(3) }
                        product["title"] = request["params"]?["query"]
                        product["source"] = .string("syntheticPublicSource")
                        page["query"] = request["params"]?["query"]
                        page["products"] = .array([.object(product)])
                        page["failures"] = .array([])
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if (["failedflow", "failedflownocode"].contains(scenario) || scenario.hasPrefix("failedstage-")),
                       command == "auth.begin" {
                        var failureObject: [String: JSONValue] = [
                            "code": .string("AUTH_INVALID"), "retryable": .bool(false),
                            "message": .string("Original synthetic upstream wording must not enter the app summary.")
                        ]
                        if scenario.hasPrefix("failedstage-") {
                            let suffix = String(scenario.dropFirst("failedstage-".count))
                            if let diagnostic = NativeConsentFailure(rawValue: suffix) {
                                failureObject["details"] = diagnostic.details
                            } else {
                                let parts = suffix.split(separator: "-", maxSplits: 1).map(String.init)
                                let diagnostic: NativeConsentFailure
                                let variant: String
                                if parts.count == 2, let subsite = NativeConsentFailure(rawValue: parts[0]) {
                                    diagnostic = subsite
                                    variant = parts[1]
                                } else {
                                    diagnostic = .pipelineFailed
                                    variant = suffix
                                }
                                var details = diagnostic.details.object ?? [:]
                                switch variant {
                                case "extra": details["secret"] = .string("Original extra-field sentinel")
                                case "unknown": details["reason"] = .string("unrecognizedReason")
                                case "mismatched": details["stage"] = .string("storeProof")
                                case "cancelcode": failureObject["code"] = .string("AUTH_CANCELLED")
                                case "expirycode": failureObject["code"] = .string("AUTH_EXPIRED")
                                case "internalcode": failureObject["code"] = .string("INTERNAL_ERROR")
                                case "malformed": details["reason"] = .integer(1)
                                case "category": details["category"] = .string("unrecognizedCategory")
                                case "missing": details.removeValue(forKey: "stage")
                                default: exit(3)
                                }
                                failureObject["details"] = .object(details)
                            }
                        }
                        let failure: JSONValue = scenario == "failedflownocode" ? .null : .object(failureObject)
                        try emit(.object(result(request, data: .object([
                            "state": .string("signedOut"), "credentialStore": .string("macOSKeychain"),
                            "audience": .null, "expiresAt": .null, "entitlementAuthorized": .bool(false),
                            "flow": .object(["flowID": .string("fixture-failed-flow"),
                                             "state": .string("failed"), "error": failure])
                        ]))))
                        continue
                    }
                    if scenario == "authgate", command.hasPrefix("auth.") {
                        if command == "auth.status" { try trace("auth.status") }
                        var flowState = "pending"
                        let windowClosedMarker = lifecycleDirectory.appendingPathComponent("native-window-closed")
                        if command == "auth.begin" {
                            flowStarted = true
                            gatedAttempts += 1
                            if FileManager.default.fileExists(atPath: windowClosedMarker.path) {
                                try FileManager.default.removeItem(at: windowClosedMarker)
                            }
                            try trace("auth.begin")
                        }
                        let windowClosed = FileManager.default.fileExists(atPath: windowClosedMarker.path)
                        if windowClosed { flowStarted = false; flowState = "cancelled" }
                        if command == "auth.cancel" { flowStarted = false; flowState = "cancelled"; try trace("auth.cancel") }
                        var status: [String: JSONValue] = [
                            "state": .string("signedOut"), "credentialStore": .string("macOSKeychain"),
                            "audience": .null, "expiresAt": .null, "entitlementAuthorized": .bool(false)
                        ]
                        if flowStarted || command == "auth.cancel" || windowClosed {
                            status["flow"] = .object(["flowID": .string("fixture-gated-flow-\(gatedAttempts)"),
                                "state": .string(flowState), "error": .null])
                        }
                        let response = result(request, data: .object(status))
                        if ["auth.begin", "auth.cancel"].contains(command) {
                            DispatchQueue.global().async {
                                Thread.sleep(forTimeInterval: 0.4)
                                do { try emit(.object(response)) }
                                catch { exit(3) }
                            }
                        } else { try emit(.object(response)) }
                        continue
                    }
                    if scenario == "publiccapture", command == "catalog.query" {
                        guard let page = try fixture("public-halo-query")["data"] else { exit(3) }
                        try emit(.object(result(request, data: page)))
                        continue
                    }
                    if command == "installed.snapshot",
                       ["publiccapture", "registryempty", "registryunavailable", "uifailures"].contains(scenario) {
                        registryReads += 1
                        if scenario == "registryunavailable" || scenario == "uifailures" && registryReads > 1 {
                            try emitFailure(request, code: "NETWORK_UNAVAILABLE")
                        } else {
                            guard var registry = frames.first(where: {
                                $0["data"]?["installations"]?.array != nil
                            })?["data"]?.object else { exit(3) }
                            registry["installations"] = .array([])
                            try emit(.object(result(request, data: .object(registry))))
                        }
                        continue
                    }
                    if scenario.hasPrefix("descriptors"), command == "catalog.descriptors" {
                        descriptorReads += 1
                        if scenario.hasPrefix("descriptorscommand") {
                            if scenario == "descriptorscommandmalformed" {
                                try emit(.object(result(request, data: .object([:]))))
                                continue
                            }
                            if descriptorReads < 3 || scenario != "descriptorscommandretry" {
                                var frame = result(request, data: .null)
                                frame.removeValue(forKey: "data")
                                frame["ok"] = .bool(false)
                                frame["error"] = .object([
                                    "code": .string(scenario == "descriptorscommandauth"
                                        ? "AUTH_INVALID" : "NETWORK_UNAVAILABLE"),
                                    "message": .string("Synthetic descriptor command failure."),
                                    "retryable": .bool(scenario != "descriptorscommandpermanent")
                                ])
                                try emit(.object(frame))
                                continue
                            }
                        }
                        let params = request["params"] ?? .null
                        let ids = params["productIDs"]?.array?.compactMap(\.string) ?? []
                        let timestamp = ISO8601DateFormatter()
                        let now = Date().addingTimeInterval(params["refresh"]?.string == "network" ? 0 : -240)
                        if scenario == "descriptorssplitfailure", ids == ["9DESC0000002"] {
                            try emitFailure(request, code: "NETWORK_UNAVAILABLE")
                            continue
                        }
                        let recovering = ["descriptorsretry", "descriptorscapacity", "descriptorsauth",
                                          "descriptorsretryexhausted"].contains(scenario)
                        if recovering, descriptorReads > 1, ids != ["9DESC0000002"] { exit(3) }
                        let failed = recovering && (descriptorReads < 3 || scenario == "descriptorsauth"
                            || scenario == "descriptorsretryexhausted")
                            ? ids.filter { $0 == "9DESC0000002" }
                            : scenario == "descriptorsoversized" ? ids
                            : scenario == "descriptorssplitfailure" && ids.count > 1 ? Array(ids.dropFirst()) : []
                        let records = ids.filter { !failed.contains($0) }.map { id -> JSONValue in
                            .object([
                                "productID": .string(id), "market": params["market"] ?? .null,
                                "language": params["language"] ?? .null,
                                "checkedAt": .string(timestamp.string(from: now)),
                                "expiresAt": .string(timestamp.string(from: now.addingTimeInterval(300))),
                                "freshness": .string("cached"),
                                "product": .object([
                                    "ProductId": .string(id), "ProductType": .string("Game"),
                                    "ProductKind": .string("Game"),
                                    "LocalizedProperties": .array([.object([
                                        "ProductTitle": .string("Synthetic managed game"), "Images": .array([]),
                                        "ProductDescription": .string("Managed public descriptor.")
                                    ])]),
                                    "DisplaySkuAvailabilities": .array([.object([
                                        "Sku": .object([
                                            "SkuId": .string("synthetic"),
                                            "Properties": .object(["Packages": .array([.object([
                                                "PlatformDependencies": .array([.object([
                                                    "PlatformName": .string("Windows.Desktop")
                                                ])])
                                            ])])])
                                        ]),
                                        "Availabilities": .array([])
                                    ])])
                                ])
                            ])
                        }
                        let failures = failed.map { id -> JSONValue in
                            .object(["productID": .string(id), "error": .object([
                                "code": .string(["descriptorsretry", "descriptorsretryexhausted"].contains(scenario)
                                    ? "NETWORK_UNAVAILABLE"
                                    : scenario == "descriptorsauth" ? "AUTH_INVALID" : "LIMIT_EXCEEDED"),
                                "message": .string("Synthetic public descriptor failure"),
                                "retryable": .bool(recovering)
                            ])])
                        }
                        try emit(.object(result(request, data: .object([
                            "descriptors": .array(records), "failures": .array(failures)
                        ]))))
                        continue
                    }
                    if ["querybudget", "querysourcewarning", "querysourcefailed"].contains(scenario),
                       command == "catalog.query" {
                        catalogQueryReads += 1
                        let params = request["params"] ?? .null
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                && $0["data"]?["products"]?.array?.isEmpty == false
                        })?["data"]?.object else { exit(3) }
                        page["query"] = params["query"]
                        page["source"] = .string("XboxComSearch+MicrosoftStoreEdge:v9.0/searchResults")
                        page["failures"] = .array([])
                        page["nextCursor"] = .null
                        page["products"] = .array((page["products"]?.array ?? []).prefix(1).map {
                            var value = $0.object ?? [:]
                            value["market"] = params["market"]
                            value["language"] = params["language"]
                            value["resolvedLanguage"] = .string("neutral")
                            value["source"] = .string("syntheticPublicSource")
                            return .object(value)
                        })
                        if scenario != "querybudget", params["query"] == .string("Forza") {
                            page["sourceFailure"] = .object([
                                "code": .string("PACKAGE_UNAVAILABLE"),
                                "message": .string("One public source returned a non-search page."),
                                "retryable": .bool(false)
                            ])
                        }
                        if scenario == "querysourcefailed" || (scenario == "querybudget" && catalogQueryReads == 1) {
                            page["products"] = .array([])
                            page["failures"] = .array((0..<(scenario == "querybudget" ? 16 : 1)).map { index in
                                .object(["productID": .string(String(format: "9REJ%08d", index)),
                                    "error": .object(["code": .string("PACKAGE_UNAVAILABLE"),
                                        "message": .string("Synthetic non-PC candidate."),
                                        "retryable": .bool(false)])])
                            })
                            if scenario == "querybudget" { page["nextCursor"] = .string("q1-aa") }
                            var response = result(request, data: .null)
                            response.removeValue(forKey: "data")
                            response["ok"] = .bool(false)
                            response["error"] = .object(["code": .string("PACKAGE_UNAVAILABLE"),
                                "message": .string("No PC games in this candidate page."),
                                "retryable": .bool(false), "details": .object(page)])
                            try emit(.object(response))
                        } else {
                            if scenario == "querybudget", params["cursor"] != .string("q1-aa") { exit(3) }
                            try emit(.object(result(request, data: .object(page))))
                        }
                        continue
                    }
                    if scenario == "querynodetails", command == "catalog.query" {
                        try emitFailure(request, code: "PACKAGE_UNAVAILABLE")
                        continue
                    }
                    if scenario == "queryrefreshfailure", command == "catalog.query" {
                        catalogQueryReads += 1
                        if catalogQueryReads == 2 {
                            try emitFailure(request, code: "NETWORK_UNAVAILABLE")
                            continue
                        }
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                && $0["data"]?["products"]?.array?.isEmpty == false
                        })?["data"]?.object, var product = page["products"]?.array?.first?.object else { exit(3) }
                        let params = request["params"] ?? .null
                        product["source"] = .string("syntheticPublicSource")
                        product["market"] = params["market"]
                        product["language"] = params["language"]
                        product["resolvedLanguage"] = params["language"]
                        page["query"] = params["query"]
                        page["products"] = .array([.object(product)])
                        page["failures"] = .array([])
                        page["nextCursor"] = .null
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if scenario == "querynulldetails", command == "catalog.query" {
                        var response = result(request, data: .null)
                        response.removeValue(forKey: "data")
                        response["ok"] = .bool(false)
                        response["error"] = .object(["code": .string("PACKAGE_UNAVAILABLE"),
                            "message": .string("Synthetic source failure."), "retryable": .bool(false), "details": .null])
                        try emit(.object(response))
                        continue
                    }
                    if ["querycoalesce", "querypagination"].contains(scenario), command == "catalog.query" {
                        guard queryCounters.started() else {
                            queryCounters.finished()
                            try emitFailure(request, code: "LIMIT_EXCEEDED")
                            continue
                        }
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                && $0["data"]?["products"]?.array?.isEmpty == false
                        })?["data"]?.object, var product = page["products"]?.array?.first?.object else { exit(3) }
                        let params = request["params"] ?? .null
                        product["source"] = .string("syntheticPublicSource")
                        product["market"] = params["market"]
                        product["language"] = params["language"]
                        product["resolvedLanguage"] = params["language"]
                        page["query"] = params["query"]
                        page["failures"] = .array([])
                        let fixtureCursor = page["nextCursor"]
                        page["nextCursor"] = .null
                        if scenario == "querypagination" {
                            if params["cursor"]?.string == nil {
                                page["nextCursor"] = fixtureCursor
                            } else {
                                product["productID"] = .string("FIXTUREPAGE2")
                                product["editions"] = .array([])
                            }
                        }
                        let basePage = page, baseProduct = product
                        DispatchQueue.global().async {
                            Thread.sleep(forTimeInterval: 2)
                            queryCounters.finished()
                            let counts = queryCounters.snapshot()
                            var responsePage = basePage, responseProduct = baseProduct
                            responseProduct["title"] = .string("\(params["query"]?.string ?? "") [requests=\(counts.issued),max=\(counts.maximum)]")
                            responsePage["products"] = .array([.object(responseProduct)])
                            do { try emit(.object(result(request, data: .object(responsePage)))) }
                            catch { exit(3) }
                        }
                        continue
                    }
                    if ["inspection", "inspectionmissing", "inspectionmismatch"].contains(scenario),
                       command == "installed.inspect" {
                        if scenario == "inspectionmissing" {
                            try emitFailure(request, code: "NOT_FOUND")
                        } else {
                            guard var inspection = frames.first(where: {
                                $0["data"]?["scope"]?.string == "userSelectedDirectory"
                            })?["data"]?.object else { exit(3) }
                            inspection["directory"] = scenario == "inspectionmismatch"
                                ? .string("/different/selected/folder") : request["params"]?["directory"]
                            try emit(.object(result(request, data: .object(inspection))))
                        }
                        continue
                    }
                    if scenario == "beginfail", command == "auth.begin" {
                        try emitFailure(request, code: "AUTH_INVALID",
                                        message: "Original preparation upstream sentinel must not enter local UI.")
                        continue
                    }
                    if ["expired", "expiredpermission", "savedpermission", "transientauth", "latecancel", "deadlinecompleted"].contains(scenario) {
                        if command == "auth.begin" { flowStarted = true; flowReads = 0 }
                        if command == "auth.logout" { loggedOut = true; flowStarted = false }
                        if command == "auth.cancel", scenario == "latecancel" {
                            cancelledLate = true
                            try emitFailure(request, code: "INVALID_TRANSITION")
                            continue
                        }
                        if command.hasPrefix("auth.") {
                            if command == "auth.status", ["expiredpermission", "savedpermission"].contains(scenario) {
                                profileReads += 1
                                if profileReads == 2 {
                                    try emitFailure(request, code: "AUTH_INVALID", category: "credentialStoreUnavailable")
                                    continue
                                }
                            }
                            if command == "auth.status", flowStarted {
                                flowReads += 1
                                if scenario == "transientauth", flowReads == 1 {
                                    try emitFailure(request, code: "AUTH_INVALID", category: "credentialStoreUnavailable")
                                    continue
                                }
                            }
                            let completed = flowStarted && command == "auth.status"
                                && (scenario != "latecancel" || cancelledLate)
                            var status: [String: JSONValue] = [
                                "state": .string(completed || (scenario == "savedpermission" && !loggedOut) ? "credentialPresent"
                                    : ["expired", "expiredpermission"].contains(scenario) && !loggedOut && !flowStarted
                                        ? "expired" : "signedOut"),
                                "credentialStore": .string("macOSKeychain"), "audience": .null,
                                "expiresAt": .null, "entitlementAuthorized": .bool(false)
                            ]
                            if flowStarted {
                                status["flow"] = .object(["flowID": .string("fixture-native-flow"),
                                    "state": .string(completed ? "completed" : "pending"), "error": .null])
                            }
                            if status["state"]?.string == "credentialPresent" {
                                status["accountHash"] = .string(fixtureAccountHash)
                            }
                            try emit(.object(result(request, data: .object(status))))
                            continue
                        }
                    }
                    if ["humanwait", "hangmutation"].contains(scenario),
                       ["auth.begin", "auth.logout", "auth.status"].contains(command) {
                        if scenario == "humanwait" {
                            let response = result(request, data: .object([
                                "state": .string("signedOut"), "credentialStore": .string("macOSKeychain"),
                                "audience": .null, "expiresAt": .null, "entitlementAuthorized": .bool(false)
                            ]))
                            DispatchQueue.global().async {
                                Thread.sleep(forTimeInterval: 31)
                                do { try emit(.object(response)) }
                                catch { exit(3) }
                            }
                        }
                        continue
                    }
                    if ["discoveryhundreds", "discoveryrepeatedpage", "discoverybounded", "discoveryretryfailure"].contains(scenario),
                       command == "catalog.discover" {
                        discoveryReads += 1
                        if scenario == "discoveryretryfailure", discoveryReads == 3 {
                            guard request["params"]?["cursor"] == .null else { exit(3) }
                            try emitFailure(request, code: "NETWORK_UNAVAILABLE",
                                message: "Synthetic retry failure without page details")
                            continue
                        }
                        guard request["params"]?["limit"]?.uint64 == 16,
                              var page = frames.first(where: {
                                  $0["data"]?["corpus"]?.string == "pcGamePassDiscovery"
                              })?["data"]?.object,
                              let template = page["products"]?.array?.first?.object,
                              let revision = page["corpusRevision"]?.string else { exit(3) }
                        let prefix = "d1-\(revision)-"
                        let cursor = request["params"]?["cursor"]?.string
                        let start: Int
                        if let cursor {
                            guard cursor.hasPrefix(prefix),
                                  let offset = Int(cursor.dropFirst(prefix.count)) else { exit(3) }
                            start = offset
                        } else { start = 0 }
                        let total = scenario == "discoverybounded" ? 528 : 300
                        guard start >= 0 && start < total else { exit(3) }
                        let end = min(start + 16, total)
                        page["products"] = .array((start..<end).map { index in
                            let id = String(format: "NEUTRAL%05d", index)
                            var item = template
                            item["productID"] = .string(id)
                            item["title"] = .string("Neutral PC game \(index)")
                            item["source"] = .string("syntheticPublicSource")
                            item["pcCatalogCandidate"] = .bool(true)
                            item["artwork"] = .array([])
                            item["artworkStatus"] = .string("absent")
                            item["editions"] = .array((item["editions"]?.array ?? []).map { edition in
                                var value = edition.object ?? [:]
                                value["productID"] = .string(id)
                                return .object(value)
                            })
                            return .object(item)
                        })
                        page["failures"] = .array([])
                        let next = scenario == "discoveryrepeatedpage" && start > 0 ? start : end
                        page["nextCursor"] = next < total ? .string("\(prefix)\(next)") : .null
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if scenario == "discoverypartialretry", command == "catalog.discover" {
                        discoveryReads += 1
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "pcGamePassDiscovery"
                        })?["data"]?.object,
                              let template = page["products"]?.array?.first?.object else { exit(3) }
                        let range = discoveryReads == 1 ? 0..<6 : 6..<7
                        page["products"] = .array(range.map { index in
                            let id = String(format: "RETRY%07d", index)
                            var item = template
                            item["productID"] = .string(id)
                            item["title"] = .string("Synthetic retry game \(index)")
                            item["source"] = .string("syntheticPublicSource")
                            item["pcCatalogCandidate"] = .bool(true)
                            item["editions"] = .array((item["editions"]?.array ?? []).map { edition in
                                var value = edition.object ?? [:]
                                value["productID"] = .string(id)
                                return .object(value)
                            })
                            return .object(item)
                        })
                        page["failures"] = .array([.object([
                            "productID": .string("RETRY9999999"), "error": .object([
                                "code": .string("NETWORK_UNAVAILABLE"), "message": .string("Synthetic partial failure"),
                                "retryable": .bool(true)
                            ])
                        ])])
                        page["nextCursor"] = .string("d1-\(page["corpusRevision"]?.string ?? "")-16")
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if scenario == "discoveryrefresh", command == "catalog.discover" {
                        discoveryReads += 1
                        if discoveryReads == 1 {
                            guard var page = frames.first(where: {
                                $0["data"]?["corpus"]?.string == "pcGamePassDiscovery"
                            })?["data"]?.object else { exit(3) }
                            page["products"] = .array((page["products"]?.array ?? []).map { product in
                                var value = product.object ?? [:]
                                value["source"] = .string("syntheticPublicSource")
                                value["pcCatalogCandidate"] = .bool(true)
                                return .object(value)
                            })
                            page["failures"] = .array([])
                            page["nextCursor"] = .null
                            try emit(.object(result(request, data: .object(page))))
                        } else {
                            guard var response = frames.first(where: {
                                $0["error"]?["details"]?["corpus"]?.string == "pcGamePassDiscovery"
                            })?.object else { exit(3) }
                            response["requestID"] = request["requestID"]
                            try emit(.object(response))
                        }
                        continue
                    }
                    if scenario == "discoverypcflag", command == "catalog.discover" {
                        guard request["params"]?["limit"]?.uint64 == 16,
                              var page = frames.first(where: {
                                  $0["data"]?["corpus"]?.string == "pcGamePassDiscovery"
                              })?["data"]?.object else { exit(3) }
                        page["products"] = .array((page["products"]?.array ?? []).map { product in
                            var value = product.object ?? [:]
                            value["source"] = .string("syntheticPublicSource")
                            value["pcCatalogCandidate"] = .bool(false)
                            return .object(value)
                        })
                        page["failures"] = .array([])
                        page["nextCursor"] = .null
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if scenario == "discoveryrecover", command == "catalog.discover" {
                        discoveryReads += 1
                        guard let failedPage = frames.first(where: {
                            $0["error"]?["details"]?["corpus"]?.string == "pcGamePassDiscovery"
                        }) else { exit(3) }
                        if discoveryReads == 1 {
                            guard var response = failedPage.object else { exit(3) }
                            response["requestID"] = request["requestID"]
                            try emit(.object(response))
                        } else {
                            guard var page = frames.first(where: {
                                $0["data"]?["corpus"]?.string == "pcGamePassDiscovery"
                            })?["data"]?.object else { exit(3) }
                            page["products"] = .array((page["products"]?.array ?? []).map { product in
                                var value = product.object ?? [:]
                                value["source"] = .string("syntheticPublicSource")
                                return .object(value)
                            })
                            page["failures"] = .array([])
                            page["corpusRevision"] = failedPage["error"]?["details"]?["corpusRevision"]
                            page["nextCursor"] = .null
                            try emit(.object(result(request, data: .object(page))))
                        }
                        continue
                    }
                    if scenario == "discoveryfail", command == "catalog.discover" {
                        guard var response = frames.first(where: {
                            $0["error"]?["details"]?["corpus"]?.string == "pcGamePassDiscovery"
                        })?.object else { exit(3) }
                        response["requestID"] = request["requestID"]
                        try emit(.object(response))
                        continue
                    }
                    if ["queryfail", "badqueryfail"].contains(scenario), command == "catalog.query" {
                        guard var response = frames.first(where: {
                            $0["error"]?["details"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                        })?.object else { exit(3) }
                        response["requestID"] = request["requestID"]
                        if scenario == "badqueryfail" {
                            guard var error = response["error"]?.object,
                                  var details = error["details"]?.object else { exit(3) }
                            details["failures"] = .array([])
                            error["details"] = .object(details)
                            response["error"] = .object(error)
                        }
                        try emit(.object(response))
                        continue
                    }
                    if ["queryempty", "queryslow", "discoverypcflag"].contains(scenario), command == "catalog.query" {
                        guard var page = frames.first(where: {
                            $0["data"]?["corpus"]?.string == "publicMicrosoftStoreSearch"
                                && $0["data"]?["products"]?.array?.isEmpty == true
                        })?["data"]?.object else { exit(3) }
                        page["query"] = request["params"]?["query"]
                        if scenario == "queryslow" { Thread.sleep(forTimeInterval: 1) }
                        try emit(.object(result(request, data: .object(page))))
                        continue
                    }
                    if scenario == "eof" { exit(0) }
                    if scenario == "exit" { exit(7) }
                    if scenario == "timeout" { Thread.sleep(forTimeInterval: 5); continue }
                    let data: JSONValue
                    if command == ManagementCommand.diagnostics.rawValue, scenario == "diagnostics" {
                        guard let summary = frames.first(where: { $0["data"]?["jobCount"] != nil })?["data"] else { exit(3) }
                        data = summary
                    } else if command == "jobs.snapshot" {
                        if scenario == "retiresnapshot" {
                            try trace("snapshot.wait")
                            Thread.sleep(forTimeInterval: 0.4)
                        }
                        data = .object(["sessionID": .string("fixture-session"), "watermark": .integer(0), "jobs": .array([])])
                    } else {
                        data = .object(["state": .string("signedOut"), "credentialStore": .string("macOSKeychain"),
                            "audience": .null, "expiresAt": .null, "entitlementAuthorized": .bool(false)])
                    }
                    var response = result(request, data: scenario == "wrongshape" ? .object(hello) : data)
                    if scenario == "keychain" {
                        response.removeValue(forKey: "data")
                        response["ok"] = .bool(false)
                        response["error"] = .object([
                            "code": .string("AUTH_INVALID"), "message": .string("Synthetic store failure."),
                            "retryable": .bool(false),
                            "details": .object(["category": .string("credentialStoreUnavailable")])
                        ])
                    }
                    if scenario == "wrongid" { response["requestID"] = .string("fixture-unexpected") }
                    try emit(.object(response))
                }
            }
            if lifecycleScenario {
                try trace("stdin.closed")
                if scenario == "retirefailed" {
                    try trace("retirement.held")
                    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    while !FileManager.default.fileExists(atPath:
                        lifecycleDirectory.appendingPathComponent("retirement.release").path) {
                        guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                } else {
                    Thread.sleep(forTimeInterval: 1.4)
                }
                try trace("exiting")
            }
            exit(0)
        } catch { exit(3) }
    }

    static func result(_ request: JSONValue, data: JSONValue) -> [String: JSONValue] {
        ["kind": .string("result"), "protocol": .object(["major": .integer(1), "minor": .integer(0)]),
         "requestID": request["requestID"] ?? .string("fixture-invalid"), "ok": .bool(true), "data": data]
    }

    static func emit(_ frame: JSONValue) throws {
        var data = try JSONEncoder().encode(frame)
        data.append(10)
        outputLock.lock()
        defer { outputLock.unlock() }
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static let outputLock = NSLock()
    private static let queryCounters = QueryCounters()

    static func emitFailure(_ request: JSONValue, code: String, category: String? = nil,
                            message: String = "Synthetic fixture failure.") throws {
        var error: [String: JSONValue] = [
            "code": .string(code), "message": .string(message), "retryable": .bool(false)
        ]
        if let category { error["details"] = .object(["category": .string(category)]) }
        try emit(.object([
            "kind": .string("result"), "protocol": .object(["major": .integer(1), "minor": .integer(0)]),
            "requestID": request["requestID"] ?? .null, "ok": .bool(false), "error": .object(error)
        ]))
    }

    private final class QueryCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, issued = 0, maximum = 0

        func started() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            active += 1
            issued += 1
            maximum = max(maximum, active)
            return active <= 4
        }

        func finished() {
            lock.lock()
            defer { lock.unlock() }
            active -= 1
        }

        func snapshot() -> (issued: Int, maximum: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (issued, maximum)
        }
    }
}
