// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XodusManagement

struct GPTKOnboardingView: View {
    @ObservedObject var controller: GPTKOnboardingController
    var showsHeader = true
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Game Porting Toolkit Setup")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("DirectX 12 graphics on Apple Silicon require Apple's D3DMetal translation libraries from Game Porting Toolkit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if controller.isInstalled, let receipt = controller.receipt {
                installedView(receipt: receipt)
            } else {
                setupWorkflowView
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .sheet(isPresented: Binding(
            get: { controller.activeInspection != nil },
            set: { if !$0 { controller.cancelLicenseReview() } }
        )) {
            if let inspection = controller.activeInspection {
                AppleLicenseReviewSheet(
                    inspection: inspection,
                    onAgree: { controller.confirmLicenseAndInstall() },
                    onCancel: { controller.cancelLicenseReview() }
                )
            }
        }
    }

    @ViewBuilder
    private func installedView(receipt: GPTKExtractionReceipt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple D3DMetal Installed")
                        .font(.headline)
                    Text("Version \(receipt.version) staged and verified for DirectX 12 translation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)

            LabeledContent("Location", value: receipt.destinationURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Update or Reinstall Toolkit…") {
                controller.openAppleDeveloperPortal()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var setupWorkflowView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Step 1: Download from Apple
            VStack(alignment: .leading, spacing: 8) {
                Text("Step 1: Download from Apple Developer")
                    .font(.headline)
                Text("Apple terms require downloading Game Porting Toolkit directly with your personal Apple ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    controller.openAppleDeveloperPortal()
                } label: {
                    Label("Download from Apple Developer", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // Step 2: Ingestion (Detection, Drop, or Choose)
            VStack(alignment: .leading, spacing: 10) {
                Text("Step 2: Ingest Toolkit Disk Image")
                    .font(.headline)

                if let detected = controller.detectedDMG {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detected in Downloads:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(detected.lastPathComponent)
                                .font(.subheadline)
                        }
                        Spacer()
                        Button("Inspect & Install") {
                            controller.handleSelectedURL(detected)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }

                // Drag & Drop Area
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isTargetedForDrop ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [6])
                        )
                        .background(isTargetedForDrop ? Color.accentColor.opacity(0.05) : Color.clear)

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 28))
                            .foregroundStyle(isTargetedForDrop ? Color.accentColor : Color.secondary)
                        Text("Drag and drop Game_Porting_Toolkit_*.dmg here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Or choose file…") {
                            controller.chooseFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            controller.handleDrop(urls: [url])
                        }
                    }
                    return true
                }
            }

            // Ongoing operation state
            switch controller.step {
            case .inspecting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Mounting and inspecting disk image…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .extracting(_, let msg):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
    }
}

struct AppleLicenseReviewSheet: View {
    let inspection: GPTKInspection
    let onAgree: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Game Porting Toolkit Agreement")
                    .font(.title3.bold())
                Text("Review the terms before extracting D3DMetal components onto your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RTFTextPreview(data: inspection.licenseRTFData)
                .frame(minWidth: 500, idealWidth: 580, minHeight: 320, idealHeight: 400)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Agree and Install", action: onAgree)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 420, idealHeight: 520)
    }
}

struct RTFTextPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false

        if let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            textView.textStorage?.setAttributedString(attr)
        } else if let text = String(data: data, encoding: .utf8) {
            textView.string = text
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
