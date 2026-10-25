// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import OSLog

public struct BackendConfiguration: Sendable {
    public let executable: URL
    public let stateDirectory: URL
    public let nativeAuthHost: NativeAuthHostBinding?
    public let executableIdentity: NativeAuthHostBinding?

    public init(executable: URL, stateDirectory: URL, nativeAuthHost: NativeAuthHostBinding? = nil,
                executableIdentity: NativeAuthHostBinding? = nil) {
        self.executable = executable
        self.stateDirectory = stateDirectory
        self.nativeAuthHost = nativeAuthHost
        self.executableIdentity = executableIdentity
    }
}

public actor ManagementClient {
    public struct DescriptorMetricCounts: Sendable, Equatable {
        public let checkpoint: UInt64
        public let lookups: UInt64
        public let hits: UInt64
        public let forced: UInt64
        public let coalesced: UInt64
        public let attempts: UInt64
        public let terminals: UInt64
        public let successes: UInt64
    }
    enum OverflowOrigin: String, Sendable {
        case requestBudget, eventQueue, diagnosticLifetime, stdoutQueue, stderrQueue
    }

    struct OverflowFailure: Error {
        let origin: OverflowOrigin
        let count: Int
    }

    private(set) var lastOverflow: OverflowFailure?
    var pendingRequestCount: Int { pending.count }
    public nonisolated let events: AsyncThrowingStream<ManagementEvent, Error>
    private let eventContinuation: AsyncThrowingStream<ManagementEvent, Error>.Continuation
    private let validator: ContractValidator
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus.development", category: "management")
    private let writer = DispatchQueue(label: "Xodus.management.stdin")
    private var process: Process?
    private var admittedConfiguration: BackendConfiguration?
    // Historical startup stage only; this never establishes a ready connection or current sign-in.
    public private(set) var nativeAuthHostValidated = false
    private var stdin: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var framer = JSONLineFramer()
    private var diagnosticBytes = 0
    private var collectionDiagnostics = CollectionDiagnosticFramer()
    private var descriptorMetrics = DescriptorMetricsFramer()
    private var descriptorMetricsEnabled = false
    private var descriptorCheckpointInFlight = false
    private var descriptorExports: UInt64 = 0
    private var descriptorAdmissionWaiters = 0
    var descriptorCheckpointPending: Bool { descriptorCheckpointInFlight }
    var descriptorQueuedRequestCount: Int { descriptorAdmissionWaiters }
    public var descriptorMetricsOptedIn: Bool { descriptorMetricsEnabled }
    private var libraryReadNumber: UInt64 = 0
    private var stopped = false
    private var exitStatus: Int32?
    private var hello: ManagementHello?
    private var pending: [String: Pending] = [:]
    private var usedIDs = Set<String>()

    private struct Pending {
        let command: ManagementCommand
        let libraryReadNumber: UInt64?
        let continuation: CheckedContinuation<JSONValue, Error>
        let deadline: Task<Void, Never>
    }

    public init() throws {
        validator = try ContractValidator()
        let channel = AsyncThrowingStream<ManagementEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = channel.stream
        eventContinuation = channel.continuation
    }

    public func descriptorMetricsCheckpoint() async throws -> DescriptorMetricCounts {
        guard descriptorMetricsEnabled, !descriptorCheckpointInFlight else {
            throw ManagementError.invalidRequest
        }
        guard let counts = try await descriptorMetricsDiagnosticCheckpoint().counts else {
            throw ManagementError.invalidPayload
        }
        return counts
    }

    public func descriptorMetricsDiagnosticCheckpoint() async throws -> (data: JSONValue, counts: DescriptorMetricCounts?) {
        guard descriptorMetricsEnabled, !descriptorCheckpointInFlight else {
            return (try await request(.diagnostics), nil)
        }
        descriptorCheckpointInFlight = true
        defer { descriptorCheckpointInFlight = false }
        let drainDeadline = ContinuousClock.now.advanced(by: ManagementCommand.diagnostics.defaultTimeout)
        logger.notice("Descriptor boundary: reason=draining pending=\(self.pending.count, privacy: .public)")
        while !pending.isEmpty, !stopped, ContinuousClock.now < drainDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !stopped else { throw ManagementError.disconnected }
        guard pending.isEmpty else {
            logger.notice("Descriptor boundary: reason=drainTimeout pending=\(self.pending.count, privacy: .public)")
            return (try await sendRequest(.diagnostics), nil)
        }
        let expected = descriptorExports + 1
        let data: JSONValue
        do { data = try await sendRequest(.diagnostics) }
        catch {
            descriptorMetrics.invalidate()
            throw error
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while descriptorMetrics.checkpoints < expected, descriptorMetrics.status != .invalid,
              descriptorMetrics.status != .exhausted, !stopped, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !stopped, descriptorMetrics.status == .provisional,
              descriptorMetrics.checkpoints == expected,
              descriptorMetrics.sequence == descriptorMetrics.checkpoint,
              descriptorMetrics.active.isEmpty else {
            descriptorMetrics.invalidate()
            logger.notice("Descriptor boundary: reason=missingOrInvalidMarker pending=\(self.pending.count, privacy: .public)")
            return (data, nil)
        }
        logger.notice("Descriptor boundary: reason=complete pending=\(self.pending.count, privacy: .public)")
        return (data, DescriptorMetricCounts(checkpoint: descriptorMetrics.checkpoint,
            lookups: descriptorMetrics.lookups, hits: descriptorMetrics.hits,
            forced: descriptorMetrics.forced, coalesced: descriptorMetrics.coalesced,
            attempts: descriptorMetrics.attempts, terminals: descriptorMetrics.terminals,
            successes: descriptorMetrics.successes))
    }

    public func connect(_ configuration: BackendConfiguration) async throws -> ManagementHello {
        guard process == nil, !stopped else { throw ManagementError.alreadyConnected }
        guard configuration.executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: configuration.executable.path),
              configuration.stateDirectory.isFileURL,
              configuration.stateDirectory.path.hasPrefix("/"),
              configuration.stateDirectory.standardizedFileURL.pathComponents.count > 2 else {
            throw ManagementError.backendUnavailable
        }
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        let child = Process()
        child.executableURL = configuration.executable
        let nativeArguments: [String]
        do { nativeArguments = try configuration.nativeAuthHost?.validatedArguments() ?? [] }
        catch { throw ManagementError.nativeAuthHostUnavailable }
        child.arguments = ["manage", "--protocol", "1", "--state-dir", configuration.stateDirectory.path]
            + nativeArguments
        // Inherit operational context, not unrelated application tokens or debug/proxy settings.
        child.environment = Self.operationalEnvironment(ProcessInfo.processInfo.environment)
        descriptorMetricsEnabled = child.environment?["XODUS_DESCRIPTOR_METRICS"] == "1"
        child.standardInput = input
        child.standardOutput = output
        child.standardError = diagnostics
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ManagementError.startFailed
        }
        child.terminationHandler = { [weak self] value in
            let status = value.terminationStatus
            Task { await self?.ended(status: status) }
        }
        do {
            if let identity = configuration.executableIdentity {
                guard identity.executable == configuration.executable else {
                    throw ManagementError.pairedEngineUnavailable
                }
                do { _ = try identity.validatedArguments() }
                catch { throw ManagementError.pairedEngineUnavailable }
            }
            do { _ = try configuration.nativeAuthHost?.validatedArguments() }
            catch { throw ManagementError.nativeAuthHostUnavailable }
            nativeAuthHostValidated = configuration.nativeAuthHost != nil
            try child.run()
        }
        catch let error as ManagementError { throw error }
        catch { throw ManagementError.startFailed }
        process = child
        admittedConfiguration = configuration
        stdin = input.fileHandleForWriting
        logger.info("Management process started.")

        let stdout = Self.chunks(output.fileHandleForReading, origin: .stdoutQueue)
        outputTask = Task { [weak self] in
            defer { stdout.cancel() }
            do {
                for try await bytes in stdout {
                    guard let self else { return }
                    try await self.consume(bytes)
                }
                await self?.outputEnded()
            } catch {
                await self?.transportFailed(error)
            }
        }
        let stderr = Self.chunks(diagnostics.fileHandleForReading, origin: .stderrQueue)
        diagnosticTask = Task { [weak self] in
            defer { stderr.cancel() }
            do {
                for try await bytes in stderr {
                    guard let self else { return }
                    try await self.consumeDiagnostics(bytes)
                }
                await self?.diagnosticsEnded()
            } catch { await self?.transportFailed(error) }
        }
        do {
            let result = try await request(.hello, params: [
                "client": .string("xodus-macos-app"), "clientVersion": .string("0.2.0")
            ])
            return try result.decode(ManagementHello.self)
        } catch {
            fail(Self.safeError(error))
            throw error
        }
    }

    static func operationalEnvironment(_ environment: [String: String]) -> [String: String] {
        var selected = environment.filter {
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR"].contains($0.key)
        }.merging(["RUST_LOG": "error"]) { _, value in value }
        if environment["XODUS_DESCRIPTOR_METRICS"] == "1" { selected["XODUS_DESCRIPTOR_METRICS"] = "1" }
        return selected
    }

    public func request(_ command: ManagementCommand, params: [String: JSONValue] = [:],
                        timeout: Duration? = nil) async throws -> JSONValue {
        let budget = timeout ?? command.defaultTimeout
        guard budget > .zero else { throw ManagementError.invalidRequest }
        if descriptorCheckpointInFlight {
            guard pending.count + descriptorAdmissionWaiters < 64 else {
                throw overflow(.requestBudget, count: pending.count + descriptorAdmissionWaiters)
            }
            descriptorAdmissionWaiters += 1
            var waiting = true
            defer { if waiting { descriptorAdmissionWaiters -= 1 } }
            let deadline = ContinuousClock.now.advanced(by: budget)
            while descriptorCheckpointInFlight, !stopped, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            guard !stopped else { throw ManagementError.disconnected }
            guard ContinuousClock.now < deadline else {
                fail(.requestTimedOut)
                throw ManagementError.requestTimedOut
            }
            descriptorAdmissionWaiters -= 1
            waiting = false
            return try await sendRequest(command, params: params, timeout: ContinuousClock.now.duration(to: deadline))
        }
        return try await sendRequest(command, params: params, timeout: timeout)
    }

    private func sendRequest(_ command: ManagementCommand, params: [String: JSONValue] = [:],
                             timeout: Duration? = nil) async throws -> JSONValue {
        let budget = timeout ?? command.defaultTimeout
        guard budget > .zero else { throw ManagementError.invalidRequest }
        guard !stopped, let child = process, child.isRunning, let stdin else {
            throw ManagementError.disconnected
        }
        if [.authBegin, .authLogout, .authVerify, .odeAccountRead, .odeRuntimeVerify].contains(command),
           let admitted = admittedConfiguration, let identity = admitted.executableIdentity {
            do {
                _ = try identity.validatedArguments()
                _ = try admitted.nativeAuthHost?.validatedArguments()
            } catch { throw ManagementError.pairedEngineUnavailable }
        }
        if command != .hello {
            guard let hello else { throw ManagementError.disconnected }
            guard hello.supports(command) else { throw ManagementError.capabilityMissing(command.rawValue) }
        } else if hello != nil { throw ManagementError.alreadyConnected }
        guard pending.count + descriptorAdmissionWaiters < 64, usedIDs.count < 100_000 else {
            throw overflow(.requestBudget, count: pending.count + descriptorAdmissionWaiters >= 64
                           ? pending.count + descriptorAdmissionWaiters : usedIDs.count)
        }
        let id = UUID().uuidString
        let frame = JSONValue.object([
            "kind": .string("request"), "protocol": .object(["major": .integer(1), "minor": .integer(0)]),
            "requestID": .string(id), "command": .string(command.rawValue), "params": .object(params)
        ])
        do { try validator.validate(frame) }
        catch { throw ManagementError.invalidRequest }
        var data = try JSONEncoder().encode(frame)
        guard data.count <= JSONLineFramer.maximumBytes else { throw ManagementError.frameTooLarge }
        data.append(10)
        let bytes = data
        if command == .diagnostics, descriptorMetricsEnabled { descriptorExports += 1 }
        usedIDs.insert(id)
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: budget) }
                catch { return }
                await self?.timedOut(id)
            }
            let readNumber: UInt64?
            if command == .odeAccountRead, params["section"]?.string == "library" {
                libraryReadNumber += 1
                readNumber = libraryReadNumber
                logger.info("Collection request dispatched: localRead=\(self.libraryReadNumber, privacy: .public).")
            } else { readNumber = nil }
            pending[id] = Pending(command: command, libraryReadNumber: readNumber,
                                  continuation: continuation, deadline: deadline)
            writer.async { [weak self] in
                do { try stdin.write(contentsOf: bytes) }
                catch { Task { await self?.fail(.writeFailed) } }
            }
        }
    }

    @discardableResult
    public func close(observationTimeout: Duration = .seconds(6)) async -> Bool {
        guard observationTimeout > .zero, observationTimeout <= .seconds(6) else {
            logger.error("Invalid owned-process shutdown observation budget.")
            return false
        }
        if !stopped {
            stopped = true
            resolveAll(.disconnected)
            eventContinuation.finish()
            stopProcess()
        }
        guard let child = process else { return true }
        // Reconnect cannot race the previous process's private-directory lock or auth-child cleanup.
        let exited = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "Xodus.management.shutdown").async {
                // Foundation waitUntilExit can stall its private run loop after an observed child exit.
                let deadline = ContinuousClock.now.advanced(by: observationTimeout)
                while child.isRunning, ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                continuation.resume(returning: !child.isRunning)
            }
        }
        if !exited { logger.error("Owned management process did not finish bounded shutdown.") }
        return exited
    }

    private func consume(_ bytes: Data) throws {
        guard !stopped else { return }
        for line in try framer.append(bytes) {
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: line) }
            catch { throw ManagementError.invalidFrame }
            try validator.validate(value)
            switch value["kind"]?.string {
            case "result": try receiveResult(value)
            case "event":
                guard let hello else { throw ManagementError.invalidEvent }
                let event = try value.decode(ManagementEvent.self)
                guard event.sessionID == hello.sessionID,
                      event.jobID == event.data.jobID, event.revision == event.data.revision,
                      event.requestID == event.data.requestID else { throw ManagementError.invalidEvent }
                try enqueueEvent(event)
            default: throw ManagementError.invalidFrame
            }
        }
    }

    private func receiveResult(_ value: JSONValue) throws {
        // The sealed producer cannot correlate a state-lock failure before its request loop starts.
        if hello == nil, pending.count == 1, pending.values.first?.command == .hello,
           value["requestID"] == .string("invalid-0"), value["ok"] == .bool(false),
           value["error"] == .object([
               "code": .string("STATE_LOCKED"),
               "message": .string("Another management process owns this state directory."),
               "retryable": .bool(true)
           ]) {
            throw ManagementError.stateLocked
        }
        guard let id = value["requestID"]?.string, let waiter = pending[id] else {
            throw ManagementError.unexpectedResult
        }
        if value["ok"] == .bool(true) {
            guard let data = value["data"], let definition = waiter.command.resultDefinition else {
                throw ManagementError.invalidPayload
            }
            try validator.validate(data, definition: definition)
            if waiter.command == .hello {
                let negotiated = try data.decode(ManagementHello.self)
                guard Set(negotiated.capabilities.map(\.command)).count == negotiated.capabilities.count else {
                    throw ManagementError.invalidPayload
                }
                hello = negotiated
                logger.info("Management protocol negotiated.")
            }
            pending.removeValue(forKey: id)
            waiter.deadline.cancel()
            waiter.continuation.resume(returning: data)
        } else {
            guard let error = value["error"], let code = error["code"]?.string,
                  let retryable = error["retryable"]?.boolean else { throw ManagementError.invalidFrame }
            let failure: ManagementError
            if waiter.command == .authVerify ||
                ([.odeAccountRead, .odeRuntimeVerify].contains(waiter.command)
                    && error["details"]?["category"]?.string == "authenticatedReadFailure") {
                guard let stage = AuthenticatedReadFailure(error: error) else {
                    throw ManagementError.invalidPayload
                }
                failure = .authenticatedReadFailed(stage)
            } else if waiter.command == .libraryRecent,
                      error["details"]?["category"]?.string == "recentLibraryFailure" {
                guard let stage = RecentLibraryFailure(error: error) else {
                    throw ManagementError.invalidPayload
                }
                failure = .recentLibraryFailed(stage)
            } else if waiter.command == .discover, code == "PACKAGE_UNAVAILABLE", let details = error["details"] {
                try validator.validate(details, definition: "failedDiscoveryData")
                failure = .discoveryFailed(try details.decode(CatalogDiscovery.self))
            } else if waiter.command == .query, code == "PACKAGE_UNAVAILABLE", let details = error["details"] {
                try validator.validate(details, definition: "failedQueryData")
                failure = .queryFailed(try details.decode(CatalogQuery.self))
            } else if code == "AUTH_INVALID", error["details"]?["category"]?.string == "credentialStoreUnavailable",
                      [.authStatus, .authBegin, .authCancel, .authLogout].contains(waiter.command) {
                failure = .credentialStoreUnavailable
            } else { failure = .backendError(code, retryable: retryable) }
            pending.removeValue(forKey: id)
            waiter.deadline.cancel()
            // The producer's human message/raw diagnostic text is deliberately not retained.
            waiter.continuation.resume(throwing: failure)
        }
    }

    func consumeDiagnostics(_ bytes: Data) throws {
        guard !stopped else { return }
        guard bytes.count <= JSONLineFramer.maximumBytes - diagnosticBytes else {
            throw overflow(.diagnosticLifetime, count: diagnosticBytes + bytes.count)
        }
        diagnosticBytes += bytes.count
        if descriptorMetricsEnabled {
            let previousStatus = descriptorMetrics.status
            for line in descriptorMetrics.append(bytes) {
                logger.notice("Descriptor metrics captured: \(line, privacy: .public)")
            }
            if descriptorMetrics.status != previousStatus {
                logger.notice("Descriptor metrics proof: status=\(self.descriptorMetrics.status.rawValue, privacy: .public)")
            }
        }
        for line in collectionDiagnostics.append(bytes) {
            let reads = pending.values.compactMap(\.libraryReadNumber)
            if reads.count == 1, let read = reads.first {
                logger.info("Collection counts captured: pendingLocalRead=\(read, privacy: .public); \(line, privacy: .public)")
            } else {
                logger.info("Collection counts captured: uncorrelated; \(line, privacy: .public)")
            }
        }
    }

    private func diagnosticsEnded() {
        guard descriptorMetricsEnabled else { return }
        descriptorMetrics.finish()
        logger.notice("Descriptor metrics proof: status=\(self.descriptorMetrics.status.rawValue, privacy: .public)")
    }

    struct DescriptorMetricsFramer {
        enum Status: String { case unavailable, provisional, invalid, exhausted }
        private(set) var status: Status = .unavailable
        private(set) var sequence: UInt64 = 0
        private(set) var checkpoint: UInt64 = 0
        private(set) var checkpoints: UInt64 = 0
        private(set) var lookups: UInt64 = 0
        private(set) var hits: UInt64 = 0
        private(set) var forced: UInt64 = 0
        private(set) var coalesced: UInt64 = 0
        private(set) var attempts: UInt64 = 0
        private(set) var terminals: UInt64 = 0
        private(set) var successes: UInt64 = 0
        private(set) var active = Set<UInt64>()
        private var line = Data()
        private var discarding = false
        private var emittedBytes = 0
        private static let prefix = "Ode descriptor metrics v1 "
        private static let family = Data("Ode descriptor metrics".utf8)

        mutating func append(_ bytes: Data) -> [String] {
            var accepted: [String] = []
            for byte in bytes {
                if byte == 10 {
                    if !discarding, line.starts(with: Self.family) {
                        if let text = String(data: line, encoding: .utf8), accept(text) {
                            accepted.append(text)
                        } else { status = .invalid }
                    }
                    line.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    if line.count < 255 { line.append(byte) }
                    else {
                        if line.starts(with: Self.family) { status = .invalid }
                        line.removeAll(keepingCapacity: true)
                        discarding = true
                    }
                }
            }
            return accepted
        }

        mutating func finish() {
            if line.starts(with: Self.family) || !active.isEmpty { status = .invalid }
            line.removeAll()
        }

        mutating func invalidate() { status = .invalid }

        private mutating func accept(_ text: String) -> Bool {
            guard status != .invalid, status != .exhausted,
                  text.hasPrefix(Self.prefix), text.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
                  emittedBytes <= 65_536 - text.utf8.count - 1 else { return false }
            let fields = text.dropFirst(Self.prefix.count).split(separator: " ", omittingEmptySubsequences: false)
            func number(_ index: Int, _ key: String) -> UInt64? {
                guard fields.indices.contains(index), fields[index].hasPrefix(key + "=") else { return nil }
                let value = fields[index].dropFirst(key.count + 1)
                guard !value.isEmpty, value == "0" || value.first != "0",
                      value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return UInt64(value)
            }
            guard let kind = fields.first, let next = number(1, "seq"), sequence < UInt64.max,
                  next == sequence + 1 else { return false }
            if kind == "enabled" {
                guard status == .unavailable, fields.count == 3, next == 1,
                      number(2, "budget") == 65_536 else { return false }
                status = .provisional
            } else {
                guard status == .provisional else { return false }
                switch kind {
                case "lookup":
                    guard fields.count == 5, let hit = number(2, "hit"), hit <= 1,
                          let forced = number(3, "forced"), forced <= 1,
                          let coalesced = number(4, "coalesced"), coalesced <= 1,
                          hit == 0 || (forced == 0 && coalesced == 0) else { return false }
                    lookups += 1
                    hits += hit
                    self.forced += forced
                    self.coalesced += coalesced
                case "attempt":
                    guard fields.count == 3, let fetch = number(2, "fetch"),
                          fetch == attempts + 1 else { return false }
                    attempts += 1
                    active.insert(fetch)
                case "terminal":
                    guard fields.count == 4, let fetch = number(2, "fetch"), active.contains(fetch),
                          let ok = number(3, "ok"), ok <= 1 else { return false }
                    active.remove(fetch)
                    terminals += 1
                    successes += ok
                case "checkpoint":
                    guard fields.count == 2, active.isEmpty else { return false }
                    checkpoint = next
                    checkpoints += 1
                case "exhausted":
                    guard fields.count == 2 else { return false }
                    status = .exhausted
                default: return false
                }
            }
            sequence = next
            emittedBytes += text.utf8.count + 1
            return true
        }
    }

    func enqueueEvent(_ event: ManagementEvent) throws {
        if case .dropped = eventContinuation.yield(event) {
            throw overflow(.eventQueue, count: 129)
        }
    }

    private func overflow(_ origin: OverflowOrigin, count: Int) -> ManagementError {
        if lastOverflow == nil {
            lastOverflow = OverflowFailure(origin: origin, count: count)
            logger.error("Management overflow: origin=\(origin.rawValue, privacy: .public) count=\(count, privacy: .public)")
        }
        return .outputOverflow
    }

    private func transportFailed(_ error: Error) {
        guard !stopped else { return }
        if let failure = error as? OverflowFailure {
            fail(overflow(failure.origin, count: failure.count))
        } else {
            fail(Self.safeError(error))
        }
    }

    struct CollectionDiagnosticFramer {
        private var line = Data()
        private var discarding = false
        private static let maximumLineBytes = 512

        mutating func append(_ bytes: Data) -> [String] {
            var counts: [String] = []
            for byte in bytes {
                if byte == 10 {
                    if !discarding, let text = String(data: line, encoding: .utf8),
                       let match = text.range(of: "^Ode collection read: records=[0-9]+; activeGameRows=[0-9]+; productIDs=[0-9]+; subscriptionRows=[0-9]+$",
                                              options: .regularExpression),
                       match == text.startIndex..<text.endIndex {
                        counts.append(text)
                    }
                    line.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    if line.count < Self.maximumLineBytes {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: true)
                        discarding = true
                    }
                }
            }
            return counts
        }
    }

    private func outputEnded() {
        guard !stopped else { return }
        do { try framer.finish() }
        catch { fail(Self.safeError(error)); return }
        // EOF never supplies a missing terminal result, even when the exit status is zero.
        fail(exitStatus.map { $0 == 0 ? .disconnected : .backendStopped($0) } ?? .disconnected)
    }

    private func ended(status: Int32) {
        guard !stopped else { return }
        exitStatus = status
        if status != 0, hello != nil { fail(.backendStopped(status)) }
        // Drain a pre-HELLO startup error before exit can erase its typed recovery.
        // A clean exit is drained by outputEnded(), so buffered terminal frames are not lost.
    }

    private func timedOut(_ id: String) {
        guard let waiter = pending[id] else { return }
        logger.error("Management request timed out: \(waiter.command.rawValue, privacy: .public).")
        fail(.requestTimedOut)
    }

    private func fail(_ error: ManagementError) {
        guard !stopped else { return }
        stopped = true
        resolveAll(error)
        eventContinuation.finish(throwing: error)
        stopProcess()
    }

    private func resolveAll(_ error: ManagementError) {
        hello = nil
        let waiters = pending.values
        pending = [:]
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private func stopProcess() {
        try? stdin?.close()
        stdin = nil
        outputTask?.cancel()
        diagnosticTask?.cancel()
        guard let child = process else { return }
        child.terminationHandler = nil
        if child.isRunning {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { child.terminate() }
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func safeError(_ error: Error) -> ManagementError {
        (error as? ManagementError) ?? .disconnected
    }

    struct ChunkStream: AsyncSequence, Sendable {
        typealias Element = Data
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        let permits: ChunkReadPermits

        var bufferedChunkCount: Int { permits.count }
        func cancel() { continuation.finish() }

        struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncThrowingStream<Data, Error>.Iterator
            let permits: ChunkReadPermits

            mutating func next() async throws -> Data? {
                let bytes = try await base.next()
                if bytes != nil { permits.release() }
                return bytes
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), permits: permits)
        }
    }

    // The pipe pump is a blocking dispatch worker, never an actor executor.
    // Reserve bounded queue space before reading so a busy consumer applies
    // pipe backpressure rather than dropping a legitimate response fragment.
    final class ChunkReadPermits: @unchecked Sendable {
        private let condition = NSCondition()
        private var reserved = 0
        private var cancelled = false

        var count: Int {
            condition.lock()
            defer { condition.unlock() }
            return reserved
        }

        func reserve() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            while reserved == 128 && !cancelled { condition.wait() }
            guard !cancelled else { return false }
            reserved += 1
            return true
        }

        func release() {
            condition.lock()
            reserved -= 1
            condition.signal()
            condition.unlock()
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }
    }

    static func chunks(_ handle: FileHandle, origin: OverflowOrigin) -> ChunkStream {
        let permits = ChunkReadPermits()
        let channel = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let continuation = channel.continuation
        continuation.onTermination = { _ in permits.cancel() }
        DispatchQueue(label: "Xodus.management.\(origin.rawValue)").async {
            defer { try? handle.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while permits.reserve() {
                // One pipe read returns available bytes; read(upToCount:) may wait for a full buffer.
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count == 0 {
                    permits.release()
                    continuation.finish()
                    return
                }
                if count < 0 {
                    permits.release()
                    if errno == EINTR { continue }
                    continuation.finish(throwing: ManagementError.disconnected)
                    return
                }
                switch continuation.yield(Data(buffer.prefix(count))) {
                case .enqueued: break
                case .dropped:
                    permits.release()
                    continuation.finish(throwing: OverflowFailure(origin: origin, count: 129))
                    return
                case .terminated:
                    permits.release()
                    return
                @unknown default:
                    permits.release()
                    continuation.finish(throwing: OverflowFailure(origin: origin, count: 129))
                    return
                }
            }
        }
        return ChunkStream(stream: channel.stream, continuation: continuation, permits: permits)
    }
}
