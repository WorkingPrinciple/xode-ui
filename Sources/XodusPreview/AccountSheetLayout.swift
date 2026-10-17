// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct WelcomeSheetTerminationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowPolicyView { WindowPolicyView() }
    func updateNSView(_ view: WindowPolicyView, context: Context) {}

    static func dismantleNSView(_ view: WindowPolicyView, coordinator: ()) {
        view.restorePolicy()
    }

    final class WindowPolicyView: NSView {
        private weak var configuredWindow: NSWindow?
        private var previousPolicy: Bool?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if configuredWindow !== newWindow { restorePolicy() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            previousPolicy = window.preventsApplicationTerminationWhenModal
            // Welcome must let normal Quit reach the delegate's authoritative operation/shutdown checks.
            window.preventsApplicationTerminationWhenModal = false
        }

        func restorePolicy() {
            if let configuredWindow, let previousPolicy {
                configuredWindow.preventsApplicationTerminationWhenModal = previousPolicy
            }
            configuredWindow = nil
            previousPolicy = nil
        }
    }
}

struct AccountSheetLayout<Header: View, Content: View, Actions: View>: View {
    let header: Header
    let content: Content
    let actions: Actions
    let showsHeader: Bool

    init(showsHeader: Bool = true, @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.header = header()
        self.content = content()
        self.actions = actions()
        self.showsHeader = showsHeader
    }

    static func headerHeight(for height: CGFloat) -> CGFloat {
        min(210, max(0, (height - 420) * 0.75))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        let height = Self.headerHeight(for: geometry.size.height)
                        if showsHeader && height > 0 { header.frame(height: height).clipped() }
                        content.padding(.horizontal, 28).padding(.vertical, 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actions.padding(20)
            }
        }
        .frame(minWidth: 480, idealWidth: showsHeader ? 650 : 560, maxWidth: 760,
               minHeight: showsHeader ? 340 : 480, idealHeight: 620, maxHeight: 700)
    }
}

struct AccountActionsLayout: Layout {
    var spacing: CGFloat = 12
    var layoutDirection: LayoutDirection = .leftToRight

    private func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    private func fitsHorizontally(_ sizes: [CGSize], width: CGFloat) -> Bool {
        sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)) <= width
    }

    func frames(for sizes: [CGSize], in bounds: CGRect) -> [CGRect] {
        let horizontal = fitsHorizontally(sizes, width: bounds.width)
        var offset: CGFloat = 0
        return sizes.indices.map { index in
            let size = sizes[index]
            let x: CGFloat
            let y: CGFloat
            if horizontal {
                x = index == sizes.count - 1 ? bounds.maxX - size.width : bounds.minX + offset
                y = bounds.midY - size.height / 2
                offset += size.width + spacing
            } else {
                x = bounds.maxX - size.width
                y = bounds.minY + offset
                offset += size.height + spacing
            }
            let originX = layoutDirection == .rightToLeft
                ? bounds.minX + bounds.maxX - x - size.width : x
            return CGRect(origin: CGPoint(x: originX, y: y), size: size)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = sizes(subviews, width: nil)
        let idealWidth = ideal.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, ideal.count - 1))
        let width = proposal.width ?? idealWidth
        if fitsHorizontally(ideal, width: width) {
            return CGSize(width: width, height: ideal.map(\.height).max() ?? 0)
        }
        let stacked = sizes(subviews, width: width)
        return CGSize(width: width, height: stacked.reduce(0) { $0 + $1.height }
                      + spacing * CGFloat(max(0, stacked.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let ideal = sizes(subviews, width: nil)
        let measured = fitsHorizontally(ideal, width: bounds.width) ? ideal : sizes(subviews, width: bounds.width)
        for (index, frame) in frames(for: measured, in: bounds).enumerated() {
            subviews[index].place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }
}
