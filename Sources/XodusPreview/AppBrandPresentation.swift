// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

/// Module-wide name so every XodusPreview file can use the brand without importing XodusCore.
typealias AppBrand = XodusCore.AppBrand
typealias AppVersion = XodusCore.AppVersion

/// X Ode's own colours (owner decision W1, 27 Oct): the unchanged XOdeMark in burgundy on a white tile, in light
/// and dark appearance (10.1:1). Nothing in the brand uses Xbox green. Fills and text that sit on window
/// backgrounds adapt so they stay legible in dark appearance.
enum OdeBrand {
    struct RGB: Equatable {
        let red, green, blue: Int
        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    static let burgundy = RGB(red: 0x7A, green: 0x1E, blue: 0x3A)
    static let wine = RGB(red: 0xB2, green: 0x3A, blue: 0x48)
    static let rose = RGB(red: 0xEE, green: 0x97, blue: 0xA9)

    private static func adaptive(_ name: String, light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        })
    }

    /// The mark itself, always on the white tile.
    static let mark = Color(nsColor: burgundy.nsColor)
    static let tile = Color.white
    /// Button and progress fills: white labels on them stay at 5.8:1 or more; the fill keeps 3:1 against dark windows.
    static let tint = adaptive("XOdeBrandTint", light: burgundy, dark: wine)
    /// Text and symbols on window backgrounds: 8:1 in light, 5.2:1 or more in dark.
    static let accent = adaptive("XOdeBrandAccent", light: burgundy, dark: rose)
    static let gradient = LinearGradient(colors: [Color(nsColor: wine.nsColor), Color(nsColor: burgundy.nsColor)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The logo lockup: the X mark with the "Ode" wordmark beneath it, announced once as "X Ode".
struct XOdeLockup: View {
    static var accessibilityName: String { AppBrand.displayName }
    var markSize: CGFloat = 112
    var markStyle: AnyShapeStyle = AnyShapeStyle(OdeBrand.mark)
    var wordmarkFont: Font = .largeTitle.weight(.medium)
    var markBackground: AnyShapeStyle? = AnyShapeStyle(OdeBrand.tile)

    var body: some View {
        VStack(spacing: markSize >= 80 ? 12 : 8) {
            Group {
                if let markBackground {
                    XOdeLogo().fill(markStyle)
                        .frame(width: markSize, height: markSize).padding(markSize * 0.3)
                        .background(markBackground, in: RoundedRectangle(cornerRadius: markSize * 0.375))
                        // A faint edge so the white tile doesn't vanish on a white window.
                        .overlay(RoundedRectangle(cornerRadius: markSize * 0.375).strokeBorder(.primary.opacity(0.12)))
                } else {
                    XOdeLogo().fill(markStyle).frame(width: markSize, height: markSize)
                }
            }
            Text(AppBrand.wordmark).font(wordmarkFont)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityName)
    }
}

enum AppBrandPresentation {
    static let supportWindowID = "support"

    /// Options for the standard About panel: "X Ode", "Version 0.2.0 Beta (412)", "© Working Principle".
    static func aboutPanelOptions(_ version: AppVersion = AppBrand.current) -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSAttributedString(string: FeaturedCredits.aboutLine + "\n" + AppBrand.copyright, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return [.applicationName: AppBrand.displayName,
                .applicationVersion: version.aboutVersion,
                .version: version.build ?? "",
                .credits: credits]
    }

    static func orderFrontAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions())
    }
}

/// Help ▸ X Ode Beta Support and Help ▸ Send Feedback. No external support address is shown
/// until one is verified; feedback goes through the redacted diagnostic summary.
struct BetaSupportView: View {
    var openDiagnostics: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBrand.supportTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Version \(AppBrand.versionLabel)").foregroundStyle(.secondary)
                }
                Text("This is an early beta. Some games may not start, and features can change between builds.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Report a problem or send feedback") {
                Text("Save a redacted diagnostic summary, then send it with a short description of what happened to the person who invited you to the beta.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("The summary leaves out passwords, sign-in tokens and raw engine logs. You can read it before saving.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Prepare Diagnostic Summary…", action: openDiagnostics)
                    .accessibilityIdentifier("xodus.support.diagnostics")
            }
            Section {
                Text(AppBrand.copyright).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        .accessibilityIdentifier("xodus.support")
    }
}

/// The main window's game-search action, published only while that window is the focused scene.
struct GameSearchFocusKey: FocusedValueKey {
    typealias Value = GameSearchFocus
}

struct GameSearchFocus {
    let focus: () -> Void
}

extension FocusedValues {
    var gameSearchFocus: GameSearchFocus? {
        get { self[GameSearchFocusKey.self] }
        set { self[GameSearchFocusKey.self] = newValue }
    }
}

/// Edit ▸ Find… (⌘F) for game search. It sits before the system text-editing group, which keeps
/// Find, Spelling, Substitutions, Transformations and Speech, and it is enabled only while the main
/// window is focused, so it never pulls focus away from Settings, Licenses or Support.
struct GameSearchCommands: Commands {
    let navigationAllowed: Bool
    @FocusedValue(\.gameSearchFocus) private var search

    var body: some Commands {
        CommandGroup(before: .textEditing) {
            Button("Find…") { search?.focus() }
                .keyboardShortcut("f")
                .disabled(search == nil || !navigationAllowed)
            Divider()
        }
    }
}
