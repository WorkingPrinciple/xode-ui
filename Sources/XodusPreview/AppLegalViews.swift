// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum AppLegalCopy {
    static let license = "GNU General Public License version 3 (GPL-3.0-only)"
    static let source = URL(string: "https://github.com/dragoshont/xodus-macos-app")!
    static let licenseText = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let acknowledgment = "\(AppBrand.displayName) manages games through a fork of the Xodus game-management project (xodus-gaming, GPL-3.0). We thank its contributors and the authors of the open-source components used by the app."
    static let d3dMetal = "Calimocho bundles Apple D3DMetal under Apple's non-commercial license. It's downloaded separately from this app, not included in it."
    static let trademarks = "The names \(AppBrand.displayName) and \(AppBrand.company) and their logos aren't licensed by the GPL. Modified versions must use a different name and be marked as modified."
}

struct AppLicensesView: View {
    var body: some View {
        Form {
            Section {
                Text("Licenses").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                LabeledContent("\(AppBrand.displayName)", value: AppLegalCopy.license)
                Text(AppBrand.copyright).foregroundStyle(.secondary)
                Text("The original app source, documentation and artwork are licensed under GPL version 3 only.")
                    .foregroundStyle(.secondary)
                Text(AppLegalCopy.trademarks).foregroundStyle(.secondary)
                Text(AppLegalCopy.d3dMetal).foregroundStyle(.secondary)
                Link("Read the license", destination: AppLegalCopy.licenseText)
                Link("View source code", destination: AppLegalCopy.source)
            }
            Section("Games and other software") {
                Text("Games and third-party software keep their own licenses. The app's license does not grant ownership of games or permission to redistribute them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360)
    }
}

struct AppAcknowledgmentsView: View {
    var body: some View {
        Form {
            Section {
                Text("Acknowledgments").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(AppLegalCopy.acknowledgment)
                Text("Original authors and third-party components retain their copyrights, license terms and required notices.")
                    .foregroundStyle(.secondary)
            }
            Section("\(AppBrand.displayName)") {
                Link("Source and license notices", destination: AppLegalCopy.source)
                Text(AppLegalCopy.license).foregroundStyle(.secondary)
            }
            Section("Wine and Calimocho") {
                Text("Calimocho is a Wine-based engine distributed separately. Wine is licensed under LGPL-2.1-or-later, and Calimocho keeps Wine's license and notices.")
                    .foregroundStyle(.secondary)
                Text(AppLegalCopy.d3dMetal).foregroundStyle(.secondary)
            }
            Section("Trademarks") {
                Text("CrossOver is a trademark of CodeWeavers, Inc. \(AppBrand.displayName) doesn't include CrossOver. Microsoft, Xbox, Xbox Live and PC Game Pass are trademarks of the Microsoft group of companies.")
                    .foregroundStyle(.secondary)
                Text("Game names, artwork, trailers and descriptions belong to their publishers and are shown from Microsoft Store catalog information.")
                    .foregroundStyle(.secondary)
            }
            Section("Python") {
                Text("The app includes CPython 3.14.8. Its license and notices are retained with the bundled runtime.")
                    .foregroundStyle(.secondary)
                Link("Python license", destination: URL(string: "https://docs.python.org/3/license.html")!)
            }
            Section("Anti-cheat references") {
                Text("The offline catalogue includes technology-name references from AreWeAntiCheatYet, MIT licensed, copyright 2021 Starz0r and Curve. Its Linux/Steam compatibility verdicts are not Mac or Microsoft Store verdicts and are not imported.")
                    .foregroundStyle(.secondary)
                Link("Dataset source and MIT license",
                     destination: URL(string: "https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet")!)
                Text("The complete MIT notice is distributed in CompatibilityData/AWACY-LICENSE.txt in the app resource bundle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360)
    }
}
