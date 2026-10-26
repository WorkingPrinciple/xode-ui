// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// REQ-19: colours X Ode chooses itself, picked to reach WCAG 4.5:1 text contrast on window, grouped-form and
/// search-field backings in light and dark appearance (system link blue measured 3.74:1 and the search
/// placeholder 2.6:1). Semantic `.secondary` text stays system-owned.
enum AccessiblePalette {
    struct RGB: Equatable {
        let red, green, blue: Int
        var color: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    static let linkLight = RGB(red: 0x00, green: 0x58, blue: 0xC4)
    static let linkDark = RGB(red: 0x6C, green: 0xB4, blue: 0xFF)
    static let placeholderLight = RGB(red: 0x59, green: 0x59, blue: 0x59)
    static let placeholderDark = RGB(red: 0xB8, green: 0xB8, blue: 0xB8)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    static let link = NSColor(name: "XodusAccessibleLink") { isDark($0) ? linkDark.color : linkLight.color }
    static let placeholder = NSColor(name: "XodusAccessiblePlaceholder") {
        isDark($0) ? placeholderDark.color : placeholderLight.color
    }
}

extension View {
    /// Link text in X Ode's accessible link colour instead of the system link blue.
    func accessibleLink() -> some View {
        foregroundStyle(Color(nsColor: AccessiblePalette.link)).tint(Color(nsColor: AccessiblePalette.link))
    }
}
