// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XCTest
@testable import XodusPreview

final class LibraryCollectionScrollingChecks: XCTestCase {
    @MainActor
    func testCollectionRowUsesAnUnmodifiedNativeHorizontalScrollView() throws {
        let host = NSHostingView(rootView: LibraryGamesRow { EmptyView() })
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 650, height: 400)
        host.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertNil(host.window, "The component check must not acquire shared host input.")
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/XodusPreview/\(name).swift"),
                          encoding: .utf8)
    }

    func testEveryLibraryCollectionUsesTheHorizontalRowWithoutTruncation() throws {
        let view = try source("LiveLibraryView")
        XCTAssertEqual(view.components(separatedBy: "LibraryGamesRow {").count - 1, 2)
        XCTAssertFalse(view.contains("LazyVGrid"), "The actual games collection must not wrap vertically.")
        XCTAssertTrue(view.contains(#"ForEach(visible) { game in card(game).id("library-card-\(game.id)") }"#))
        XCTAssertTrue(view.contains(#"ForEach(visibleLocalRecords) { game in card(game).id("library-local-\(game.id)") }"#))
        XCTAssertTrue(view.contains(#"}.id("library-native-minecraft")"#))
        XCTAssertTrue(view.contains(#".accessibilityIdentifier("xodus.library.games")"#))
        XCTAssertTrue(view.contains(#".accessibilityIdentifier("xodus.library.installedGames")"#))
    }

    func testCollectionRowKeepsNativeScrollingAndIncumbentCardGeometry() throws {
        let presentation = try source("LibraryPresentation")
        let row = try XCTUnwrap(presentation.range(of: "struct LibraryGamesRow"))
        let end = try XCTUnwrap(presentation.range(of: "struct ContinuePlayingScrollView"))
        let implementation = String(presentation[row.lowerBound..<end.lowerBound])
        XCTAssertTrue(implementation.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(implementation.contains("LazyHStack(alignment: .top, spacing: 24)"))
        XCTAssertTrue(implementation.contains(".frame(width: 200, alignment: .topLeading)"))
        XCTAssertTrue(implementation.contains(".scrollTargetLayout()"))
        XCTAssertTrue(implementation.contains(".scrollTargetBehavior(.viewAligned)"))
        XCTAssertFalse(implementation.contains(".gesture"))
        XCTAssertFalse(implementation.contains(".onKeyPress"))
        XCTAssertFalse(implementation.contains(".scrollIndicators"))
        XCTAssertFalse(implementation.contains("ContinuePlayingScrollerIntegration"))
    }
}
