// SPDX-License-Identifier: GPL-3.0-only

import Foundation

import XodusCore

import XodusManagement

@MainActor
enum ApplicationTerminationChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let owned = [
            RuntimeProviderSettings(), RuntimeProviderSettings(), RuntimeProviderSettings(),
        ]
        do {
            check(
                await ApplicationTerminationCoordinator().shutdown(session: nil, runtime: nil),
                "Normal termination coordinator permits idle termination without a management session"
            )
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks")
            let runtime = owned[0]
            runtime.select(.gptk4)
            runtime.text(\.providerVersion).wrappedValue = "mock:timeout"
            runtime.acknowledgeExperimental(true)
            runtime.makePlan(executable: executable)
            try await waitForOwnedChild(runtime)
            check(
                runtime.planning && runtime.plan == nil,
                "Normal quit regression starts an actual neutral planning child, not a canned task")
            let coordinator = ApplicationTerminationCoordinator()
            let quit = Task { await coordinator.shutdown(session: nil, runtime: runtime) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !runtime.applicationTerminating {
                guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
            runtime.select(.gptk3)
            runtime.makePlan(executable: executable)
            check(
                runtime.configuration?.provider == .gptk4,
                "Termination fences configuration changes and new planning spawns")
            let duplicate = Task { await coordinator.shutdown(session: nil, runtime: runtime) }
            let results = await (quit.value, duplicate.value)
            let stillOwned = await runtime.hasOwnedPlanningProcess
            check(
                results.0 && results.1 && !stillOwned && !runtime.planning,
                "Normal zero-management Quit waits through SIGTERM-ignored owned-child escalation and reap"
            )
            check(
                runtime.plan == nil && runtime.applicationTerminating,
                "Termination never adopts a stale plan or reopens planning after successful quit")
            check(
                await coordinator.shutdown(session: nil, runtime: runtime),
                "Repeated normal termination joins the completed shutdown without another child")

            let cancelled = owned[1]
            cancelled.select(.gptk3)
            cancelled.text(\.providerVersion).wrappedValue = "mock:timeout"
            cancelled.acknowledgeExperimental(true)
            cancelled.makePlan(executable: executable)
            try await waitForOwnedChild(cancelled)
            cancelled.cancel()
            let cancelledClosed = await ApplicationTerminationCoordinator().shutdown(
                session: nil, runtime: cancelled)
            let cancelledOwned = await cancelled.hasOwnedPlanningProcess
            check(
                cancelledClosed && !cancelledOwned && cancelled.plan == nil,
                "Normal termination safely joins an already cancelled actual planning child")
            let failed = owned[2]
            failed.select(.gptk3)
            failed.text(\.providerVersion).wrappedValue = "mock:old-engine"
            failed.acknowledgeExperimental(true)
            failed.makePlan(executable: executable)
            let failedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while failed.planning {
                guard ContinuousClock.now < failedDeadline else {
                    throw ManagementError.requestTimedOut
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            check(
                failed.errorMessage != nil && failed.plan == nil,
                "Unavailable planning remains an explicit failure before normal termination")
            let failedClosed = await ApplicationTerminationCoordinator().shutdown(
                session: nil, runtime: failed)
            let failedOwned = await failed.hasOwnedPlanningProcess
            check(
                failedClosed && !failedOwned,
                "Normal termination reconciles an already failed idle planner without a fallback")
        } catch {
            for runtime in owned {
                guard
                    await ApplicationTerminationCoordinator().shutdown(
                        session: nil, runtime: runtime)
                else {
                    throw RuntimePlanningError.shutdownFailed
                }
            }
            throw error
        }
    }

    private static func waitForOwnedChild(_ runtime: RuntimeProviderSettings) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await runtime.hasOwnedPlanningProcess) {
            guard runtime.planning, ContinuousClock.now < deadline else {
                throw ManagementError.requestTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
