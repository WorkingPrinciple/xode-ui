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
        VStack(alignment: .leading, spacing: showsHeader ? 16 : 8) {
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
        .padding(showsHeader ? 20 : 0)
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
        HStack(spacing: 12) {
            AppleGPTKAssets.iconImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 2) {
                Text("Game Porting Toolkit 4.0 Installed")
                    .font(.body.weight(.medium))
                Text("D3DMetal staged and verified for DirectX 12 translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Installed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var setupWorkflowView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Case 1: Download currently in progress (Active ETA & Speed Monitoring)
            if case .downloading(let info) = controller.step {
                downloadingCard(info: info)
            }
            // Case 2: Already found locally on the Mac
            else if let detected = controller.detectedDMG {
                detectedLocallyCard(url: detected)
            }
            // Case 3: Initial setup prompt (One more remaining step)
            else {
                oneRemainingStepCard
            }

            // Active operations
            switch controller.step {
            case .inspecting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Mounting and inspecting disk image…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            case .extracting(_, let msg):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var oneRemainingStepCard: some View {
        HStack(alignment: .center, spacing: 12) {
            AppleGPTKAssets.iconImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text("Game Porting Toolkit 4.0 beta 3")
                    .font(.body.weight(.medium))
                Text("Free download from Apple Developer, or drop here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    controller.openAppleDeveloperPortal()
                } label: {
                    Label("Free Download", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Choose file…") {
                    controller.chooseFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargetedForDrop ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isTargetedForDrop ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
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

    @ViewBuilder
    private func downloadingCard(info: DownloadProgressInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading in \(info.browser)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(info.filename)
                        .font(.headline)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }

            if let fraction = info.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }

            HStack {
                Text(info.formattedProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(info.formattedSpeed) • \(info.formattedETA)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("XOde will automatically mount and prompt for agreement once finished.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func detectedLocallyCard(url: URL) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppleGPTKAssets.iconImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.body.weight(.medium))
                Text("Found in Downloads. Ready to extract Apple D3DMetal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Inspect & Install") {
                controller.handleSelectedURL(url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
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
