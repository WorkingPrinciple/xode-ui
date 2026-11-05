// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import GameController
import SwiftUI
import XCTest
@testable import XodusPreview

final class LibraryControllerChecks: XCTestCase {
    @MainActor func testMonitoringMatchesConnectedControllersAndRetainsSubscribers() {
        let input = LibraryControllerInput()
        input.start()
        input.start()
        let actualCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        XCTAssertEqual(input.connectedCount, actualCount)
        XCTAssertEqual(input.hint != nil, actualCount > 0)
        input.stop()
        XCTAssertTrue(input.isMonitoring)
        input.stop()
        XCTAssertFalse(input.isMonitoring)
        XCTAssertNil(input.hint)
    }

    @MainActor func testNativeWindowAnchorsRemainIndependentAndInactive() async throws {
        _ = NSApplication.shared
        let first = LibraryControllerWindow()
        let second = LibraryControllerWindow()
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); secondWindow.close() }
        firstWindow.contentView = NSHostingView(rootView: LibraryControllerWindowAnchor(focus: first))
        secondWindow.contentView = NSHostingView(rootView: LibraryControllerWindowAnchor(focus: second))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while first.window == nil || second.window == nil {
            firstWindow.contentView?.layoutSubtreeIfNeeded()
            secondWindow.contentView?.layoutSubtreeIfNeeded()
            guard ContinuousClock.now < deadline else {
                XCTFail("Detached native window anchors did not attach")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(first.window === firstWindow)
        XCTAssertTrue(second.window === secondWindow)
        XCTAssertFalse(first.permitsNavigation())
        XCTAssertFalse(second.permitsNavigation())
        XCTAssertFalse(first.permitsDetailDismissal())
        XCTAssertFalse(second.permitsDetailDismissal())
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertFalse(secondWindow.isVisible)
    }

    func testDirectionalNavigationAndUnmappedHints() {
        let sections: [LibraryControllerNavigation.Section] = [
            .init(ids: ["recent-1", "recent-2"], columns: 2),
            .init(ids: ["a", "b", "c", "d", "e"], columns: 3),
            .init(ids: ["local", "native"], columns: 3)
        ]
        XCTAssertEqual(LibraryControllerNavigation.target(current: "recent-2", move: .down, sections: sections), "b")
        XCTAssertEqual(LibraryControllerNavigation.target(current: "c", move: .down, sections: sections), "e")
        XCTAssertEqual(LibraryControllerNavigation.target(current: "native", move: .up, sections: sections), "e")
        XCTAssertNil(LibraryControllerNavigation.target(current: nil, move: .down, sections: []))
        XCTAssertEqual(LibraryControllerHint(direction: nil, activate: nil, back: nil).labels,
                       ["Directional pad name unavailable", "View details button name unavailable",
                        "Close Library details button name unavailable"])
    }

    func testLostLazyFocusDoesNotRestartNavigation() {
        let sections: [LibraryControllerNavigation.Section] = [
            .init(ids: ["a", "b", "c"], columns: 3)
        ]
        var focus = LibraryControllerFocus()
        focus.appeared("a")
        focus.observeFocus("a")
        XCTAssertEqual(focus.move(.right, focused: "a", sections: sections), "b")
        XCTAssertFalse(focus.isReady("b"))
        focus.observeFocus(nil)
        XCTAssertEqual(focus.move(.right, focused: nil, sections: sections), "c",
                       "A lost SwiftUI focus assignment must not reset the controller cursor")
        focus.appeared("b")
        XCTAssertFalse(focus.isReady("b"), "A superseded card must not steal focus")
        focus.appeared("c")
        XCTAssertTrue(focus.isReady("c"), "Focus is retried when the requested lazy card appears")
        focus.observeFocus("c")
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "c")
    }

    func testKeyboardFocusSupersedesPendingControllerTarget() {
        let sections: [LibraryControllerNavigation.Section] = [
            .init(ids: ["a", "b", "c"], columns: 3)
        ]
        var focus = LibraryControllerFocus()
        focus.observeFocus("a")
        XCTAssertEqual(focus.move(.right, focused: "a", sections: sections), "b")
        focus.observeFocus("c")
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "c")
        focus.appeared("b")
        XCTAssertFalse(focus.isReady("b"))
    }

    func testNonCardFocusCancelsPendingControllerTarget() {
        let sections: [LibraryControllerNavigation.Section] = [
            .init(ids: ["a", "b"], columns: 2)
        ]
        var focus = LibraryControllerFocus()
        focus.observeFocus("a")
        XCTAssertEqual(focus.move(.right, focused: "a", sections: sections), "b")
        focus.observeFocus(nil)
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "b", "The controller cursor survives a cancelled focus request")
        focus.appeared("b")
        XCTAssertFalse(focus.isReady("b"))
    }

    func testReturningToOriginalCardDoesNotRestorePendingTarget() {
        let sections: [LibraryControllerNavigation.Section] = [
            .init(ids: ["a", "b"], columns: 2)
        ]
        var focus = LibraryControllerFocus()
        focus.observeFocus("a")
        XCTAssertEqual(focus.move(.right, focused: "a", sections: sections), "b")
        focus.observeFocus(nil)
        focus.observeFocus("a")
        focus.appeared("b")
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "a")
        XCTAssertFalse(focus.isReady("b"))
    }

    @MainActor func testWindowInputSupersedesPendingNonCardFocusWithoutStealingEvents() throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let window = LibraryControllerWindow()
        window.window = first
        defer { window.window = nil }
        XCTAssertTrue(window.isMonitoringInput)
        let firstKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: first.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        let otherKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: second.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: first.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let sections: [LibraryControllerNavigation.Section] = [.init(ids: ["a", "b"], columns: 2)]
        var focus = LibraryControllerFocus()
        XCTAssertEqual(focus.move(.right, focused: nil, sections: sections,
                                  inputGeneration: window.inputGeneration), "a")
        focus.appeared("a")
        XCTAssertTrue(focus.mayAssign("a", inputGeneration: window.inputGeneration))
        XCTAssertTrue(window.observe(otherKey) === otherKey)
        XCTAssertTrue(focus.mayAssign("a", inputGeneration: window.inputGeneration))
        XCTAssertTrue(window.observe(firstKey) === firstKey)
        XCTAssertFalse(focus.mayAssign("a", inputGeneration: window.inputGeneration))
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "a")

        XCTAssertEqual(focus.move(.right, focused: nil, sections: sections,
                                  inputGeneration: window.inputGeneration), "b")
        focus.appeared("b")
        XCTAssertTrue(focus.mayAssign("b", inputGeneration: window.inputGeneration))
        XCTAssertTrue(window.observe(click) === click)
        focus.cancelRequestIfSuperseded(by: window.inputGeneration)
        XCTAssertNil(focus.pendingTarget)
        XCTAssertEqual(focus.target, "b")
        XCTAssertFalse(focus.mayAssign("b", inputGeneration: window.inputGeneration))
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
        window.window = nil
        XCTAssertFalse(window.isMonitoringInput)
    }

    @MainActor func testControllerColumnsMatchAdaptiveGridLayout() async throws {
        for width: CGFloat in [170, 363, 364, 387, 388, 557, 558, 800, 1200] {
            let capture = GridFrameCapture()
            let host = NSHostingView(rootView: GridLayoutProbe(width: width, capture: capture))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while capture.frames.count < 12 {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Grid frames were not rendered at width \(width)")
                    window.close()
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let firstRow = capture.frames.values.filter { abs($0.minY) < 1 }.count
            XCTAssertEqual(LibraryGridLayout.controllerColumns(width: width), firstRow,
                           "Controller columns must match the rendered grid at width \(width)")
            window.close()
        }
    }

    @MainActor func testControllerScrollMaterializesRequestedLazyCardWithoutActivation() async throws {
        let capture = LazyFocusCapture()
        let host = NSHostingView(rootView: LazyFocusProbe(capture: capture))
        host.frame = NSRect(x: 0, y: 0, width: 388, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capture.appeared.isEmpty {
            guard ContinuousClock.now < firstDeadline else {
                XCTFail("Initial lazy cards did not appear")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(capture.appeared.contains(90))
        capture.request = 90
        let scrollDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !capture.appeared.contains(90) {
            guard ContinuousClock.now < scrollDeadline else {
                XCTFail("The requested lazy card was not materialized")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(capture.focusAttempts.contains(90), "The materialized target triggers a focus retry")
        // An inactive window cannot establish keyboard focus.
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor private final class GridFrameCapture {
    var frames: [Int: CGRect] = [:]
}

private struct GridFramePreference: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct GridLayoutProbe: View {
    let width: CGFloat
    let capture: GridFrameCapture

    var body: some View {
        LazyVGrid(columns: LibraryGridLayout.columns, spacing: 30) {
            ForEach(0..<12, id: \.self) { index in
                Color.clear.frame(height: 30).background(GeometryReader { geometry in
                    Color.clear.preference(key: GridFramePreference.self,
                        value: [index: geometry.frame(in: .named("grid"))])
                })
            }
        }

        .frame(width: width)
        .coordinateSpace(name: "grid")
        .onPreferenceChange(GridFramePreference.self) { capture.frames = $0 }
    }
}

@MainActor private final class LazyFocusCapture: ObservableObject {
    @Published var request: Int?
    var appeared: Set<Int> = []
    var focusAttempts: [Int] = []
}

private struct LazyFocusProbe: View {
    @ObservedObject var capture: LazyFocusCapture
    @State private var scrollID: Int?
    @State private var controllerFocus = LibraryControllerFocus()
    @FocusState private var focused: Int?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LibraryGridLayout.columns, spacing: 30) {
                ForEach(0..<100, id: \.self) { index in
                    Button("Game \(index)") {}
                        .frame(height: 100)
                        .focused($focused, equals: index)
                        .id(index)
                        .onAppear {
                            capture.appeared.insert(index)
                            controllerFocus.appeared(String(index))
                            retryFocus(index)
                        }
                        .onDisappear { controllerFocus.disappeared(String(index)) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollID)
        .onChange(of: capture.request) { _, requested in
            guard let requested else { return }
            controllerFocus.request(String(requested), focused: focused.map(String.init))
            scrollID = requested
            retryFocus(requested)
        }
        .onChange(of: focused) { _, current in controllerFocus.observeFocus(current.map(String.init)) }
    }

    private func retryFocus(_ index: Int) {
        guard controllerFocus.isReady(String(index)) else { return }
        capture.focusAttempts.append(index)
        focused = index
    }
}
