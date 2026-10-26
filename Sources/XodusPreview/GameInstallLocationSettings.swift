// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct GameInstallLocationSettings: View {
    @AppStorage(GameInstallLocation.preferenceKey) private var savedLocation = Data()
    @State private var choosing = false
    @State private var error: String?
    @State private var deniedPermission: PrivacyPermission?
    @State private var probe = GameStorageProbe()
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Default install folder") {
                Text(locationLabel).textSelection(.enabled)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose folder…") { Task { await choose() } }
                    .disabled(choosing)
                    .accessibilityIdentifier("xodus.settings.installLocation")
                if !savedLocation.isEmpty {
                    Button("Use original default") {
                        savedLocation = Data()
                        error = nil
                        deniedPermission = nil
                    }.disabled(choosing)
                }
                if choosing { ProgressView("Checking folder").controlSize(.small) }
            }
            Text("New games start here. You can choose another folder before installing. Existing games stay in their recorded locations.")
                .font(.callout).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                if let deniedPermission { OpenPrivacySettingsButton(permission: deniedPermission) }
            }
        }
        .onDisappear { generation = UUID() }
    }

    /// The error shown after a games folder couldn't be used, and the settings link when macOS privacy blocked it.
    static func problem(for error: Error, access: PrivacyDenial.FolderAccess) -> (message: String, permission: PrivacyPermission?) {
        PrivacyDenial.installFolderProblem(access, fallback: "The install folder couldn't be selected. \(error.localizedDescription)")
    }

    private var locationLabel: String {
        do {
            return try GameInstallLocation.decode(savedLocation)?.folder ?? GameScriptPaths.production.games.path
        } catch { return "Saved folder couldn't be read. Choose the folder again." }
    }

    private func choose() async {
        guard !choosing else { return }
        choosing = true
        defer { choosing = false }
        let token = UUID()
        generation = token
        let panel = NSOpenPanel()
        panel.title = "Choose the default game install folder"
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, generation == token, let root = panel.url else { return }
        do {
            let location = try await probe.read { try GameInstallLocation(folder: root) }
            guard generation == token else { return }
            savedLocation = try JSONEncoder().encode(location)
            error = nil
            deniedPermission = nil
        } catch {
            guard generation == token else { return }
            // GameInstallLocation reports any permission failure as one error, so probe the raw cause.
            let access = (try? await probe.read { PrivacyDenial.probe(root) }) ?? .other
            let problem = Self.problem(for: error, access: access)
            deniedPermission = problem.permission
            self.error = problem.message
        }
    }
}
