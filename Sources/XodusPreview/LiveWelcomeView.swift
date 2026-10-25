// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum WelcomeCopy {
    static var title: String { "Welcome to \(AppBrand.displayName)" }
    static let tagline = "Play your Xbox PC games on Mac."
    static let account = "Sign in with your Microsoft account to see PC games you own or play with PC Game Pass."
    static let signIn = "Sign in with Microsoft"
    static let checking = "Checking your Microsoft account"
    static var keychain: String {
        "If macOS asks about Keychain access, it's \(AppBrand.displayName) checking or saving your sign-in on this Mac."
    }
}

struct LiveWelcomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var runtime: RuntimeProviderSettings
    @ObservedObject var operations: GameOperationsController
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 24)
                    VStack(spacing: 12) {
                        XOdeLogo().fill(XboxBrand.green)
                            .frame(width: 112, height: 112).accessibilityHidden(true)
                        Text(WelcomeCopy.title).font(.largeTitle.weight(.medium))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("xodus.welcome.title")
                        Text(WelcomeCopy.tagline).font(.title3)
                            .multilineTextAlignment(.center)
                    }
                    Text(WelcomeCopy.account)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("xodus.welcome.status")
                    if let notice = session.welcomeNotice {
                        Text(notice)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360)
                            .accessibilityIdentifier("xodus.welcome.notice")
                    }
                    if session.signInPending {
                        Button("Cancel sign-in") {
                            state.showingReadiness = false
                            Task { await state.cancelUnifiedSignIn(session: session) }
                        }
                            .keyboardShortcut(.cancelAction)
                            .disabled(session.accountBusy)
                            .accessibilityIdentifier("xodus.welcome.cancel")
                    } else {
                        Button(WelcomeCopy.signIn) {
                            state.showingReadiness = true
                            Task {
                                if !session.accountStatusCurrent {
                                    await session.prepareWelcome()
                                }
                                if session.canStartWelcomeSignIn
                                    || (session.needsAccountDisconnect && session.canDisconnectAccount) {
                                    await state.recoverUnifiedSignIn(session: session)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.connectionTransitioning || session.accountBusy || session.hasConfirmedSignIn)
                        .accessibilityIdentifier("xodus.welcome.signIn")
                    }
                    if session.connectionTransitioning || session.accountBusy {
                        OdeLoadingStatus(title: WelcomeCopy.checking, message: WelcomeCopy.keychain)
                            .frame(maxWidth: 360)
                    } else {
                        Text(WelcomeCopy.keychain)
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360)
                            .accessibilityIdentifier("xodus.welcome.keychain")
                    }
                    if operations.hasDownloadStatus {
                        GameOperationProgressView(operations: operations, privacyRestricted: true)
                            .accessibilityIdentifier("xodus.welcome.operation")
                    }
                    Text(AppBrand.nameWithChannel + " " + AppBrand.version)
                        .font(.footnote).foregroundStyle(.tertiary)
                        .accessibilityIdentifier("xodus.welcome.version")
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 80))
                .padding(40)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 600,
               minHeight: 400, idealHeight: 480, maxHeight: 600)
        .interactiveDismissDisabled(!session.hasConfirmedSignIn)
        .accessibilityIdentifier("xodus.welcome")
    }
}

/// Free space in the games folder, read off the main actor with a timeout.
struct GamesFolderSpace: Equatable, Sendable {
    static let lowSpaceBytes: Int64 = 20 * 1_000_000_000

    let folder: String
    let availableBytes: Int64?

    var isLow: Bool { availableBytes.map { $0 < Self.lowSpaceBytes } ?? false }

    var summary: String {
        guard let availableBytes else { return "Free space couldn't be read" }
        return "\(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)) available"
    }

    static func currentFolder(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.data(forKey: GameInstallLocation.preferenceKey) ?? Data()
        return (try? GameInstallLocation.decode(saved))?.folder ?? GameScriptPaths.production.games.path
    }

    /// Measures the nearest existing folder, so a games folder that isn't created yet still reports its volume.
    static func measure(folder: String) -> Self {
        var url = URL(fileURLWithPath: folder).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Self(folder: folder, availableBytes: values?.volumeAvailableCapacityForImportantUsage)
    }
}

/// Shown once after signing in from the welcome screen: account, engine and games-folder space.
/// Read-only: it only reads existing status and opens Settings or the download page.
struct ReadinessChecklistView: View {
    enum Status: Equatable {
        case done, waiting, attention

        var symbol: String {
            switch self {
            case .done: "checkmark.circle.fill"
            case .waiting: "clock"
            case .attention: "exclamationmark.triangle.fill"
            }
        }

        var accessibilityName: String {
            switch self {
            case .done: "Ready"
            case .waiting: "Checking"
            case .attention: "Needs attention"
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @ObservedObject var session: LiveSession
    @ObservedObject var installed: InstalledGamesController
    var allowsStatusReads = true
    var openSettingsPane: (SettingsPane) -> Void = { _ in }
    var done: () -> Void = {}
    @State private var space: GamesFolderSpace?
    @State private var probe = GameStorageProbe()

    private var engine: CalimochoAvailability {
        CalimochoAvailability.from(
            choices: installed.availableEngineOverrides.compactMap { $0.inspection.engineName }
                .map { EngineChoice.named($0, ready: true) }
                + installed.failedEngineOverrides.map { EngineChoice.named($0, ready: false) },
            checking: installed.checkingEngineOverrides,
            installed: allowsStatusReads ? CalimochoRelease.isPresent() : nil)
    }

    static func engineStatus(_ availability: CalimochoAvailability) -> (Status, String) {
        switch availability {
        case .ready: (.done, "Calimocho is ready to play games")
        case .checking, .notChecked: (.waiting, "Checking for Calimocho…")
        case .missing: (.attention, "Calimocho isn't installed")
        case .invalid: (.attention, "Calimocho couldn't be verified")
        }
    }

    var body: some View {
        let (engineState, engineTitle) = Self.engineStatus(engine)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("You're signed in").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Here's what \(AppBrand.displayName) needs before you play.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                row(session.hasConfirmedSignIn ? .done : .waiting, title: "Microsoft account",
                    detail: session.accountJourneyTitle)
                    .accessibilityIdentifier("xodus.readiness.account")
                row(engineState, title: engineTitle,
                    detail: engine.needsDownload ? engine.message : nil) {
                    if engine.needsDownload {
                        HStack(spacing: 12) {
                            Link(CalimochoRelease.getTitle, destination: CalimochoRelease.downloadURL)
                                .accessibilityIdentifier("xodus.readiness.getCalimocho")
                            Button("Open Engines Settings") { openSettingsPane(.engines) }
                        }
                    }
                }
                .accessibilityIdentifier("xodus.readiness.engine")
                row(space == nil ? .waiting : space?.isLow == true || space?.availableBytes == nil ? .attention : .done,
                    title: space.map { "Games folder: \($0.summary)" } ?? "Checking the games folder…",
                    detail: space.map { space in
                        space.isLow ? "Space is low. Many games need tens of gigabytes. \(space.folder)" : space.folder
                    }) {
                    Button("Change Games Folder…") { openSettingsPane(.general) }
                }
                .accessibilityIdentifier("xodus.readiness.storage")
            }
            HStack {
                Spacer()
                Button("Continue", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("xodus.readiness.continue")
            }
        }
        .padding(32)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 600)
        .accessibilityIdentifier("xodus.readiness")
        .task(id: allowsStatusReads && session.nativeLifecycleConfiguration != nil) {
            guard allowsStatusReads else { return }
            await installed.refreshEngineOverrides(force: false)
        }
        .task(id: allowsStatusReads) {
            guard allowsStatusReads else { return }
            let folder = GamesFolderSpace.currentFolder()
            space = (try? await probe.read { GamesFolderSpace.measure(folder: folder) })
                ?? GamesFolderSpace(folder: folder, availableBytes: nil)
        }
    }

    private func row(_ status: Status, title: String, detail: String?) -> some View {
        row(status, title: title, detail: detail) { EmptyView() }
    }

    private func row<Actions: View>(_ status: Status, title: String, detail: String?,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: status.symbol)
                .foregroundStyle(status == .done ? AnyShapeStyle(.green) : status == .attention
                                 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityLabel(status.accessibilityName)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                actions()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
