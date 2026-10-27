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
            // REQ-19: clear glass alone left the section labels at 1.2:1 over scrolled artwork (build 624), and
            // thick material still measured 3.1:1 in dark appearance over bright art. The system toolbar
            // material (.bar) under the glass keeps unselected labels at 5.9:1 in light and 9.7:1 in dark
            // (measured over white, black and two artworks), above the 4.5:1 floor, while staying native.
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .background(.bar, in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .background(.bar, in: Capsule())
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
    var recentSearchesPresented: Binding<Bool> = .constant(false)
    var recentSearchesContent = AnyView(EmptyView())
    let openAccount: () -> Void

    @ToolbarContentBuilder var body: some ToolbarContent {
        // REQ-19: build 650 showed the Library grid scrolling under bare section labels when no hero is shown,
        // so the section controls always sit on the toolbar material, not only over hero artwork.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) { navigationControls }
                .modifier(NativeToolbarMaterial())
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        // Separate items so each toolbar item keeps its own name; one shared item kept the
        // import button's name after switching to tabs without Import.
        ToolbarItem(placement: .primaryAction) {
            ToolbarAccountButton(label: accountLabel, symbol: accountSymbol, reference: accountArtwork,
                profileLoading: profileLoading, profileFailed: profileFailed,
                libraryContrast: libraryContrast, action: openAccount)
                .id(accountBinding)
                .padding(.trailing, importGame == nil ? 12 : 0)
        }
        if let importGame {
            ToolbarItem(placement: .primaryAction) {
                NativeToolbarImportButton(enabled: importEnabled, action: importGame)
                    .padding(.trailing, 12)
            }
        }

    }

    @ViewBuilder private var navigationControls: some View {
        navigation.fixedSize().accessibilityIdentifier("xodus.navigation")
        NativeToolbarSearch(text: searchText, focused: searchFocused,
                            placeholder: searchPlaceholder, enabled: searchEnabled, openSearch: openSearch,
                            showResults: showSearchResults,
                            recentSearchesPresented: recentSearchesPresented,
                            recentSearchesContent: recentSearchesContent)
    }

    private var navigation: some View { Self.navigationPicker(selection: selection) }

    /// The section picker, shared with the REQ-19 rendered-contrast check.
    @ViewBuilder static func navigationPicker(selection: Binding<Destination>) -> some View {
        let picker = Picker("Navigate \(AppBrand.displayName)", selection: selection) {
            ForEach(Destination.allCases) { destination in
                Text(destination.rawValue).tag(destination)
                    .accessibilityIdentifier("xodus.navigation.\(destination.rawValue.lowercased())")
            }
        }
        .labelsHidden()
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
            if let importGame { NativeToolbarImportButton(enabled: importEnabled, action: importGame) }
        }
        .padding(.trailing, 12)
    }
}

struct NativeToolbarImportButton: View {
    static let title = "Import Installed Game"
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(Self.title, systemImage: "plus", action: action)
            .labelStyle(.iconOnly).help("Import a game that's already installed on this Mac")
            .modifier(NativeToolbarIconStyle())
            .disabled(!enabled)
            .accessibilityLabel(Self.title)
            .accessibilityIdentifier("xodus.installed.import")
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

    /// The toolbar item's own name, so it can never inherit a neighbour's title.
    static func title(_ label: String) -> String { "Account: \(label)" }

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
            Label {
                Text(Self.title(label))
            } icon: {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 26, height: 26).clipShape(Circle())
                    } else {
                        Image(systemName: symbol).frame(width: 26, height: 26)
                    }
                }.accessibilityHidden(true)
            }
            .labelStyle(.iconOnly)
        }
        .modifier(NativeToolbarIconStyle(enabled: libraryContrast))
        .help("\(label) · \(status)")
        .accessibilityLabel(Self.title(label))
        .accessibilityValue(status)
        .accessibilityIdentifier("xodus.account")
        .task(id: presentationActive ? request : nil) {
            guard presentationActive else { return }
            await presentation.load(request)
        }
    }
}
