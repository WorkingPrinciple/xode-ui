// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

/// Module-wide name so every XodusPreview file can use the brand without importing XodusCore.
typealias AppBrand = XodusCore.AppBrand
typealias AppVersion = XodusCore.AppVersion

/// The logo lockup: the X mark with the "Ode" wordmark beneath it, announced once as "X Ode".
struct XOdeLockup: View {
    static var accessibilityName: String { AppBrand.displayName }
    var markSize: CGFloat = 112
    var markStyle: AnyShapeStyle = AnyShapeStyle(XboxBrand.green)
    var wordmarkFont: Font = .largeTitle.weight(.medium)
    var markBackground: AnyShapeStyle? = nil

    var body: some View {
        VStack(spacing: markSize >= 80 ? 12 : 8) {
            Group {
                if let markBackground {
                    XOdeLogo().fill(markStyle)
                        .frame(width: markSize, height: markSize).padding(markSize * 0.3)
                        .background(markBackground, in: RoundedRectangle(cornerRadius: markSize * 0.375))
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
