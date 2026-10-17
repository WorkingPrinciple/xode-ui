// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct ScopedSearchField: View {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    var enabled = true

    var body: some View {
        NativeSearchField(text: $text, focused: $focused, placeholder: placeholder, enabled: enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }
}

struct NativeToolbarSearch: View {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    var enabled = true

    static func width(text: String, focused: Bool) -> CGFloat {
        focused || !text.isEmpty ? 220 : 32
    }

    var body: some View {
        ScopedSearchField(text: $text, focused: $focused, placeholder: placeholder, enabled: enabled)
            .frame(width: Self.width(text: text, focused: focused))
            .help(placeholder)
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    var enabled = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusedSearchField {
        makeField(coordinator: context.coordinator)
    }

    func makeField(coordinator: Coordinator) -> FocusedSearchField {
        let view = FocusedSearchField()
        view.delegate = coordinator
        view.target = coordinator
        view.action = #selector(Coordinator.searchChanged(_:))
        view.focusRingType = .exterior
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .controlTextColor
        view.setAccessibilityIdentifier("xodus.catalog.search")
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.sendsSearchStringImmediately = true
        view.sendsWholeSearchString = false
        updateField(view, coordinator: coordinator)
        return view
    }

    func updateNSView(_ view: FocusedSearchField, context: Context) {
        updateField(view, coordinator: context.coordinator)
    }

    func updateField(_ view: FocusedSearchField, coordinator: Coordinator) {
        coordinator.parent = self
        view.wantsFocus = focused && enabled
        view.isEnabled = enabled
        if view.stringValue != text { view.stringValue = text }
        view.placeholderString = placeholder
        view.setAccessibilityLabel(placeholder)
        if view.wantsFocus, view.window != nil, view.currentEditor() == nil {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.wantsFocus, view.isEnabled else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }
        @objc func searchChanged(_ field: NSSearchField) {
            guard field.isEnabled, parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
}

final class FocusedSearchField: NSSearchField {
    var wantsFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, isEnabled { window?.makeFirstResponder(self) }
    }
}
