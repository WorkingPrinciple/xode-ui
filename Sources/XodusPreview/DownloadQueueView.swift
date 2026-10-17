// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

/// Renders the live install/download queue: ordered jobs with per-job progress and
/// pause / resume / cancel controls, driven entirely by `DownloadQueueController`.
struct DownloadQueueView: View {
    @ObservedObject var queue: DownloadQueueController

    var body: some View {
        if !queue.jobs.isEmpty {
            Section("Queue") {
                ForEach(queue.jobs) { job in
                    DownloadQueueRow(queue: queue, job: job)
                }
                if queue.jobs.contains(where: { $0.phase.isTerminal }) {
                    Button("Clear finished") { queue.clearFinished() }
                        .accessibilityIdentifier("xodus.queue.clearFinished")
                }
            }
        }
    }
}

struct DownloadQueueRow: View {
    @ObservedObject var queue: DownloadQueueController
    let job: InstallJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("xodus.queue.status")
            }
            if job.phase.occupiesSlot {
                if let fraction = job.progress?.fraction {
                    ProgressView(value: fraction)
                        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                if job.phase.canPause {
                    Button("Pause") { queue.pause(job.id) }
                        .accessibilityIdentifier("xodus.queue.pause")
                }
                if job.phase.canResume {
                    Button("Resume") { queue.resume(job.id) }
                        .accessibilityIdentifier("xodus.queue.resume")
                }
                if job.phase.canCancel {
                    Button("Cancel", role: .destructive) { queue.cancel(job.id) }
                        .accessibilityIdentifier("xodus.queue.cancel")
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.title), \(statusLabel)")
    }

    private var statusLabel: String {
        switch job.phase {
        case .queued: "Waiting"
        case .preparing: "Preparing"
        case .downloading:
            if let fraction = job.progress?.fraction {
                "Downloading \(Int((fraction * 100).rounded()))%"
            } else { "Downloading" }
        case .paused: "Paused"
        case .verifying: "Verifying"
        case .configuring: "Setting up"
        case .completed: "Installed"
        case .cancelled: "Cancelled"
        case .failed: "Stopped\(job.failureCode.map { " (code \($0))" } ?? "")"
        }
    }
}
