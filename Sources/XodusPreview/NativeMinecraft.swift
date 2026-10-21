// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import SwiftUI

@MainActor
final class NativeMinecraft: ObservableObject {
    static let shared = NativeMinecraft()
    static let bundleIdentifier = "com.mojang.minecraftlauncher"
    @Published private(set) var app: URL?
    @Published private(set) var javaPID: Int32?
    @Published private(set) var errorMessage: String?

    func refresh() async {
        let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        let candidate = located ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Minecraft.app")
        if Bundle(url: candidate)?.bundleIdentifier == Self.bundleIdentifier {
            app = candidate
        } else { app = nil }
        do {
            javaPID = try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-axo", "pid=,uid=,comm="]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, bytes.count <= 4_194_304 else {
                    throw InstalledGameError.launch
                }
                return Self.minecraftJavaPID(in: String(decoding: bytes, as: UTF8.self), uid: getuid())
            }.value
            errorMessage = nil
        } catch { errorMessage = "Minecraft Java process status couldn't be checked." }
    }

    nonisolated static func minecraftJavaPID(in listing: String, uid: uid_t) -> Int32? {
        for row in listing.split(separator: "\n") {
            let fields = row.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, UInt32(fields[1]) == uid, let pid = Int32(fields[0]), pid > 0 else { continue }
            let executable = String(fields[2])
            if executable.contains("/Application Support/minecraft/runtime/"),
               URL(fileURLWithPath: executable).lastPathComponent == "java" { return pid }
        }
        return nil
    }

    func open() {
        guard let app, Bundle(url: app)?.bundleIdentifier == Self.bundleIdentifier else {
            errorMessage = "The official macOS Minecraft Launcher couldn't be found."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            Task { @MainActor in
                if let error { self.errorMessage = "Minecraft Launcher couldn't open. \(error.localizedDescription)" }
            }
        }
    }
}

struct NativeMinecraftCard: View {
    @ObservedObject private var minecraft = NativeMinecraft.shared
    @ObservedObject private var evidence = MacGameEvidenceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Minecraft: Java Edition", systemImage: "gamecontroller").font(.headline)
            Label("Native launcher", systemImage: "desktopcomputer")
            Text("Uses the official macOS launcher, not the Windows Xbox package.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if minecraft.app != nil {
                Button("Open native launcher") { minecraft.open() }
                    .accessibilityIdentifier("xodus.native.minecraft.open")
                Text(minecraft.javaPID == nil ? "Launcher installed" : "Minecraft Java is running")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Link("Download native launcher", destination: URL(string: "https://www.minecraft.net/download")!)
            }
            if let error = minecraft.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            MacGameEvidenceView(record: evidence.games["9PJ8266BHFWN"])
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.vertical, 12)
    }
}
