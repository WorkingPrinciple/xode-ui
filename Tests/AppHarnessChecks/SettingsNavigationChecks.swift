// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SwiftUI
@testable import XodusPreview

final class SettingsNavigationChecks: XCTestCase {
    @MainActor
    func testEngineEntrySelectsCanonicalTabBeforeOpeningSettings() {
        let state = AppState()
        state.settingsTab = .account
        state.openAccount(.profile)
        state.showingSetup = true
        var opens = 0
        state.openEngineSettings {
            opens += 1
            XCTAssertEqual(state.settingsTab, .engines)
            XCTAssertFalse(state.showingAccount)
            XCTAssertFalse(state.showingSetup)
            XCTAssertEqual(state.accountDestination, .account)
        }
        XCTAssertEqual(opens, 1)
        state.settingsTab = .advanced
        state.openEngineSettings { opens += 1 }
        XCTAssertEqual(state.settingsTab, .engines, "An already open Settings window must switch back to Engines")
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), ["General", "Engines", "Account", "Advanced"])
        XCTAssertEqual(AccountDestination.allCases.map(\.rawValue), ["Account", "Profile", "Achievements", "My Consoles"])
    }

    @MainActor
    func testCanonicalSettingsShellKeepsEveryTabWithoutOpeningAWindow() {
        let state = AppState()
        let session = LiveSession()
        let windowCount = NSApplication.shared.windows.count
        let host = NSHostingView(rootView: LiveSettingsView()
            .environmentObject(state).environmentObject(session))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 540, height: 450)
        for tab in SettingsTab.allCases {
            state.settingsTab = tab
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(host.window)
            XCTAssertEqual(host.frame.size, CGSize(width: 540, height: 450))
            XCTAssertEqual(NSApplication.shared.windows.count, windowCount)
            XCTAssertNil(session.authentication)
            XCTAssertFalse(session.accountBusy)
        }
    }
}
