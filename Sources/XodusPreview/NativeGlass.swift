// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

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
    var libraryContrast = false
    let openAccount: () -> Void

    var body: some ToolbarContent {
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
            Button(accountLabel, systemImage: accountSymbol, action: openAccount)
                .labelStyle(.iconOnly)
                .modifier(NativeToolbarIconStyle(enabled: libraryContrast))
                .help(accountLabel)
                .accessibilityIdentifier("xodus.account")
        }
    }

    @ViewBuilder private var navigationControls: some View {
        navigation.fixedSize().accessibilityLabel("Navigate X Ode").accessibilityIdentifier("xodus.navigation")
        NativeToolbarSearch(text: searchText, focused: searchFocused,
                            placeholder: searchPlaceholder, enabled: searchEnabled)
    }

    private var picker: some View {
        Picker("Navigate X Ode", selection: selection) {
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
