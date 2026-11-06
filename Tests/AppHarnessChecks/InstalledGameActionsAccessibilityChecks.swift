// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XCTest
@testable import XodusPreview

final class InstalledGameActionsAccessibilityChecks: XCTestCase {
    @MainActor
    func testTitleSpecificLabelKeepsBothActionsVariantsIconSized() {
        let library = InstalledGamesController()
        let operations = GameOperationsController(installed: library)
        for title in ["Brotato", "A longer installed game title"] {
            let game = InstalledGame(id: UUID(), title: title, identityName: "", version: "",
                storeId: "", folder: "", launcher: "", importedAt: .distantPast)
            for heroStyle in [false, true] {
                let host = NSHostingView(rootView: InstalledGameActions(library: library,
                    operations: operations, game: game, usesGlass: true, heroStyle: heroStyle))
                host.frame = CGRect(x: 0, y: 0, width: 180, height: 60)
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                XCTAssertLessThan(host.fittingSize.width, 80, "The accessible title must not become visible text.")
                XCTAssertLessThan(host.fittingSize.height, 60)
                XCTAssertNil(host.window)
            }
        }
    }

    @MainActor
    func testNativeActionsMenuHasTitleSpecificAccessibleName() throws {
        let library = InstalledGamesController()
        let operations = GameOperationsController(installed: library)
        let game = InstalledGame(id: UUID(), title: "Brotato", identityName: "", version: "",
            storeId: "9P9VNSQK1W3K", folder: "", launcher: "", importedAt: .distantPast)
        for heroStyle in [false, true] {
            let host = NSHostingView(rootView: InstalledGameActions(library: library,
                operations: operations, game: game, usesGlass: true, heroStyle: heroStyle))
            host.frame = CGRect(x: 0, y: 0, width: 180, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let menus = nativeMenus(in: host)
            guard !menus.isEmpty else {
                throw XCTSkip("Never-shown SwiftUI host has no native accessibility tree; installed AX title/description verification remains required.")
            }
            XCTAssertEqual(menus.count, 1)
            let menu = try XCTUnwrap(menus.first)
            XCTAssertEqual(menu.accessibilityLabel(), "Actions for Brotato")
            XCTAssertEqual(menu.accessibilityTitle(), "Actions for Brotato")
            XCTAssertTrue(menu.isAccessibilityEnabled())
            XCTAssertFalse(window.isVisible, "The source check must never show or activate a window.")
        }
    }

    @MainActor
    private func nativeMenus(in view: NSView) -> [NSAccessibilityProtocol] {
        var result: [NSAccessibilityProtocol] = []
        func visit(_ element: NSAccessibilityProtocol) {
            if element.accessibilityRole() == .menuButton { result.append(element) }
            for child in element.accessibilityChildren() ?? [] {
                if let accessible = child as? NSAccessibilityProtocol { visit(accessible) }
            }
        }
        visit(view)
        return result
    }
}
