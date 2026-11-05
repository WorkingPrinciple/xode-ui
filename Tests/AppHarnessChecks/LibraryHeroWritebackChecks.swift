// SPDX-License-Identifier: GPL-3.0-only
import Combine
import SwiftUI
import XCTest
@testable import XodusPreview

final class LibraryHeroWritebackChecks: XCTestCase {
    func testPhysicalHeroPageObservationAtRealViewportWidths() {
        for width in [CGFloat(320), 650, 1200] {
            for index in 0..<6 {
                XCTAssertEqual(HeroPageSnap.pageIndex(contentMinX: -CGFloat(index) * width,
                    pageWidth: width, count: 6), index)
            }
            XCTAssertEqual(HeroPageSnap.pageIndex(contentMinX: -2.49 * width,
                pageWidth: width, count: 6), 2)
            XCTAssertEqual(HeroPageSnap.pageIndex(contentMinX: -2.51 * width,
                pageWidth: width, count: 6), 3)
            XCTAssertEqual(HeroPageSnap.pageIndex(contentMinX: width,
                pageWidth: width, count: 6), 0)
            XCTAssertEqual(HeroPageSnap.pageIndex(contentMinX: -6 * width,
                pageWidth: width, count: 6), 5)
        }
        XCTAssertNil(HeroPageSnap.pageIndex(contentMinX: 0, pageWidth: 0, count: 6))
        XCTAssertNil(HeroPageSnap.pageIndex(contentMinX: .nan, pageWidth: 1200, count: 6))
        XCTAssertNil(HeroPageSnap.pageIndex(contentMinX: 0, pageWidth: .infinity, count: 6))
        XCTAssertNil(HeroPageSnap.pageIndex(contentMinX: 0, pageWidth: 1200, count: 0))
    }

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
