// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import XodusManagement

@MainActor
final class InstalledProductAccess: ObservableObject {
    private var catalogScope: String?
    struct Fact {
        let value: OdeProductAccess
        let checkedAt: Date
        let expiresAt: Date?

        init(value: OdeProductAccess, checkedAt: Date) {
            self.value = value
            self.checkedAt = checkedAt
            expiresAt = value.expiryDate
        }
    }

    @Published private(set) var facts: [String: Fact] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var checking = false
    private(set) var accountHash: String?
    private var attempts: [String: Date] = [:]
    /// REQ-159: reads are on demand for one product, each answer is reused for 10 minutes, and a retryable
    /// failure backs off (per product and for all products) instead of re-polling Microsoft.
    nonisolated static let freshness: TimeInterval = 600
    nonisolated static let maximumBackoff: TimeInterval = 900
    private var failures: [String: Int] = [:]
    /// 72450bd3 L2: consecutive failures across all products set the global pause length.
    private var globalFailures = 0
    /// 72450bd3 M2: products checked from their product page stay tracked (cached) across installed-set updates.
    private var pagedIDs = Set<String>()
    private(set) var pausedUntil: Date?
    /// Every licence read this object started; a fixture bounds it.
    private(set) var readCount = 0
    nonisolated static func backoff(afterFailures count: Int) -> TimeInterval {
        min(maximumBackoff, 60 * pow(2, Double(max(0, count - 1))))
    }
    private var installed = Set<String>()
    private var operation: Task<Void, Never>?
    /// A product a waiting request needs now (e.g. a deep link); a running sweep checks it next.
    private var priorityID: String?
    private var expiryNotification: Task<Void, Never>?
    private var generation = UUID()
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "product-access")

    private func fresh(_ id: String, now: Date) -> Bool {
        guard let fact = facts[id], now.timeIntervalSince(fact.checkedAt) >= 0,
              now.timeIntervalSince(fact.checkedAt) < Self.freshness - 60 else { return false }
        return fact.expiresAt.map { $0.timeIntervalSince(now) > 180 } ?? true
    }

    /// REQ-159: keeps the installed set current without reading any licence.
    func track(account: String?, installedIDs: [String]) {
        guard account == accountHash else { return }
        installed = Set(installedIDs.filter(PCGamesClient.validProductID)).union(pagedIDs)
        facts = facts.filter { installed.contains($0.key) }
        errors = errors.filter { installed.contains($0.key) }
    }

    /// 72450bd3 M2: one shared, cached check for a product page; never its own store or a retire on disappear.
    func checkProduct(_ productID: String, session: LiveSession, force: Bool = false) async {
        guard PCGamesClient.validProductID(productID) else { return }
        pagedIDs.insert(productID)
        await refresh(session: session, installedIDs: Array(installed.union([productID])), force: force,
                      selectedProductID: productID)
    }

    func checkProduct(_ productID: String, account: String?, now: Date = Date(), force: Bool = false,
                      read: @escaping @MainActor (String) async throws -> OdeAccountRead) async {
        guard PCGamesClient.validProductID(productID) else { return }
        pagedIDs.insert(productID)
        await refresh(account: account, installedIDs: Array(installed.union([productID])), now: now, force: force,
                      selectedProductID: productID, read: read)
    }

    /// 72450bd3 L1: while reads are paused after a failure, say until when instead of waiting silently.
    func pausedNotice(now: Date = Date()) -> String? {
        guard let pausedUntil, now < pausedUntil else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Access checks are paused until \(formatter.string(from: pausedUntil)) after a failed check. Try again then."
    }

    /// REQ-159: a current answer that this account can't play the product; until then Play stays offered and
    /// checks access when pressed.
    func deniedRecently(_ productID: String, account: String?, now: Date = Date()) -> Bool {
        guard let account, accountHash == account, errors[productID] == nil, let fact = facts[productID],
              now.timeIntervalSince(fact.checkedAt) >= 0, now.timeIntervalSince(fact.checkedAt) < Self.freshness
        else { return false }
        return !permits(productID, account: account, now: now)
    }

    /// REQ-119: not checked yet for this account (no result and no error); the tile shows, Play waits.
    func pending(_ productID: String, account: String?) -> Bool {
        guard let account, accountHash == nil || accountHash == account else { return false }
        return facts[productID] == nil && errors[productID] == nil
    }

    func permits(_ productID: String, account: String?, now: Date = Date()) -> Bool {
        guard let account, accountHash == account, let fact = facts[productID],
              now.timeIntervalSince(fact.checkedAt) >= 0,
              now.timeIntervalSince(fact.checkedAt) < Self.freshness else { return false }
        return fact.value.access == .permitted && fact.value.reason == nil
            && (fact.value.expiresAt == nil || fact.expiresAt.map { $0 > now } == true)
    }

    func permitsReview(_ productID: String, account: String?, pcCandidate: Bool, now: Date = Date()) -> Bool {
        pcCandidate && !checking && errors[productID] == nil && permits(productID, account: account, now: now)
    }

    /// QA A1: the one source for settled "not in this account" and service-failure access copy, used by
    /// the game page, its install control and any tile or tooltip. No store or purchase links (REQ-22/26/61).
    static let notIncludedTitle = "Not included with your account"
    static let notIncludedDetail = "This game isn't in your Microsoft account's games or your PC Game Pass plan. If you own it, check that you're signed in with the right account."
    static var notIncludedNotice: String { "\(notIncludedTitle). \(notIncludedDetail)" }
    static let unavailableNotice = "Couldn't confirm access right now. Try again."
    static let tryAgainTitle = "Try Again"

    /// True for a current, error-free check that settled without this game: the account response didn't
    /// list it, or its answer is unknown while the complete public PC Game Pass list also excludes it.
    /// Transport errors never qualify.
    func notIncluded(_ productID: String, account: String?, publicGamePassExcludes: Bool,
                     now: Date = Date()) -> Bool {
        guard let account, accountHash == account, !checking,
              errors[productID] == nil, let fact = facts[productID],
              !permits(productID, account: account, now: now),
              now.timeIntervalSince(fact.checkedAt) >= 0, now.timeIntervalSince(fact.checkedAt) < Self.freshness,
              fact.expiresAt.map({ $0 <= now }) != true else { return false }
        return fact.value.reason == .productNotListed || (fact.value.reason == nil && publicGamePassExcludes)
    }

    func reviewNotice(for productID: String, account: String?, publicGamePassExcludes: Bool = false,
                      now: Date = Date()) -> String? {
        if notIncluded(productID, account: account, publicGamePassExcludes: publicGamePassExcludes, now: now) {
            return Self.notIncludedNotice
        }
        guard let account, accountHash == account else {
            return "Access for this account hasn't been checked for this game."
        }
        if checking { return "Checking access for this game." }
        if errors[productID] != nil || facts[productID] == nil, let paused = pausedNotice(now: now) { return paused }
        if errors[productID] != nil { return Self.unavailableNotice }
        if permits(productID, account: account, now: now) { return nil }
        guard let fact = facts[productID] else { return "Access for this game hasn't been checked." }
        if now.timeIntervalSince(fact.checkedAt) < 0 || now.timeIntervalSince(fact.checkedAt) >= Self.freshness
            || fact.expiresAt.map({ $0 <= now }) == true {
            return "The access check for this game has expired. Check access again."
        }
        switch fact.value.reason {
        case .providerDenied: return "The account provider didn't grant access to this game."
        case .productNotListed: return Self.notIncludedNotice
        case .validityUnavailable: return "The account provider couldn't confirm a valid access period for this game."
        case .grantExpired: return "The access grant returned for this game has expired."
        case .grantNotStarted: return "The access grant returned for this game isn't active yet."
        case nil: return "Access for this game hasn't been confirmed."
        }
    }

    func retire() {
        generation = UUID()
        operation?.cancel()
        expiryNotification?.cancel()
        expiryNotification = nil
        operation = nil
        accountHash = nil
        facts = [:]
        errors = [:]
        attempts = [:]
        failures = [:]
        globalFailures = 0
        pagedIDs = []
        pausedUntil = nil
        installed = []
        checking = false
    }

    func refresh(session: LiveSession, installedIDs: [String], now: Date = Date(), force: Bool = false,
                 selectedProductID: String? = nil) async {
        let scope = session.accountCatalogScope
        if catalogScope != scope {
            retire()
            catalogScope = scope
        }
        guard session.accountCountryReady else { return }
        let account = session.hasConfirmedSignIn ? session.accountHash : nil
        guard account == nil || session.nativeLifecycleConfiguration != nil else { return }
        await refresh(account: account, installedIDs: installedIDs, now: now, force: force,
                      selectedProductID: selectedProductID) { id in
            for _ in 0..<100 where session.accountBusy || session.yieldsToLibraryRead {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard session.accountCatalogScope == scope else { throw CancellationError() }
            let result = try await session.readUnifiedAccount(.license, productID: id)
            guard session.accountCatalogScope == scope else { throw CancellationError() }
            return result
        }
    }

    func prioritize(_ productID: String, session: LiveSession, installedIDs: [String]) async {
        guard session.accountCountryReady, catalogScope == nil || catalogScope == session.accountCatalogScope else { return }
        let account = session.hasConfirmedSignIn ? session.accountHash : nil
        guard account != nil, session.nativeLifecycleConfiguration != nil else { return }
        let scope = session.accountCatalogScope
        await prioritize(productID, account: account, installedIDs: installedIDs) { id in
            guard session.accountCatalogScope == scope else { throw CancellationError() }
            let result = try await session.readUnifiedAccount(.license, productID: id)
            guard session.accountCatalogScope == scope else { throw CancellationError() }
            return result
        }
    }

    func refresh(account: String?, installedIDs: [String], now: Date = Date(), force: Bool = false,
                 selectedProductID: String? = nil,
                 read: @escaping @MainActor (String) async throws -> OdeAccountRead) async {
        if account != accountHash {
            let old = operation
            retire()
            let epoch = generation
            await old?.value
            guard generation == epoch else { return }
            accountHash = account
        }
        guard let account, XboxAccountBinding.valid(account) else { return }
        let currentInstalled = Set(installedIDs.filter(PCGamesClient.validProductID))
        guard currentInstalled.count <= 100 else {
            logger.error("Installed product access scan exceeds the 100-product bound")
            return
        }
        installed = currentInstalled
        if facts.keys.contains(where: { !installed.contains($0) }) {
            facts = facts.filter { installed.contains($0.key) }
        }
        if errors.keys.contains(where: { !installed.contains($0) }) {
            errors = errors.filter { installed.contains($0.key) }
        }
        attempts = attempts.filter { installed.contains($0.key) }
        // A request made during a scan (e.g. a just-installed title) is re-evaluated afterwards rather than dropped.
        let requestEpoch = generation
        while let operation {
            await operation.value
            guard !Task.isCancelled, generation == requestEpoch, accountHash == account else { return }
        }
        // REQ-159: every read, swept or selected, reuses a 10-minute answer and respects the per-product and
        // global backoff after a failure; production never sweeps (it only calls `track`).
        if let pausedUntil, now < pausedUntil { return }
        let ids = installed.sorted { (attempts[$0] == nil ? 0 : 1, $0) < (attempts[$1] == nil ? 0 : 1, $1) }.filter { id in
            if let selectedProductID, id != selectedProductID { return false }
            if let failed = failures[id], let last = attempts[id],
               now.timeIntervalSince(last) < Self.backoff(afterFailures: failed) { return false }
            if force { return errors[id] != nil || facts[id] == nil || !fresh(id, now: now) }
            guard let last = attempts[id] else { return true }
            return now.timeIntervalSince(last) >= 60 && (errors[id] != nil || !fresh(id, now: now))
        }
        guard !ids.isEmpty else { return }
        let epoch = generation
        checking = true
        operation = Task {
            defer {
                if generation == epoch { checking = false; operation = nil }
            }
            var queue = ids
            while !queue.isEmpty || priorityID != nil {
                let id: String
                if let urgent = priorityID {
                    priorityID = nil
                    queue.removeAll { $0 == urgent }
                    id = urgent
                } else { id = queue.removeFirst() }
                guard !Task.isCancelled, generation == epoch, accountHash == account else { return }
                guard installed.contains(id) else { continue }
                attempts[id] = now
                do {
                    let licenseSpan = LoadSignposts.begin("LicenseRead",
                        "operation=installedProductAccess")
                    let response: OdeAccountRead
                    readCount += 1
                    do {
                        response = try await read(id)
                        LoadSignposts.end("LicenseRead", licenseSpan, "outcome=success")
                    } catch {
                        LoadSignposts.end("LicenseRead", licenseSpan, "outcome=failed")
                        throw error
                    }
                    try response.validate(section: .license, accountHash: account)
                    let value = try response.payload.decode(OdeProductAccess.self)
                    try value.validate(productID: id, checkedAt: response.checkedAt)
                    guard !Task.isCancelled, generation == epoch, accountHash == account else { return }
                    guard installed.contains(id) else { continue }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let date = formatter.date(from: response.checkedAt)
                    formatter.formatOptions = [.withInternetDateTime]
                    guard let checkedAt = date ?? formatter.date(from: response.checkedAt) else {
                        throw ManagementError.invalidPayload
                    }
                    facts[id] = Fact(value: value, checkedAt: checkedAt)
                    failures[id] = nil
                    globalFailures = 0
                    pausedUntil = nil
                    scheduleExpiry()
                    if errors[id] != nil { errors[id] = nil }
                    logger.notice("Product access \(id, privacy: .public): \(value.access.rawValue, privacy: .public)")
                } catch is CancellationError { return }
                catch {
                    guard generation == epoch, accountHash == account else { return }
                    errors[id] = LiveSession.describe(error)
                    failures[id] = (failures[id] ?? 0) + 1
                    globalFailures += 1
                    pausedUntil = now.addingTimeInterval(Self.backoff(afterFailures: globalFailures))
                    logger.error("Product access \(id, privacy: .public) failed: \(LiveSession.describe(error), privacy: .public)")
                }
                await Task.yield()
            }
        }
        await operation?.value
    }

    /// Checks this installed product next: inside a running sweep, or as its own check otherwise.
    func prioritize(_ productID: String, account: String?, installedIDs: [String],
                    read: @escaping @MainActor (String) async throws -> OdeAccountRead) async {
        guard PCGamesClient.validProductID(productID), installedIDs.contains(productID) else { return }
        if operation != nil, accountHash == account, account != nil {
            installed.insert(productID)
            priorityID = productID
            return
        }
        await refresh(account: account, installedIDs: installedIDs, force: true,
                      selectedProductID: productID, read: read)
    }

    private func scheduleExpiry() {
        expiryNotification?.cancel()
        let now = Date()
        let deadlines = facts.values.flatMap { fact -> [Date] in
            var dates = [fact.checkedAt.addingTimeInterval(Self.freshness)]
            if let date = fact.expiresAt {
                dates.append(date)
            }
            return dates
        }.filter { $0 > now }
        guard let next = deadlines.min() else { return }
        expiryNotification = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.timeIntervalSince(now))) }
            catch { return }
            self?.objectWillChange.send()
            self?.scheduleExpiry()
        }
    }
}
