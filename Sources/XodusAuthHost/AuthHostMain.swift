// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation
import Darwin
import Foundation

@main
struct AuthHostMain {
    @MainActor static func main() {
#if !XODUS_SHIPPING
        if CommandLine.arguments.dropFirst() == ["--self-check"] {
            Task { exit(await AuthHostChecks.run() ? 0 : 1) }
            CFRunLoopRun()
            exit(1)
        }
        if CommandLine.arguments.dropFirst() == ["--self-check-peer"] {
            Task { exit(await AuthHostChecks.peer()) }
            CFRunLoopRun()
            exit(1)
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--self-check-window-close-peer",
           ["performClose", "close"].contains(CommandLine.arguments[2]) {
            Task { exit(await AuthHostChecks.windowClosePeer(CommandLine.arguments[2])) }
            CFRunLoopRun()
            exit(1)
        }
#endif
        guard CommandLine.arguments.count == 1 else { exit(64) }
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        guard setrlimit(RLIMIT_CORE, &limit) == 0 else { exit(1) }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0, dup2(null, STDOUT_FILENO) >= 0, dup2(null, STDERR_FILENO) >= 0 else { exit(1) }
        Darwin.close(null)
        do {
            let channel = try PrivateChannel(descriptor: STDIN_FILENO)
            let inertInput = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard inertInput >= 0, dup2(inertInput, STDIN_FILENO) >= 0 else { exit(1) }
            Darwin.close(inertInput)
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let controller = AuthHostController(channel: channel)
            application.delegate = controller
            controller.start()
            withExtendedLifetime(controller) { application.run() }
        } catch { exit(1) }
    }
}

@MainActor
final class AuthHostController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let channel: PrivateChannel
    private var session = HostSession()
    private var browser: NativeAuthBrowser?
    private var window: NSWindow?
    private var readTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var outputFailed = false
    private var ending = false
    private var workerUnavailable = false

    init(channel: PrivateChannel) { self.channel = channel }

#if !XODUS_SHIPPING
    func openNeutralWindowForChecks(_ frame: CommandFrame) async throws -> NSWindow {
        guard case .open = frame.command else { throw HostFailure.protocolInvalid }
        try session.accept(frame)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        try await send(.ready)
        return window
    }
#endif

    func start() {
        readTask = Task {
            do {
                let first = try await channel.read(deadline: .now.advanced(by: .seconds(5)))
                try await accept(CommandFrame(first))
                while !ending {
                    guard let deadline = session.deadline else { throw HostFailure.protocolInvalid }
                    let data = try await channel.read(deadline: deadline)
                    if ending { return }
                    try await accept(CommandFrame(data))
                }
            } catch let failure as HostFailure {
                if failure == .channelClosed { workerUnavailable = true }
                await finish(failure: failure)
            } catch { await finish(failure: .protocolInvalid) }
        }
    }

    private func accept(_ frame: CommandFrame) async throws {
        try session.accept(frame)
        switch frame.command {
        case .open(_, let request, let userAgent):
            guard let deadline = session.deadline else { throw HostFailure.protocolInvalid }
            deadlineTask = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                await finish(failure: .deadlineExpired)
            }
            let browser = NativeAuthBrowser(
                trust: BrowserTrust(navigation: HostPolicy.navigation, bridge: HostPolicy.bridge,
                                    finish: HostPolicy.finish),
                received: { [weak self] data in self?.received(data) },
                failed: { [weak self] failure in self?.browserFailed(failure) })
            self.browser = browser
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Microsoft sign-in"
            window.minSize = NSSize(width: 420, height: 480)
            window.contentView = browser.view
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
            try await send(.ready)
            guard !ending else { return }
            guard ContinuousClock.now < deadline else { throw HostFailure.deadlineExpired }
            try browser.load(request, userAgent: userAgent)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        case .navigate(let url):
            guard let browser else { throw HostFailure.protocolInvalid }
            try await drainOutput()
            try await send(.ready)
            guard !ending else { return }
            guard let deadline = session.deadline, ContinuousClock.now < deadline else {
                throw HostFailure.deadlineExpired
            }
            try browser.load(URLRequest(url: url), userAgent: HostPolicy.userAgent)
        case .close(let disposition):
            ending = true
            stopView()
            do {
                try await drainOutput()
                try await send(.closed(disposition))
            }
            catch { await channel.stop(); exit(1) }
            await channel.stop()
            exit(disposition.exitCode)
        }
    }

    private func received(_ data: LegacyDA) {
        guard !ending, !workerUnavailable else { return }
        let previous = outputTask
        outputTask = Task {
            await previous?.value
            guard !ending, !workerUnavailable else { return }
            do { try await send(.da(data)) }
            catch let failure as HostFailure {
                outputFailed = true
                await finish(failure: failure)
            }
            catch {
                outputFailed = true
                await finish(failure: .protocolInvalid)
            }
        }
    }

    private func browserFailed(_ failure: HostFailure) {
        guard !ending else { return }
        Task { await finish(failure: failure) }
    }

    private func send(_ result: HostResult) async throws {
        guard !workerUnavailable else { throw HostFailure.channelClosed }
        let data = try session.encode(result)
        let deadline: ContinuousClock.Instant
        switch result {
        case .failed, .cancelled:
            deadline = .now.advanced(by: .milliseconds(250))
        case .closed:
            deadline = min(session.deadline ?? .now, .now.advanced(by: .milliseconds(500)))
        default:
            deadline = min(session.deadline ?? .now, .now.advanced(by: .seconds(2)))
        }
        try await channel.write(data, deadline: deadline)
    }

    private func drainOutput() async throws {
        try await HostOutputFence.drain(outputTask, failed: { outputFailed })
        guard !workerUnavailable else { throw HostFailure.channelClosed }
    }

    private func stopView() {
        deadlineTask?.cancel()
        browser?.close()
        window?.delegate = nil
        window?.close()
        window = nil
        browser = nil
    }

    private func finish(failure: HostFailure) async {
        guard !ending else { return }
        ending = true
        stopView()
        outputTask?.cancel()
        if !workerUnavailable, session.flowID != nil, !session.terminal {
            do { try await send(failure == .cancelled ? .cancelled : .failed(failure)) }
            catch { await channel.stop(); exit(1) }
        }
        await channel.stop()
        exit(failure == .cancelled ? 2 : 1)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard !ending else { return true }
        Task { await finish(failure: .cancelled) }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let sender = notification.object as? NSWindow, sender === window, !ending else { return }
        Task { await finish(failure: .cancelled) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ending { return .terminateNow }
        Task { await finish(failure: .cancelled) }
        return .terminateLater
    }
}
