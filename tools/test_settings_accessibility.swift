// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

struct AccessibilityTestFailure: Error {
    let message: String
    let status: Int32
}

var failures = 0
struct ScopedRunResult {
    let status: Int32
    let failures: [String]
}

final class ScopedRunContext {
    let appURL: URL
    var process: OwnedChild?

    init(appURL: URL) {
        self.appURL = appURL
    }
}

func fail(_ message: String, status: Int32 = 1) throws -> Never {
    throw AccessibilityTestFailure(message: message, status: status)
}

func check(_ condition: Bool, _ success: String, _ failure: String) {
    if condition {
        print("PASS: \(success)")
    } else {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
    }
}

// This standalone runner is the only reaper of its posix_spawn children. An exited
// child remains a zombie (reserving its PID) until this owner calls waitpid.
final class OwnedChild {
    let processIdentifier: pid_t
    private var ownedPID: pid_t?

    init(executable: URL, arguments: [String],
         environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var disposition = sigaction()
        disposition.__sigaction_u.__sa_handler = SIG_DFL
        guard sigemptyset(&disposition.sa_mask) == 0,
              sigaction(SIGCHLD, &disposition, nil) == 0 else {
            throw AccessibilityTestFailure(message: "Could not establish exclusive child reaping: \(String(cString: strerror(errno))).", status: 1)
        }
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw AccessibilityTestFailure(message: "Could not allocate child launch arguments.", status: 1)
        }
        var terminatedArguments = argv + [nil]
        var terminatedEnvironment = envp + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, nil, nil,
                                 &terminatedArguments, &terminatedEnvironment)
        guard result == 0 else {
            throw AccessibilityTestFailure(message: "Could not spawn the isolated child: \(String(cString: strerror(result))).", status: 1)
        }
        processIdentifier = pid
        ownedPID = pid
    }

    var hasUnreapedChild: Bool { ownedPID != nil }

    func pollExit() throws -> Bool {
        guard let pid = ownedPID else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            ownedPID = nil
            return true
        }
        if result == 0 { return false }
        let failure = errno
        if failure == EINTR { return false }
        // ECHILD means ownership has been lost, not permission to signal a saved PID.
        if failure == ECHILD { ownedPID = nil }
        throw AccessibilityTestFailure(message: "Could not reap the owned child (pid \(pid)): \(String(cString: strerror(failure))); no signal sent.", status: 1)
    }

    func waitForExit(timeout: TimeInterval) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if try pollExit() { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    func terminate(gracefulTimeout: TimeInterval = 0.25,
                   forceTimeout: TimeInterval = 2,
                   sendSignal: (pid_t, Int32) -> Int32 = { kill($0, $1) }) -> String? {
        do {
            for (signal, timeout) in [(SIGTERM, gracefulTimeout), (SIGKILL, forceTimeout)] {
                if try pollExit() { return nil }
                guard let pid = ownedPID else { return nil }
                // No concurrent reaper can free this PID between pollExit and kill.
                if sendSignal(pid, signal) != 0 {
                    let failure = errno
                    throw AccessibilityTestFailure(message: "Could not send signal \(signal) to owned child (pid \(pid)): \(String(cString: strerror(failure))).", status: 1)
                }
                if try waitForExit(timeout: timeout) { return nil }
            }
            return "The owned child did not exit after SIGKILL within \(forceTimeout) seconds."
        } catch {
            return (error as? AccessibilityTestFailure)?.message ?? error.localizedDescription
        }
    }
}

func runScoped(appURL: URL,
               removeBundle: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
               terminateChild: (OwnedChild) -> String? = { $0.terminate() },
               body: (ScopedRunContext) throws -> Int32) -> ScopedRunResult {
    let context = ScopedRunContext(appURL: appURL)
    var cleanupFailures: [String] = []
    let bodyStatus: Int32 = {
        defer {
            if let process = context.process {
                if let failure = terminateChild(process) {
                    cleanupFailures.append(failure)
                }
            }
            if FileManager.default.fileExists(atPath: appURL.path) {
                do {
                    try removeBundle(appURL)
                    if FileManager.default.fileExists(atPath: appURL.path) {
                        cleanupFailures.append("The isolated test app bundle still exists after cleanup.")
                    }
                } catch {
                    cleanupFailures.append("Could not remove the isolated test app bundle: \(error.localizedDescription)")
                }
            }
        }
        do {
            return try body(context)
        } catch let failure as AccessibilityTestFailure {
            cleanupFailures.append(failure.message)
            return failure.status
        } catch {
            cleanupFailures.append(error.localizedDescription)
            return 1
        }
    }()
    return ScopedRunResult(status: cleanupFailures.isEmpty ? bodyStatus : 1, failures: cleanupFailures)
}

func runCleanupSelfChecks() -> Int32 {
    failures = 0
    let fileManager = FileManager.default
    func makeBundle() throws -> URL {
        let bundle = fileManager.temporaryDirectory
            .appendingPathComponent("OdeToX-SettingsAccessibility-Lifecycle-\(UUID().uuidString).app")
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        try Data("fixture".utf8).write(to: bundle.appendingPathComponent("marker"))
        return bundle
    }
    func startSyntheticChild() throws -> OwnedChild {
        try OwnedChild(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    }
    func waitForReadyFile(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return fileManager.fileExists(atPath: url.path)
    }
    do {
        let successfulBundle = try makeBundle()
        let successfulChild = try startSyntheticChild()
        let successful = runScoped(appURL: successfulBundle) { context in
            context.process = successfulChild
            return 0
        }
        check(successful.status == 0 && !successfulChild.hasUnreapedChild,
              "Successful test runner terminates its synthetic child",
              "Successful test runner left its synthetic child running.")
        check(!fileManager.fileExists(atPath: successfulBundle.path),
              "Successful test runner removes its staged bundle",
              "Successful test runner left its staged bundle.")

        let failedBundle = try makeBundle()
        let failedChild = try startSyntheticChild()
        let failed = runScoped(appURL: failedBundle) { context in
            context.process = failedChild
            throw AccessibilityTestFailure(message: "Synthetic interaction failure.", status: 1)
        }
        check(failed.status == 1 && failed.failures.contains("Synthetic interaction failure.")
              && !failedChild.hasUnreapedChild,
              "Failed test runner reports its error and terminates its synthetic child",
              "Failed test runner did not report its error or left its synthetic child running.")
        check(!fileManager.fileExists(atPath: failedBundle.path),
              "Failed test runner removes its staged bundle",
              "Failed test runner left its staged bundle.")

        let resistantBundle = try makeBundle()
        let readyFile = resistantBundle.appendingPathComponent("ignoring-term")
        let resistantChild = try OwnedChild(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /usr/bin/touch \"$READY_FILE\"; exec /bin/sleep 60"],
            environment: ProcessInfo.processInfo.environment.merging(
                ["READY_FILE": readyFile.path], uniquingKeysWith: { _, replacement in replacement }))
        let resistantStart = Date()
        let resistant = runScoped(appURL: resistantBundle) { context in
            context.process = resistantChild
            guard waitForReadyFile(readyFile) else {
                throw AccessibilityTestFailure(message: "Synthetic SIGTERM-resistant child did not become ready.", status: 1)
            }
            return 0
        }
        let resistantDuration = Date().timeIntervalSince(resistantStart)
        check(resistant.status == 0 && !resistantChild.hasUnreapedChild && resistantDuration < 4,
              "SIGTERM-resistant child is escalated to bounded SIGKILL",
              "SIGTERM-resistant child cleanup failed or exceeded its bounded escalation window.")
        check(!fileManager.fileExists(atPath: resistantBundle.path),
              "SIGTERM-resistant child cleanup removes its staged bundle",
              "SIGTERM-resistant child cleanup left its staged bundle.")

        let reapedChild = try OwnedChild(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        let reaped = try reapedChild.waitForExit(timeout: 2)
        var signalsToReapedChild = 0
        let reapedFailure = reapedChild.terminate(sendSignal: { _, _ in
            signalsToReapedChild += 1
            return 0
        })
        check(reaped && reapedFailure == nil && signalsToReapedChild == 0,
              "Already-reaped child cannot be signaled through its retained display PID",
              "Already-reaped child was signaled or failed cleanup.")

        let staleBundle = try makeBundle()
        let staleChild = try OwnedChild(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        var signalsToStaleChild = 0
        let stale = runScoped(appURL: staleBundle, terminateChild: {
            $0.terminate(sendSignal: { _, _ in
                signalsToStaleChild += 1
                return 0
            })
        }) { context in
            context.process = staleChild
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var status: Int32 = 0
            while waitpid(staleChild.processIdentifier, &status, WNOHANG) != staleChild.processIdentifier {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AccessibilityTestFailure(message: "Synthetic external reap timed out.", status: 1)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return 0
        }
        check(stale.status != 0 && signalsToStaleChild == 0
              && stale.failures.contains(where: { $0.contains("no signal sent") })
              && !staleChild.hasUnreapedChild,
              "External reap invalidates stale identity and fails cleanup without sending signals",
              "Stale child identity was signaled or ownership loss was not reported.")
        check(!fileManager.fileExists(atPath: staleBundle.path),
              "Lost child ownership still removes the staged bundle",
              "Lost child ownership left the staged bundle.")

        for rejectSignal in [true, false] {
            let signalBundle = try makeBundle()
            let signalChild = try startSyntheticChild()
            let started = ProcessInfo.processInfo.systemUptime
            let signalResult = runScoped(appURL: signalBundle, terminateChild: {
                $0.terminate(gracefulTimeout: 0.02, forceTimeout: 0.02, sendSignal: { _, _ in
                    errno = EPERM
                    return rejectSignal ? -1 : 0
                })
            }) { context in
                context.process = signalChild
                return 0
            }
            let recoveryFailure = signalChild.terminate()
            check(signalResult.status != 0
                  && signalResult.failures.contains(where: {
                      $0.contains(rejectSignal ? "Could not send signal" : "did not exit after SIGKILL")
                  })
                  && ProcessInfo.processInfo.systemUptime - started < 3
                  && !fileManager.fileExists(atPath: signalBundle.path)
                  && recoveryFailure == nil && !signalChild.hasUnreapedChild,
                  "\(rejectSignal ? "Signal rejection" : "Termination timeout") fails cleanup within a bound; bundle and child recovery verified",
                  "Synthetic termination failure was hidden, unbounded, or left a fixture behind.")
        }

        let cleanupFailureBundle = try makeBundle()
        let cleanupFailureChild = try startSyntheticChild()
        let cleanupFailure = runScoped(appURL: cleanupFailureBundle, removeBundle: { _ in
            throw NSError(domain: "SettingsAccessibilityCleanupChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic removal rejection."])
        }) { context in
            context.process = cleanupFailureChild
            return 0
        }
        check(cleanupFailure.status != 0 && !cleanupFailureChild.hasUnreapedChild,
              "Bundle-removal failure still terminates its synthetic child and fails the runner",
              "Bundle-removal failure was not reflected in the exit status or left its child running.")
        check(cleanupFailure.failures.contains(where: { $0.contains("Synthetic removal rejection.") })
              && fileManager.fileExists(atPath: cleanupFailureBundle.path),
              "Bundle-removal failure is reported rather than silently ignored",
              "Bundle-removal failure was not reported or did not retain the fixture for cleanup verification.")
        do {
            try fileManager.removeItem(at: cleanupFailureBundle)
            check(!fileManager.fileExists(atPath: cleanupFailureBundle.path),
                  "Cleanup self-check removes its intentionally retained fixture",
                  "Cleanup self-check left its intentionally retained fixture.")
        } catch {
            check(false, "Cleanup self-check removes its intentionally retained fixture",
                  "Cleanup self-check could not remove its intentionally retained fixture: \(error.localizedDescription)")
        }
    } catch {
        check(false, "Settings cleanup self-check prepared and cleaned its fixtures",
              "Settings cleanup self-check could not prepare its fixture: \(error.localizedDescription)")
    }
    print("\(failures == 0 ? "All" : "\(failures) failed; remaining") Settings cleanup checks.")
    return failures == 0 ? 0 : 1
}

func runAccessibilityScenario() -> Int32 {
    failures = 0
    let appURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("OdeToX-SettingsAccessibility-\(UUID().uuidString).app", isDirectory: true)
    let result = runScoped(appURL: appURL) { context in
        guard CommandLine.arguments.count == 2 else {
            try fail("Usage: swift tools/test_settings_accessibility.swift /path/to/XodusPreview", status: 64)
        }
        guard AXIsProcessTrusted() else {
            try fail("ACCESSIBILITY_PERMISSION_DENIED: grant Accessibility access to the test host, then rerun.", status: 77)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            try fail("XodusPreview is not executable at \(executable.path). Build it first.")
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let infoPlist = repository.appendingPathComponent("tools/Info.plist")
        let bundleIdentifier = "io.github.dragoshont.xodus.settings-accessibility-test."
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            let stagedInfoPlist = contents.appendingPathComponent("Info.plist")
            try FileManager.default.copyItem(at: infoPlist, to: stagedInfoPlist)
            guard var metadata = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: stagedInfoPlist), format: nil) as? [String: Any] else {
                try fail("The staged Ode to X Info.plist is not a property list dictionary.")
            }
            metadata["CFBundleIdentifier"] = bundleIdentifier
            let isolatedMetadata = try PropertyListSerialization.data(
                fromPropertyList: metadata, format: .xml, options: 0)
            try isolatedMetadata.write(to: stagedInfoPlist, options: .atomic)
            try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent("Xodus"))
            let buildDirectory = executable.deletingLastPathComponent()
            for name in ["XodusAppFoundation_XodusPreview.bundle", "XodusAppFoundation_XodusManagement.bundle"] {
                let bundle = buildDirectory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: bundle.path) else {
                    try fail("Missing SwiftPM resource bundle needed by the test app: \(bundle.path)")
                }
                try FileManager.default.copyItem(at: bundle, to: resources.appendingPathComponent(name))
            }
            guard let bundle = Bundle(url: appURL),
                  bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "Ode to X",
                  bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Ode to X",
                  bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Xodus",
                  bundle.bundleIdentifier == bundleIdentifier else {
                try fail("The staged test app does not have an isolated Ode to X bundle identity.")
            }
        } catch let failure as AccessibilityTestFailure {
            throw failure
        } catch {
            try fail("Could not stage an Ode to X test app bundle: \(error.localizedDescription)")
        }

        let process: OwnedChild
        do {
            process = try OwnedChild(executable: macOS.appendingPathComponent("Xodus"),
                                     arguments: ["--settings-accessibility-check"])
            context.process = process
        } catch {
            try fail("Could not launch the Ode to X test app: \(error.localizedDescription)")
        }

        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)

        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
                return nil
            }
            return result
        }

        func children(_ element: AXUIElement) -> [AXUIElement] {
            value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }

        func descendants(of element: AXUIElement) -> [AXUIElement] {
            let childElements = children(element)
            return childElements + childElements.flatMap(descendants)
        }

        func windows() -> [AXUIElement] {
            value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        }

        func describe(_ element: AXUIElement, depth: Int = 0) {
            let role = value(element, kAXRoleAttribute) as? String ?? "?"
            let title = value(element, kAXTitleAttribute) as? String ?? ""
            let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
            print("\(String(repeating: " ", count: depth * 2))\(role) title=\(title) id=\(identifier)")
            for child in children(element) { describe(child, depth: depth + 1) }
        }

        func settingsWindow() -> AXUIElement? {
            windows().first {
                (value($0, kAXIdentifierAttribute) as? String) == "com_apple_SwiftUI_Settings_window"
            }
        }

        func identified(_ identifier: String) -> AXUIElement? {
            settingsWindow().flatMap { window in
                descendants(of: window).first {
                    value($0, kAXIdentifierAttribute) as? String == identifier
                }
            }
        }

        func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if condition() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } while Date() < deadline
            return condition()
        }

        func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                try fail("Could not create keyboard events.")
            }
            down.flags = flags
            up.flags = flags
            down.postToPid(process.processIdentifier)
            up.postToPid(process.processIdentifier)
        }

        guard waitUntil({ !windows().isEmpty }) else {
            for window in windows() { describe(window) }
            try fail("Ode to X did not expose an accessible window.")
        }
        let applicationName = value(app, kAXTitleAttribute) as? String ?? ""
        let windowTitles = windows().compactMap { value($0, kAXTitleAttribute) as? String }
        print("Observed application name: \(applicationName); window titles: \(windowTitles)")
        check(applicationName == "Ode to X" && windowTitles.contains("Ode to X"),
              "The running test app and its window are visibly named Ode to X",
              "Expected the visible app and window name Ode to X; observed \(applicationName) and \(windowTitles).")
        _ = NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try press(CGKeyCode(kVK_ANSI_Comma), flags: .maskCommand)

        guard waitUntil({ settingsWindow() != nil && identified("xodus.settings.tab.engines") != nil }) else {
            for window in windows() { describe(window) }
            try fail("Cmd+, did not open Settings.")
        }
        print("PASS: Cmd+, opens Settings")

        let settingsTabs = [
            ("General", "xodus.settings.tab.general"),
            ("Engines", "xodus.settings.tab.engines"),
            ("Account", "xodus.settings.tab.account"),
            ("Advanced", "xodus.settings.tab.advanced")
        ]

        func activateTabLabel(_ title: String) -> Bool {
            guard let selector = settingsWindow().flatMap({ window in
                descendants(of: window).first {
                    value($0, kAXRoleAttribute) as? String == kAXButtonRole
                        && value($0, kAXTitleAttribute) as? String == title
                }
            }) else { return false }
            return AXUIElementPerformAction(selector, kAXPressAction as CFString) == .success
        }

        func selectTab(_ title: String, identifier: String) -> Bool {
            if identified(identifier) != nil {
                let alternate = settingsTabs.first { $0.1 != identifier }
                guard let alternate, activateTabLabel(alternate.0),
                      waitUntil({ identified(alternate.1) != nil && identified(identifier) == nil }) else {
                    return false
                }
            }
            guard activateTabLabel(title) else { return false }
            return waitUntil({ identified(identifier) != nil })
        }

        for (title, identifier) in settingsTabs {
            let selected = selectTab(title, identifier: identifier)
            check(selected, "Selecting the '\(title)' selector by its visible label selects tab view \(identifier)",
                  "Selecting the '\(title)' selector did not transition to tab view \(identifier).")
        }
        guard selectTab("Engines", identifier: "xodus.settings.tab.engines") else {
            try fail("Could not return to the identified Engines tab.")
        }

        let pickerID = "xodus.settings.engine.picker"
        let refreshID = "xodus.settings.engine.refresh"
        guard let picker = identified(pickerID), identified(refreshID) != nil else {
            try fail("Settings Engine picker or Refresh control is missing its accessibility identifier.")
        }
        print("PASS: Engine picker and Refresh control expose their identifiers")

        guard AXUIElementSetAttributeValue(picker, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              waitUntil({ value(app, kAXFocusedUIElementAttribute).map { CFEqual($0, picker) } == true }) else {
            try fail("Could not focus the identified Engine picker through Accessibility.")
        }

        if let window = settingsWindow(),
           let advancedTab = descendants(of: window).first(where: {
               value($0, kAXRoleAttribute) as? String == kAXButtonRole
                   && value($0, kAXTitleAttribute) as? String == "Advanced"
           }),
           AXUIElementPerformAction(advancedTab, kAXPressAction as CFString) == .success,
           waitUntil({ identified("xodus.settings.tab.advanced") != nil }),
           let market = identified("xodus.settings.catalog.market"),
           let language = identified("xodus.settings.catalog.language"),
           AXUIElementSetAttributeValue(market, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
           waitUntil({ value(app, kAXFocusedUIElementAttribute).map { CFEqual($0, market) } == true }) {
            try press(CGKeyCode(kVK_Tab))
            check(waitUntil({
                value(app, kAXFocusedUIElementAttribute).map { CFEqual($0, language) } == true
            }), "Tab moves focus between the Advanced tab's Market and Language text fields",
            "Tab did not move focus between the Advanced text fields under the current macOS keyboard-navigation setting.")
        } else {
            check(false, "Tab moves focus between the Advanced tab's Market and Language text fields",
                  "Could not identify and focus the Advanced tab's Market and Language text fields.")
        }

        try press(CGKeyCode(kVK_Escape))
        let dismissed = waitUntil({ settingsWindow() == nil })
        check(dismissed, "Esc dismisses Settings", "Esc did not dismiss the Settings window.")
        print("\(failures == 0 ? "All" : "\(failures) failed; remaining") Settings Accessibility interaction checks.")
        return failures == 0 ? 0 : 1
    }
    for failure in result.failures {
        FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
    }
    return result.status
}

let status = CommandLine.arguments.dropFirst().first == "--cleanup-self-check"
    ? runCleanupSelfChecks()
    : runAccessibilityScenario()
exit(status)
