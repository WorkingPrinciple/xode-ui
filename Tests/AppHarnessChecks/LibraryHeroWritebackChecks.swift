// SPDX-License-Identifier: GPL-3.0-only
import Combine
import SwiftUI
import XCTest
@testable import XodusPreview

final class LibraryHeroWritebackChecks: XCTestCase {
    @MainActor
    func testScrollPositionWritebackPublishesOnlyActualHeroChanges() {
        let selection = LibrarySelection()
        let position = Binding<String?>(get: { selection.heroID }, set: { selection.heroID = $0 })
        var notifications = 0
        let subscription = selection.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        for _ in 0..<1_000 { position.wrappedValue = nil }
        XCTAssertEqual(notifications, 0, "An unchanged empty scroll target must not invalidate the Library.")
        position.wrappedValue = "first"
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(selection.heroID, "first")
        for _ in 0..<1_000 { position.wrappedValue = "first" }
        XCTAssertEqual(notifications, 1, "Repeated ScrollView writeback must settle without another graph update.")
        selection.heroID = "second"
        XCTAssertEqual(notifications, 2, "Manual or automatic page changes still update the retained Library.")
        XCTAssertEqual(position.wrappedValue, "second")
        position.wrappedValue = nil
        XCTAssertEqual(notifications, 3, "Removing a real scroll target still publishes.")
        for _ in 0..<1_000 { position.wrappedValue = nil }
        XCTAssertEqual(notifications, 3)
        selection.heroID = "first"
        XCTAssertEqual(notifications, 4)
        XCTAssertEqual(position.wrappedValue, "first")
    }
}
