// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

/// Module-wide name so every XodusPreview file can use the brand without importing XodusCore.
typealias AppBrand = XodusCore.AppBrand

enum AppBrandPresentation {
    static let supportWindowID = "support"

    /// Options for the standard About panel; the version comes from AppBrand, not a stale bundle value.
    static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSAttributedString(string: AppBrand.copyright, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return [.applicationName: AppBrand.displayName,
                .applicationVersion: AppBrand.versionLabel,
                .credits: credits]
    }

    static func orderFrontAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions)
    }
}

/// Help ▸ Xode Beta Support and Help ▸ Send Feedback. No external support address is shown
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
