// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum AppLegalCopy {
    static let license = "GNU General Public License version 3 (GPL-3.0-only)"
    static let source = URL(string: "https://github.com/WorkingPrinciple/xode-ui")!
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

