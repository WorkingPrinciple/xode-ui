// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// The engine a detail sheet describes (COR-279 step 3).
enum EngineDetail: Identifiable, Equatable {
    case engine(EngineChoice)
    case crossOver
    case highball
    case user(UserEngine)

    var id: String {
        switch self {
        case .engine(let choice): "engine:" + choice.id
        case .crossOver: "crossover"
        case .highball: "highball"
        case .user(let engine): "user:" + engine.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .engine(let choice): choice.name
        case .crossOver: "CrossOver"
        case .highball: "Highball"
        case .user(let engine): engine.name
        }
    }

    /// Which games the engine runs, in the words the sheet shows.
    func usedFor(isDefault: Bool) -> String {
        switch self {
        case .engine(let choice):
            choice.playable
                ? (isDefault ? "Every game, unless a game needs a specific engine." : "Games you choose for it in the Library.")
                : EnginesCopy.testingOnly
        case .crossOver: "No Man's Sky only. Every other game plays with Calimocho."
        case .highball: "\(HighballContract.qualifiedTitle) only. Every other game plays with Calimocho."
        case .user: EnginesCopy.testingOnly
        }
    }
}

/// Wi-Fi-detail-style sheet: location, version, use and licence for one engine. Escape or Done closes it.
struct EngineDetailSheet: View {
    let detail: EngineDetail
    @ObservedObject var settings: RuntimeProviderSettings
    var highball: HighballState?
    @ObservedObject var users: UserEngineModel
    var defaultID: String?
    var allowsFileReads = true
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form { sections }
                .formStyle(.grouped)
            Divider()
            HStack {
                if case .user(let engine) = detail {
                    Button("Remove from List", role: .destructive) {
                        users.remove(engine)
                        close()
                    }
                    .disabled(!users.storeReadable || users.terminating())
                    .accessibilityLabel("Remove \(engine.name) from the list")
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("xodus.engines.detail.done")
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
        .onExitCommand(perform: close)
        .accessibilityIdentifier("xodus.engines.detail")
        .navigationTitle(detail.title)
    }

    @ViewBuilder private var sections: some View {
        Section {
            LabeledContent("Engine") { Text(detail.title) }
        } header: {
            Text(detail.title).font(.headline)
        }
        switch detail {
        case .crossOver:
            CrossOverLocationRow(settings: settings, allowsCheck: allowsFileReads)
            versionSection(CrossOverEngineRow.presentation(state: settings.crossOverDependency).detail,
                           status: CrossOverEngineRow.presentation(state: settings.crossOverDependency).state)
        case .highball:
            Section("Location") {
                LabeledContent("Application") {
                    Text(highball == nil ? "Not checked yet" : highball == .missing ? "Not installed"
                         : HighballContract.applicationPath)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let highball, highball != .missing { finderButton(HighballContract.applicationPath) }
            }
            versionSection(HighballEngineRow.presentation(highball).detail, status: HighballEngineRow.presentation(highball).state)
        case .engine(let choice):
            versionSection(choice.version ?? "Built-in engine",
                           status: EngineConfiguratorSections<EmptyView>.state(for: choice, checking: false))
        case .user(let engine):
            Section("Location") {
                LabeledContent("Folder") {
                    Text(engine.location).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                finderButton(engine.location)
            }
            versionSection(engine.version ?? "Unknown", status: .testingOnly)
        }
        Section("Used For") {
            Text(detail.usedFor(isDefault: { if case .engine(let choice) = detail { choice.id == defaultID } else { false } }()))
                .fixedSize(horizontal: false, vertical: true)
        }
        Section("About & Licence") {
            ForEach(Self.licence(detail), id: \.self) { line in
                Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if detail == .highball {
                Link("Highball on GitHub", destination: HighballContract.repository).accessibleLink()
            } else if detail == .crossOver, settings.crossOverDependency.offersTrialDownload {
                Link("Get CrossOver", destination: CrossOverDependencyState.trialDownloadURL).accessibleLink()
                    .accessibilityIdentifier("xodus.engines.crossover.get")
            }
        }
    }

    private func versionSection(_ version: String, status: EngineRowState?) -> some View {
        Section("Version") {
            LabeledContent("Version") { Text(version).textSelection(.enabled) }
            LabeledContent("Status") {
                if let status { Label(status.title, systemImage: status.symbol).foregroundStyle(.secondary) }
                else { Text("Not Checked Yet").foregroundStyle(.secondary) }
            }
        }
    }

    private func finderButton(_ path: String) -> some View {
        HStack {
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(!allowsFileReads)
        }
    }

    static func licence(_ detail: EngineDetail) -> [String] {
        switch detail {
        case .crossOver: [EnginesCopy.crossOver, EnginesCopy.crossOverLicense]
        case .highball: [HighballCopy.explanation, HighballCopy.license]
        case .engine: ["Built on Wine and other open-source components. Their licences are in \(FeaturedCredits.menuPath)."]
        case .user: ["An engine you added. \(AppBrand.displayName) only reads it and never changes it."]
        }
    }
}
