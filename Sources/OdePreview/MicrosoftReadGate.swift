// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

/// Marks a Microsoft read as started by a person (Refresh, Retry, Cmd-R, Try again, "Check country again",
/// Play). Unmarked reads are automatic. Tasks created inside `explicit` inherit the mark.
enum MicrosoftReadContext {
    @TaskLocal static var explicit = false

    static func explicit<T>(_ body: () throws -> T) rethrows -> T {
        try $explicit.withValue(true, operation: body)
    }
    @MainActor
    static func explicit<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        try await $explicit.withValue(true, operation: body)
    }
    /// For timers and follow-up work that an explicit action happens to create.
    static func automatic<T>(_ body: () throws -> T) rethrows -> T {
        try $explicit.withValue(false, operation: body)
    }
}

/// An automatic Microsoft read refused on this Mac while Microsoft throttles it or rejects the saved sign-in.
/// Nothing was sent.
struct MicrosoftReadsPaused: Error, Equatable {
    let message: String
}

/// d270a2c5: one gate, checked before every Microsoft read and fed by every answer (library, licence, recent
/// activity, profile, country, achievements, runtime). It is not a scheduler or a queue.
///
/// - Keyed to one account hash: another account starts clear, and one account's rejection never blocks another.
/// - Survives management disconnect and reconnect; cleared only by a real sign-out or an account change.
/// - Throttle and sign-in rejection are separate. Expiry or a successful read clears only the throttle;
///   the rejection clears only on a successful sign-in, a sign-out or an account change.
/// - Explicit actions read anyway; their answers still feed the gate.
@MainActor
final class MicrosoftReadGate: ObservableObject {
    nonisolated static let defaultThrottle: TimeInterval = 600

    @Published private(set) var account: String?
    @Published private(set) var throttledUntil: Date?
    @Published private(set) var signInRejected = false
    /// Automatic reads refused here (none of them reached the management boundary).
    private(set) var refusedAutomaticReads = 0
    /// Injectable for checks.
    var clock: () -> Date = Date.init

    func held(for account: String?, now: Date? = nil) -> Bool {
        guard let gated = self.account, account == nil || account == gated else { return false }
        if signInRejected { return true }
        guard let throttledUntil else { return false }
        if (now ?? clock()) >= throttledUntil {
            self.throttledUntil = nil
            return false
        }
        return true
    }

    func allowsAutomaticRead(account: String?, now: Date? = nil) -> Bool { !held(for: account, now: now) }

    /// The boundary check: explicit reads always pass; automatic ones pass unless the gate is held.
    func admit(account: String, now: Date? = nil) throws {
        guard !MicrosoftReadContext.explicit, held(for: account, now: now) else { return }
        refusedAutomaticReads += 1
        throw MicrosoftReadsPaused(message: pauseMessage(now: now) ?? LiveSession.signInRejectedMessage)
    }

    nonisolated static func throttle(after error: Error) -> TimeInterval? {
        switch error as? ManagementError {
        case .authenticatedReadThrottled(let seconds)?, .recentLibraryThrottled(let seconds)?:
            return seconds.map(TimeInterval.init) ?? defaultThrottle
        case .recentLibraryFailed(.throttled)?, .authenticatedReadFailed(.throttled)?:
            return defaultThrottle
        default: return nil
        }
    }

    nonisolated static func rejectsSignIn(_ error: Error) -> Bool {
        switch error as? ManagementError {
        case .authenticatedReadFailed(.authExchangeFailed)?, .recentLibraryFailed(.authExchangeFailed)?: return true
        default: return false
        }
    }

    private func bind(_ account: String) {
        guard self.account != account else { return }
        self.account = account
        throttledUntil = nil
        signInRejected = false
    }

    /// Every Microsoft answer, automatic or explicit.
    func record(_ error: Error, account: String, now: Date? = nil) {
        let throttle = Self.throttle(after: error)
        let rejected = Self.rejectsSignIn(error)
        guard throttle != nil || rejected else { return }
        bind(account)
        if let throttle {
            let until = (now ?? clock()).addingTimeInterval(throttle)
            if throttledUntil.map({ until > $0 }) ?? true { throttledUntil = until }
        }
        if rejected { signInRejected = true }
    }

    /// d270a2c5 minor-3 / 63685916 Nit-B: a late answer for an account that is no longer current is ignored.
    func record(_ error: Error, account: String, current: String?, now: Date? = nil) {
        guard current == account else { return }
        record(error, account: account, now: now)
    }
    func recordSuccess(account: String, current: String?) {
        guard current == account else { return }
        recordSuccess(account: account)
    }

    func recordSuccess(account: String) {
        guard self.account == account else { return }
        throttledUntil = nil
    }

    /// Completed sign-ins seen per account (2bf5e681 m2); a store's rejection clears only after a newer one.
    private var completedSignIns: [String: Int] = [:]
    func signIns(for account: String) -> Int { completedSignIns[account] ?? 0 }

    func signedIn(account: String) {
        bind(account)
        completedSignIns[account, default: 0] += 1
        signInRejected = false
    }

    func signedOut() {
        account = nil
        throttledUntil = nil
        signInRejected = false
    }

    func pauseMessage(now: Date? = nil) -> String? {
        if signInRejected { return LiveSession.signInRejectedMessage }
        guard let throttledUntil else { return nil }
        let left = throttledUntil.timeIntervalSince(now ?? clock())
        guard left > 0 else { return nil }
        return LiveSession.throttledMessage(retryAfterSeconds: Int(left.rounded(.up)))
    }
}
