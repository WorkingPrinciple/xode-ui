// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct NativeGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(scheme == .dark ? Color(white: 0.12) : Color(nsColor: .windowBackgroundColor),
                               in: Capsule())
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

struct GlassAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            Button(title, action: action).buttonStyle(.glassProminent)
        } else {
            Button(title, action: action).buttonStyle(.borderedProminent)
        }
    }
}

private struct XodusReviewReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var xodusReviewReduceTransparency: Bool {
        get { self[XodusReviewReduceTransparencyKey.self] }
        set { self[XodusReviewReduceTransparencyKey.self] = newValue }
    }
}

struct NativeToolbarMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.xodusReviewReduceTransparency) private var reviewReduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency || reviewReduceTransparency {
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .background(.background, in: Capsule())
        } else if #available(macOS 26, *) {
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
        } else {
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

struct NativeToolbarIconStyle: ViewModifier {
    var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.xodusReviewReduceTransparency) private var reviewReduceTransparency
    func body(content: Content) -> some View {
        if !enabled { content }
        else if !reduceTransparency, !reviewReduceTransparency, #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else { content.buttonStyle(.bordered).buttonBorderShape(.circle) }
    }
}

struct XodusToolbar: ToolbarContent {
    let selection: Binding<Destination>
    let searchText: Binding<String>
    let searchFocused: Binding<Bool>
    let searchPlaceholder: String
    let searchEnabled: Bool
    let accountLabel: String
    let accountSymbol: String
    var accountArtwork: CatalogArtworkReference? = nil
    var accountBinding: String? = nil
    var profileLoading = false
    var profileFailed = false
    var importGame: (() -> Void)? = nil
    var importEnabled = true
    var libraryContrast = false
    var openSearch: () -> Void = {}
    var showSearchResults: (() -> Void)?
    let openAccount: () -> Void

    @ToolbarContentBuilder var body: some ToolbarContent {
        if libraryContrast {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) { navigationControls }
                    .modifier(NativeToolbarMaterial())
            }
        } else {
            ToolbarItemGroup(placement: .principal) { navigationControls }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            NativeToolbarAccountActions(accountLabel: accountLabel, accountSymbol: accountSymbol,
                accountArtwork: accountArtwork, accountBinding: accountBinding,
                profileLoading: profileLoading, profileFailed: profileFailed,
                libraryContrast: libraryContrast, importGame: importGame, importEnabled: importEnabled,
                openAccount: openAccount)
        }

    }

    @ViewBuilder private var navigationControls: some View {
        navigation.fixedSize().accessibilityIdentifier("xodus.navigation")
        NativeToolbarSearch(text: searchText, focused: searchFocused,
                            placeholder: searchPlaceholder, enabled: searchEnabled, openSearch: openSearch,
                            showResults: showSearchResults)
    }

    private var picker: some View {
        Picker("Navigate Ode to X", selection: selection) {
            ForEach(Destination.allCases) { destination in
                Text(destination.rawValue).tag(destination)
                    .accessibilityIdentifier("xodus.navigation.\(destination.rawValue.lowercased())")
            }
        }
        .labelsHidden()
    }

    @ViewBuilder private var navigation: some View {
        if #available(macOS 27, *) {
            picker.pickerStyle(.tabs)
        } else {
            picker.pickerStyle(.segmented)
        }
    }
}

struct NativeToolbarAccountActions: View {
    let accountLabel: String
    let accountSymbol: String
    var accountArtwork: CatalogArtworkReference? = nil
    var accountBinding: String? = nil
    var profileLoading = false
    var profileFailed = false
    var libraryContrast = false
    var importGame: (() -> Void)? = nil
    var importEnabled = true
    let openAccount: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ToolbarAccountButton(label: accountLabel, symbol: accountSymbol, reference: accountArtwork,
                profileLoading: profileLoading, profileFailed: profileFailed,
                libraryContrast: libraryContrast, action: openAccount)
                .id(accountBinding)
            if let importGame {
                Button("Import installed Xbox game", systemImage: "plus", action: importGame)
                    .labelStyle(.iconOnly).help("Import installed game")
                    .modifier(NativeToolbarIconStyle())
                    .disabled(!importEnabled)
                    .accessibilityIdentifier("xodus.installed.import")
            }
        }
        .padding(.trailing, 12)
    }
}

struct ToolbarAccountButton: View {
    let label: String
    let symbol: String
    let reference: CatalogArtworkReference?
    var profileLoading = false
    var profileFailed = false
    var libraryContrast = false
    let action: () -> Void
    @StateObject private var presentation = ArtworkPresentation()
    @Environment(\.catalogPresentationActive) private var presentationActive

    static func pictureStatus(hasPicture: Bool, loading: Bool, failed: Bool) -> String {
        if hasPicture { return "Profile picture" }
        if failed { return "Profile picture couldn't be loaded" }
        return loading ? "Profile picture is loading" : "No profile picture available"
    }

    var body: some View {
        let request = CatalogArtworkRequest(reference: reference, bucket: .card)
        let image = presentation.image(for: request)
        let status = Self.pictureStatus(hasPicture: image != nil,
            loading: profileLoading || presentation.loading, failed: profileFailed || presentation.failed)
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 26, height: 26).clipShape(Circle())
                } else {
                    Image(systemName: symbol).frame(width: 26, height: 26)
                }
            }.accessibilityHidden(true)
        }
        .modifier(NativeToolbarIconStyle(enabled: libraryContrast))
        .help("\(label) · \(status)")
        .accessibilityLabel("\(label). \(status)")
        .accessibilityIdentifier("xodus.account")
        .task(id: presentationActive ? request : nil) {
            guard presentationActive else { return }
            await presentation.load(request)
        }
    }
}
