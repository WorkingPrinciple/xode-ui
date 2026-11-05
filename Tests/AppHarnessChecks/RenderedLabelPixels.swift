// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import XCTest
@testable import XodusPreview

@MainActor
func assertRenderedLabels(_ bitmap: CGImage, _ labels: [RenderedLabel],
                          textRegion: CGRect? = nil, allowOtherInk: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) throws {
    for failure in try renderedLabelFailures(bitmap, labels, textRegion: textRegion,
                                             allowOtherInk: allowOtherInk) {
        XCTFail(failure, file: file, line: line)
    }
}
