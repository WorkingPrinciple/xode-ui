// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import SwiftUI

struct NativeMinecraftInstallation: Equatable, Sendable {
    enum State: Sendable { case checking, missing, ready, repair }
    let state: State
    var path: String? = nil
    var version: String? = nil
    var problem: String? = nil

    /// QA REQ-64: only an installed launcher counts toward "Installed games"; the card can still
    /// appear in All to offer it.
    var countsAsInstalled: Bool { state == .ready || state == .repair }
    static let productID = "9PJ8266BHFWN"

    func appears(in filter: LibraryFilter, query: String) -> Bool {
        guard filter == .all || (filter == .installed && (state == .ready || state == .repair)) else {
            return false
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "Minecraft: Java Edition".localizedCaseInsensitiveContains(query)
    }

    var action: String {
        switch state {
        case .checking: "Checking launcher"
        case .missing: "Install launcher"
        case .ready: "Open"
        case .repair: "Repair launcher"
        }
    }

    static func inspect(_ candidate: URL?) -> Self {
        guard let candidate, FileManager.default.fileExists(atPath: candidate.path) else {
            return Self(state: .missing)
        }
        var observedVersion: String?
        do {
            let plist = candidate.appendingPathComponent("Contents/Info.plist")
            let bytes = try InstalledGameFiles.readRegular(plist, maximumBytes: 1_048_576)
            guard let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == NativeMinecraft.bundleIdentifier else {
                return Self(state: .repair, path: candidate.path,
                            problem: "This location doesn't contain the official Minecraft Launcher. Reinstall it from Minecraft's website.")
            }
            let version = (info["CFBundleShortVersionString"] as? String)
                .flatMap { $0.isEmpty || $0.utf8.count > 128
                    || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? nil : $0 }
            observedVersion = version
            guard let name = info["CFBundleExecutable"] as? String,
                  !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.utf8.contains(0), let version else {
                return Self(state: .repair, path: candidate.path, version: version,
                            problem: "Minecraft Launcher is incomplete or its version couldn't be read. Reinstall the official launcher; keep your Minecraft worlds.")
            }
            let executable = candidate.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
            try GameScriptFiles.checkPath(executable)
            guard try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                return Self(state: .repair, path: candidate.path, version: version,
                            problem: "Minecraft Launcher's executable is missing or can't run. Reinstall the official launcher; keep your Minecraft worlds.")
            }
            return Self(state: .ready, path: candidate.path, version: version)
        } catch {
            return Self(state: .repair, path: candidate.path, version: observedVersion,
                        problem: "Minecraft Launcher couldn't be inspected. Check access to its location or reinstall the official launcher.")
        }
    }
}

enum NativeMinecraftDetailsCopy {
    static let summary = "Uses the official macOS Minecraft Launcher. Microsoft sign-in is managed by the launcher, separately from your \(AppBrand.displayName) account."
    static let worldPreservation = "Install or reinstall the official launcher from this page. Your worlds are not removed by \(AppBrand.displayName)."
}

@MainActor
final class NativeMinecraft: ObservableObject {
    static let shared = NativeMinecraft()
    nonisolated static let bundleIdentifier = "com.mojang.minecraftlauncher"
    static let downloadURL = URL(string: "https://www.minecraft.net/download")!
    @Published private(set) var app: URL?
    @Published private(set) var installation = NativeMinecraftInstallation(state: .checking)
    @Published private(set) var javaPID: Int32?
    @Published private(set) var errorMessage: String?

    func refresh() async {
        let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Minecraft.app"),
            URL(fileURLWithPath: "/Applications/Minecraft.app")
        ]
        let candidate = ((located.map { [$0] } ?? []) + candidates)
            .first { FileManager.default.fileExists(atPath: $0.path) }
        installation = await Task.detached { NativeMinecraftInstallation.inspect(candidate) }.value
        app = installation.state == .ready ? candidate : nil
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
        let current = NativeMinecraftInstallation.inspect(app)
        installation = current
        guard current.state == .ready, let app else {
            self.app = nil
            errorMessage = current.problem ?? "The official macOS Minecraft Launcher couldn't be found. Install it from Minecraft's website."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            Task { @MainActor in
                if let error { self.errorMessage = "Minecraft Launcher couldn't open. \(error.localizedDescription)" }
            }
        }
    }
}

/// REQ-23/60: the Library card names the launcher without any local filesystem path; the folder stays in details.
enum NativeMinecraftCardCopy {
    static let help = "Official macOS Minecraft Launcher"
    static func label(version: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline }
        guard let version, !version.isEmpty, !version.contains("/"), version.utf8.count <= 32 else {
            return "Minecraft Launcher"
        }
        return "Minecraft Launcher · \(version)"
    }
}

struct NativeMinecraftCard<Artwork: View>: View {
    @ObservedObject private var minecraft = NativeMinecraft.shared
    @ViewBuilder let artwork: () -> Artwork
    @State private var showsDetails = false

    var body: some View {
        GameCard(title: "Minecraft: Java Edition", openLabel: "Details for",
                     open: { showsDetails = true }, artwork: artwork) {
            Label(NativeMinecraftCardCopy.label(version: minecraft.installation.version),
                  systemImage: "desktopcomputer")
                .help(NativeMinecraftCardCopy.help)
            if minecraft.javaPID != nil { Text("Minecraft Java is running") }
            if let error = minecraft.errorMessage {
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = minecraft.installation.problem {
                Text(problem).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showsDetails) {
            NativeMinecraftDetailsContent(
                minecraft: minecraft,
                saveLocation: GameSaveLocationView(productID: "9PJ8266BHFWN"),
                close: { showsDetails = false })
        }
    }
}

struct NativeMinecraftDetailsContent<SaveLocation: View>: View {
    @ObservedObject var minecraft: NativeMinecraft
    let saveLocation: SaveLocation
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Minecraft: Java Edition").font(.title2)
                Text(NativeMinecraftDetailsCopy.summary)
                if let path = minecraft.installation.path {
                    LabeledContent("Launcher", value: path).textSelection(.enabled)
                }
                if let version = minecraft.installation.version {
                    LabeledContent("Version", value: version)
                }
                if let problem = minecraft.installation.problem { Text(problem) }
                if let error = minecraft.errorMessage { Text(error) }
                if minecraft.installation.state == .ready {
                    Button("Open") { minecraft.open() }
                        .accessibilityLabel("Open Minecraft's official native launcher")
                        .accessibilityIdentifier("ode.native.minecraft.open")
                } else if minecraft.installation.state == .checking {
                    ProgressView("Checking launcher").controlSize(.small)
                }
                if minecraft.installation.state == .missing || minecraft.installation.state == .repair {
                    Link(minecraft.installation.action, destination: NativeMinecraft.downloadURL).accessibleLink()
                        .accessibilityIdentifier("ode.native.minecraft.recover")
                    Text(NativeMinecraftDetailsCopy.worldPreservation)
                }
                Button("Check launcher") { Task { await minecraft.refresh() } }
                saveLocation
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 640)
    }
}
