// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum LibraryLoadingPresentation {
    @MainActor
    static func showsPlaceholders(library: PCGamesController, loadingInstalled: Bool = false,
                                  checkingAccess: Bool = false, hasUsableContent: Bool,
                                  query: String = "") -> Bool {
        showsPlaceholders(pending: library.busy || library.restoringPresence || loadingInstalled || checkingAccess,
            hasUsableContent: hasUsableContent,
            failed: library.error != nil || library.presenceUnavailable,
            requiresAccountAction: library.needsSignIn || library.needsKeychainApproval
                || (!library.hasSavedSignIn && !library.restoringPresence && !library.busy),
            query: query)
    }

    static func showsPlaceholders(pending: Bool, hasUsableContent: Bool, failed: Bool,
                                  requiresAccountAction: Bool, query: String) -> Bool {
        pending && !hasUsableContent && !failed && !requiresAccountAction
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum GameLaunchPresentation {
    static func title(game: String, stopping: Bool, checking: Bool, started: Bool) -> String {
        if stopping { return "Stopping \(game)" }
        if checking { return "Checking \(game)" }
        return started ? "Opening \(game)" : "Preparing \(game)"
    }
}

struct OdeLoadingStatus: View {
    let title: String
    var message: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if reduceMotion {
                Image(systemName: "hourglass").foregroundStyle(.secondary).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LibraryLoadingPlaceholders: View {
    var body: some View {
        LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
            ForEach(0..<6) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            Image(systemName: "gamecontroller").font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .frame(height: 14).padding(.trailing, 32)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .frame(width: 80, height: 10)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct OdeStartupBackdrop: View {
    var body: some View {
        VStack(spacing: 16) {
            XOdeLogo().fill(XboxBrand.green).frame(width: 80, height: 80)
            Text("Ode to X").font(.largeTitle.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityHidden(true)
    }
}
