// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

enum OperatorAvailabilityGate {
    static func confirm(stdinInteractive: Bool, stderrInteractive: Bool,
                        warn: () -> Void, readResponse: () -> String?) -> Bool {
        guard stdinInteractive && stderrInteractive else { return false }
        warn()
        guard let response = readResponse() else { return false }
        return response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
    }
}

@MainActor
enum RealAccountScenarioChecks {
    static func launch() -> Never {
        guard OperatorAvailabilityGate.confirm(
            stdinInteractive: isatty(STDIN_FILENO) == 1,
            stderrInteractive: isatty(STDERR_FILENO) == 1,
            warn: {
                FileHandle.standardError.write(Data(
                    ("Real-account verification may access saved real credentials and open Microsoft's "
                     + "sign-in browser/window. You must be available to complete sign-in and any native "
                     + "prompts. Existing account/native-input authorization is still required. "
                     + "Are you available now? Type YES to continue: ").utf8))
            }, readResponse: { readLine() }) else {
            FileHandle.standardError.write(Data(
                "Operator availability was not confirmed in an interactive terminal; no account or browser work was started.\n".utf8))
            exit(64)
        }
        Task { @MainActor in
            let session = LiveSession()
            await session.connect()
            await session.refreshAccount()
            var passed = session.hasConfirmedSignIn
            if !passed && session.canStartWelcomeSignIn {
                await session.beginSignIn()
                let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                do {
                    while session.signInPending && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if session.signInPending {
                        FileHandle.standardError.write(Data("Real-account sign-in timed out; cancelling the pending flow.\n".utf8))
                        await session.cancelSignIn()
                    }
                    passed = session.hasConfirmedSignIn
                } catch {
                    FileHandle.standardError.write(Data("Real-account wait interrupted: \(error.localizedDescription)\n".utf8))
                    await session.cancelSignIn()
                }
            }
            if !passed {
                FileHandle.standardError.write(Data(
                    "Real-account sign-in was not confirmed through the existing admitted unified-account path. \(session.accountError ?? session.errorMessage ?? "A matching sign-in service and current account status are required.")\n".utf8))
            }
            let closed = await session.disconnect()
            if !closed {
                FileHandle.standardError.write(Data("Real-account verification could not join its management connection.\n".utf8))
            }
            if passed && closed {
                print("Unified-account sign-in confirmed; library, entitlement and gameplay acceptance are separate.")
            }
            exit(passed && closed ? 0 : 1)
        }
        CFRunLoopRun()
        fatalError("Real-account scenario returned without exiting.")
    }
}
