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

struct NativeMinecraftCard<Artwork: View>: View {
    @ObservedObject private var minecraft = NativeMinecraft.shared
    @ObservedObject private var evidence = MacGameEvidenceStore.shared
    @ViewBuilder let artwork: () -> Artwork
    @State private var showsDetails = false

    var body: some View {
        LibraryCover(title: "Minecraft: Java Edition", openLabel: "Details for",
                     alwaysShowsActions: true, open: { showsDetails = true }, artwork: artwork) {
            Label("Native launcher", systemImage: "desktopcomputer")
            MacGameEvidenceView(record: evidence.games["9PJ8266BHFWN"])
            if minecraft.javaPID != nil { Text("Minecraft Java is running") }
            if let error = minecraft.errorMessage {
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            LibraryGlassCluster {
            if minecraft.app != nil {
                Button("Open") { minecraft.open() }
                    .modifier(LibraryActionStyle(primary: false))
                    .accessibilityLabel("Open Minecraft's official native launcher")
                    .accessibilityIdentifier("xodus.native.minecraft.open")
            } else {
                Link("Download native launcher", destination: URL(string: "https://www.minecraft.net/download")!)
            }
                Menu {
                    Button("Details") { showsDetails = true }
                } label: { Image(systemName: "ellipsis").accessibilityHidden(true) }
                .menuIndicator(.hidden)
                .modifier(LibraryActionStyle(primary: false))
                .fixedSize()
                .accessibilityLabel("Actions for Minecraft: Java Edition")
            }
        }
        .sheet(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Minecraft: Java Edition").font(.title2)
                Text("Uses the official macOS Minecraft Launcher. Microsoft sign-in is managed by the launcher, separately from your Ode to X account.")
                MacGameEvidenceView(record: evidence.games["9PJ8266BHFWN"], detailed: true)
                Button("Done") { showsDetails = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 540)
        }
    }
}
