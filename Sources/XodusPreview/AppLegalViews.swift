// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum AppLegalCopy {
    static let license = "GNU General Public License version 3 (GPL-3.0-only)"
    static let source = URL(string: "https://github.com/dragoshont/xodus-macos-app")!
    static let licenseText = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let acknowledgment = "Ode to X integrates with the Xodus game-management project. We thank its contributors and the authors of the open-source components used by the app."
}

struct AppLicensesView: View {
    var body: some View {
        Form {
            Section {
                Text("Licenses").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                LabeledContent("Ode to X", value: AppLegalCopy.license)
                Text("The original app source, documentation and artwork are licensed under GPL version 3 only.")
                    .foregroundStyle(.secondary)
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
            Section("Ode to X") {
                Link("Source and license notices", destination: AppLegalCopy.source)
                Text(AppLegalCopy.license).foregroundStyle(.secondary)
            }
            Section("Python") {
                Text("The app includes CPython 3.14.8. Its license and notices are retained with the bundled runtime.")
                    .foregroundStyle(.secondary)
                Link("Python license", destination: URL(string: "https://docs.python.org/3/license.html")!)
            }
        }
        .formStyle(.grouped).padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360)
    }
}
