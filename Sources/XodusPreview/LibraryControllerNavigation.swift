// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import GameController
import os
import SwiftUI

enum LibraryControllerMove: Equatable {
    case left, right, up, down
}

enum LibraryControllerCommand {
    case move(LibraryControllerMove), activate, back
}

struct LibraryControllerAxisState {
    private var horizontal = 0
    private var vertical = 0

    mutating func update(x: Float, y: Float) -> [LibraryControllerMove] {
        let nextHorizontal = x > 0.5 ? 1 : (x < -0.5 ? -1 : 0)
        let nextVertical = y > 0.5 ? 1 : (y < -0.5 ? -1 : 0)
        var moves: [LibraryControllerMove] = []
        if nextHorizontal != horizontal, nextHorizontal != 0 {
            moves.append(nextHorizontal > 0 ? .right : .left)
        }
        if nextVertical != vertical, nextVertical != 0 {
            moves.append(nextVertical > 0 ? .up : .down)
        }
        horizontal = nextHorizontal
        vertical = nextVertical
        return moves
    }
}

enum LibraryControllerNavigation {
    struct Section {
        let ids: [String]
        let columns: Int
    }

    static func target(current: String?, move: LibraryControllerMove, sections: [Section]) -> String? {
        let sections = sections.filter { !$0.ids.isEmpty }
        guard let first = sections.first else { return nil }
        guard let current,
              let sectionIndex = sections.firstIndex(where: { $0.ids.contains(current) }),
              let index = sections[sectionIndex].ids.firstIndex(of: current) else {
            return first.ids.first
        }
        let section = sections[sectionIndex]
        let columns = max(1, section.columns)
        let column = index % columns
        switch move {
        case .left:
            return column > 0 ? section.ids[index - 1] : current
        case .right:
            return column + 1 < columns && index + 1 < section.ids.count ? section.ids[index + 1] : current
        case .up:
            if index >= columns { return section.ids[index - columns] }
            guard sectionIndex > 0 else { return current }
            let previous = sections[sectionIndex - 1]
            let previousColumns = max(1, previous.columns)
            let lastRow = ((previous.ids.count - 1) / previousColumns) * previousColumns
            return previous.ids[min(lastRow + column, previous.ids.count - 1)]
        case .down:
            let nextRow = (index / columns + 1) * columns
            if nextRow < section.ids.count {
                return section.ids[min(nextRow + column, section.ids.count - 1)]
            }
            guard sectionIndex + 1 < sections.count else { return current }
            let next = sections[sectionIndex + 1]
            return next.ids[min(column, next.ids.count - 1)]
        }
    }
}

struct LibraryControllerFocus {
    private(set) var target: String?
    private(set) var pendingTarget: String?
    private var focusAtRequest: String?
    private var inputGenerationAtRequest: UInt64?
    private var materialized: [String: Int] = [:]

    mutating func move(_ direction: LibraryControllerMove, focused: String?,
                       sections: [LibraryControllerNavigation.Section], inputGeneration: UInt64 = 0) -> String? {
        guard let next = LibraryControllerNavigation.target(
            current: pendingTarget ?? focused ?? target, move: direction, sections: sections) else {
            return nil
        }
        request(next, focused: focused, inputGeneration: inputGeneration)
        return next
    }

    mutating func request(_ id: String, focused: String?, inputGeneration: UInt64 = 0) {
        if pendingTarget == nil { focusAtRequest = focused }
        target = id
        pendingTarget = id
        inputGenerationAtRequest = inputGeneration
    }

    mutating func observeFocus(_ id: String?) {
        guard let id else {
            cancelRequest()
            return
        }
        if let pendingTarget {
            if id == pendingTarget, isReady(id) {
                target = id
                cancelRequest()
            } else if id != pendingTarget && id != focusAtRequest {
                target = id
                cancelRequest()
            }
        } else {
            target = id
        }
    }

    mutating func appeared(_ id: String) {
        materialized[id, default: 0] += 1
    }

    mutating func disappeared(_ id: String) {
        guard let count = materialized[id] else { return }
        if count <= 1 { materialized[id] = nil }
        else { materialized[id] = count - 1 }
    }

    func isReady(_ id: String) -> Bool {
        pendingTarget == id && materialized[id, default: 0] > 0
    }

    mutating func mayAssign(_ id: String, inputGeneration: UInt64) -> Bool {
        cancelRequestIfSuperseded(by: inputGeneration)
        return isReady(id)
    }

    mutating func cancelRequestIfSuperseded(by inputGeneration: UInt64) {
        if let inputGenerationAtRequest, inputGenerationAtRequest != inputGeneration {
            cancelRequest()
        }
    }

    mutating func cancelRequest() {
        pendingTarget = nil
        focusAtRequest = nil
        inputGenerationAtRequest = nil
    }
}

struct LibraryControllerHint: Equatable {
    let direction: String?
    let activate: String?
    let back: String?

    var labels: [String] {
        [direction.map { "\($0): Browse games" } ?? "Directional pad name unavailable",
         activate.map { "\($0): View details" } ?? "View details button name unavailable",
         back.map { "\($0): Close Library details" } ?? "Close Library details button name unavailable"]
    }
}

@MainActor
final class LibraryControllerInput: ObservableObject {
    static let shared = LibraryControllerInput()
    @Published private(set) var hint: LibraryControllerHint?
    let commands = PassthroughSubject<LibraryControllerCommand, Never>()
    private(set) var connectedCount = 0
    private(set) var isMonitoring = false
    private var subscribers = 0
    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var axes: [ObjectIdentifier: LibraryControllerAxisState] = [:]
    private var observers: Set<AnyCancellable> = []

    func start() {
        subscribers += 1
        guard !isMonitoring else { return }
        isMonitoring = true
        NotificationCenter.default.publisher(for: .GCControllerDidConnect)
            .merge(with: NotificationCenter.default.publisher(for: .GCControllerDidDisconnect))
            .merge(with: NotificationCenter.default.publisher(for: .GCControllerUserCustomizationsDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.axes.removeAll() }
            }
            .store(in: &observers)
        refresh()
    }

    func stop() {
        guard subscribers > 0 else { return }
        subscribers -= 1
        guard subscribers == 0 else { return }
        for controller in controllers.values { detach(controller) }
        controllers.removeAll()
        axes.removeAll()
        observers.removeAll()
        connectedCount = 0
        hint = nil
        isMonitoring = false
    }

    private func refresh() {
        let available = GCController.controllers().filter { $0.extendedGamepad != nil }
        let identities = Set(available.map(ObjectIdentifier.init))
        for (id, controller) in controllers where !identities.contains(id) {
            detach(controller)
            controllers.removeValue(forKey: id)
            axes.removeValue(forKey: id)
        }
        for controller in available {
            let id = ObjectIdentifier(controller)
            guard controllers[id] == nil, let gamepad = controller.extendedGamepad else { continue }
            controllers[id] = controller
            controller.handlerQueue = .main
            gamepad.dpad.valueChangedHandler = { [weak self, weak controller] _, x, y in
                MainActor.assumeIsolated {
                    guard let self, let controller else { return }
                    self.move(controller, x: x, y: y)
                }
            }
            gamepad.buttonA.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated {
                    guard let self, let controller else { return }
                    self.send(.activate, from: controller)
                }
            }
            gamepad.buttonB.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated {
                    guard let self, let controller else { return }
                    self.send(.back, from: controller)
                }
            }
        }
        connectedCount = controllers.count
        if let controller = available.first { updateHint(controller) }
        else { hint = nil }
    }

    private func detach(_ controller: GCController) {
        controller.extendedGamepad?.dpad.valueChangedHandler = nil
        controller.extendedGamepad?.buttonA.pressedChangedHandler = nil
        controller.extendedGamepad?.buttonB.pressedChangedHandler = nil
    }

    private func move(_ controller: GCController, x: Float, y: Float) {
        let id = ObjectIdentifier(controller)
        guard controllers[id] != nil else { return }
        var state = axes[id] ?? LibraryControllerAxisState()
        let moves = state.update(x: x, y: y)
        axes[id] = state
        for move in moves { send(.move(move), from: controller) }
    }

    private func send(_ command: LibraryControllerCommand, from controller: GCController) {
        guard controllers[ObjectIdentifier(controller)] != nil, NSApp.isActive else { return }
        updateHint(controller)
        commands.send(command)
    }

    private func updateHint(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        hint = LibraryControllerHint(direction: gamepad.dpad.localizedName,
                                     activate: gamepad.buttonA.localizedName,
                                     back: gamepad.buttonB.localizedName)
    }
}

@MainActor
final class LibraryControllerWindow: ObservableObject {
    private static let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "library-controller")
    weak var window: NSWindow? {
        didSet {
            guard oldValue !== window else { return }
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            advanceInputGeneration()
            guard window != nil else { return }
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                MainActor.assumeIsolated { _ = self?.observe(event) }
                return event
            }
            if inputMonitor == nil {
                Self.logger.error("Local input monitoring could not start; controller navigation is disabled.")
            }
        }
    }
    private var inputMonitor: Any?
    private(set) var inputGeneration: UInt64 = 0
    let inputEvents = PassthroughSubject<UInt64, Never>()
    var isMonitoringInput: Bool { inputMonitor != nil }

    isolated deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    func observe(_ event: NSEvent) -> NSEvent {
        guard let window, event.window === window else { return event }
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            advanceInputGeneration()
        default:
            break
        }
        return event
    }

    private func advanceInputGeneration() {
        inputGeneration &+= 1
        inputEvents.send(inputGeneration)
    }

    func permitsNavigation() -> Bool {
        guard isMonitoringInput, NSApp.isActive, NSApp.modalWindow == nil, let window,
              NSApp.keyWindow === window, window.attachedSheet == nil else { return false }
        return true
    }

    func permitsDetailDismissal() -> Bool {
        guard NSApp.isActive, NSApp.modalWindow == nil, let window,
              let sheet = NSApp.keyWindow, sheet.sheetParent === window,
              window.attachedSheet === sheet, sheet.attachedSheet == nil else { return false }
        return true
    }
}

struct LibraryControllerWindowAnchor: NSViewRepresentable {
    let focus: LibraryControllerWindow

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.focus = focus
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        if view.focus !== focus, view.focus?.window === view.window {
            view.focus?.window = nil
        }
        view.focus = focus
        focus.window = view.window
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        if view.focus?.window === view.window { view.focus?.window = nil }
        view.focus = nil
    }

    final class Anchor: NSView {
        weak var focus: LibraryControllerWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus?.window = window
        }
    }
}
