// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// The engine a detail sheet describes (COR-279 step 3).
enum EngineDetail: Identifiable, Equatable {
    case calimocho
    case engine(EngineChoice)
    case crossOver
    case highball
    case user(UserEngine)

    var id: String {
        switch self {
        case .calimocho: "calimocho"
        case .engine(let choice): "engine:" + choice.id
        case .crossOver: "crossover"
        case .highball: "highball"
        case .user(let engine): "user:" + engine.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .calimocho: "Calimocho"
        case .engine(let choice): choice.name
        case .crossOver: "CrossOver"
        case .highball: "Highball"
        case .user(let engine): engine.name
        }
    }

    /// Which games the engine runs, in the words the sheet shows.
    func usedFor(isDefault: Bool) -> String {
        switch self {
        case .calimocho: "Every game, unless a game needs a specific engine."
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

/// Calimocho's installer and update actions, for its detail sheet.
struct CalimochoSheetContext {
    let installer: CalimochoReleaseInstallController
    var isBusy: @MainActor @Sendable () -> Bool = { true }
    var refreshAdmission: @MainActor () async -> Bool = { false }
    var showsUpdates = false
    var beginUpdate: @MainActor (LocalCalimochoRelease) -> Void = { _ in }
    var removeOld: @MainActor () -> Void = {}
}

/// Wi-Fi-detail-style sheet: location, version, use and licence for one engine. Escape or Done closes it.
struct EngineDetailSheet: View {
    let detail: EngineDetail
    @ObservedObject var settings: RuntimeProviderSettings
    var highball: HighballState?
    @ObservedObject var users: UserEngineModel
    var defaultID: String?
    var allowsFileReads = true
    var calimocho: CalimochoSheetContext? = nil
    let close: () -> Void
    @State private var confirmingCalimochoRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            Text(detail.title).font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Form { sections }
                .formStyle(.grouped)
            Divider()
            HStack {
                if detail == .calimocho, let calimocho, calimocho.installer.hasEngineFolder {
                    Button("Remove Calimocho…", role: .destructive) { confirmingCalimochoRemoval = true }
                        .disabled(calimocho.isBusy() || calimocho.installer.isWorking)
                        .help("Quit any running game and finish active operations before removing Calimocho.")
                        .accessibilityIdentifier("ode.engines.calimocho.remove")
                        .confirmationDialog("Move Calimocho to the Trash?", isPresented: $confirmingCalimochoRemoval,
                                            titleVisibility: .visible) {
                            Button("Move to Trash", role: .destructive) {
                                calimocho.installer.remove(isBusy: calimocho.isBusy,
                                                           refreshAdmission: { _ = await calimocho.refreshAdmission() })
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Only the pinned Calimocho engine folder will be moved. Game prefixes and saves won't be changed.")
                        }
                }
                if case .user(let engine) = detail {
                    Button("Remove from List", role: .destructive) {
                        users.remove(engine)
                        close()
                    }
                    .disabled(!users.storeReadable || users.terminating())
                    .accessibilityLabel("Remove \(engine.name) from the list")
                }
                Spacer()
                // Escape closes the sheet the way Done does (review 7c5beadb L3).
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0)
                    .accessibilityHidden(true)
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ode.engines.detail.done")
            }
            .padding(16)
        }
        .frame(width: 520, height: Self.height)
        .onExitCommand(perform: close)
        .accessibilityIdentifier("ode.engines.detail")
        .navigationTitle(detail.title)
    }

    @ViewBuilder private var sections: some View {
        switch detail {
        case .calimocho:
            if let calimocho {
                Section("Location") {
                    CalimochoReleaseInstallControls(installer: calimocho.installer, isBusy: calimocho.isBusy,
                                                    refreshAdmission: calimocho.refreshAdmission, allowsRemoval: false)
                }
                Section("Version") {
                    LabeledContent("Version") {
                        Text(EngineDisplayName.releaseVersion(CalimochoRelease.engineID)
                            .map { "\($0.version) · \($0.detail)" } ?? "Unknown").textSelection(.enabled)
                    }
                    if calimocho.showsUpdates {
                        CalimochoUpdateControls(installer: calimocho.installer, isBusy: calimocho.isBusy,
                                                beginUpdate: calimocho.beginUpdate, removeOld: calimocho.removeOld)
                    }
                }
            }
        case .crossOver:
            CrossOverLocationRow(settings: settings, allowsCheck: allowsFileReads, showsStatus: false)
            versionSection(Self.crossOverVersion(settings.crossOverDependency),
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
            versionSection(Self.highballVersion(highball), status: HighballEngineRow.presentation(highball).state)
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
                    .accessibilityIdentifier("ode.engines.crossover.get")
            }
        }
    }

    private func versionSection(_ version: String, status: EngineRowState?) -> some View {
        Section("Version") {
            LabeledContent("Version") { Text(version).textSelection(.enabled) }
            LabeledContent("Status") {
                if let status { Label(status.title, systemImage: status.symbol).foregroundStyle(.secondary) }
                else { Text("—").foregroundStyle(.secondary).accessibilityLabel("Not checked yet") }
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

    /// Tall enough that every row, including the licence links, shows without scrolling.
    static let height: CGFloat = 680

    static func crossOverVersion(_ state: CrossOverDependencyState) -> String {
        switch state {
        case .installed(let app): app.version
        case .absent: "Not installed"
        case .notChecked, .checking, .unverified: "Not checked yet"
        }
    }

    static func highballVersion(_ state: HighballState?) -> String {
        switch state {
        case nil: "Not checked yet"
        case .missing: "Not installed"
        case .detected(let version, _), .qualified(let version, _): version ?? "Unknown"
        }
    }

    static func licence(_ detail: EngineDetail) -> [String] {
        switch detail {
        case .calimocho, .engine: ["Built on Wine and other open-source components. Their licences are in \(FeaturedCredits.menuPath)."]
        case .crossOver: [EnginesCopy.crossOverLicense]
        case .highball: [HighballCopy.explanation, HighballCopy.license]
        case .user: ["An engine you added. \(AppBrand.displayName) only reads it and never changes it."]
        }
    }
}
