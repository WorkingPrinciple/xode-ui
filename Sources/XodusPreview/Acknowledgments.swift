// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import SwiftUI
import XodusManagement

/// One open-source (or separately licensed) component and its notice files.
struct OpenSourceComponent: Identifiable, Hashable, Sendable {
    enum Origin: String, CaseIterable, Sendable {
        case app = "X Ode app"
        case gameService = "Game service"
        case engine = "Calimocho engine"
    }

    struct Notice: Hashable, Sendable {
        let title: String
        let url: URL
        /// Recorded SHA-256; when present, the text is shown only if it matches.
        let sha256: String?
    }

    let origin: Origin
    let name: String
    let version: String?
    let license: String
    let notices: [Notice]
    var id: String { "\(origin.rawValue)|\(name)|\(version ?? "")" }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [name, version ?? "", license, origin.rawValue].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// The complete list, generated only from what ships: the game service's notice inventory,
/// the installed Calimocho engine's notices and the app's own bundled notices.
struct AcknowledgmentsInventory: Sendable {
    static let producerDirectoryName = "ProducerNotices"
    static let pinnedProducerInventorySHA256 = "84682aa8edb8aeef97f5304d17b6282f76b0f027b362e49ae4347b61fb99b04e"

    var components: [OpenSourceComponent] = []
    /// Packages the producer inventory itself lists as lacking exact notice text.
    var unresolved: [String] = []
    /// Plain-language gaps, such as a missing inventory or engine.
    var issues: [String] = []
    /// What actually ships, for the key-projects header: "producer:<crate>", "engine",
    /// "engine:<licenses dir>", "engine-lib:<Wine vendored lib>".
    var markers: Set<String> = []

    static let engineDownloadNote = "Full notices are included with the Calimocho download."

    func filtered(_ query: String) -> [OpenSourceComponent] { components.filter { $0.matches(query) } }

    // MARK: Loading

    struct Locations: Sendable {
        var producer: URL?
        var engine: URL?
        var appLicense: URL?
        var python: URL?
        var antiCheatReference: URL?
        var engineNotice: URL?
        var appNotice: URL?
        var appTrademarks: URL?

        static var current: Locations {
            let resources = Bundle.main.resourceURL
            var producer = resources?.appendingPathComponent(AcknowledgmentsInventory.producerDirectoryName, isDirectory: true)
#if !XODUS_SHIPPING
            if let override = ProcessInfo.processInfo.environment["XODUS_PRODUCER_NOTICES_DIRECTORY"] {
                producer = URL(fileURLWithPath: override, isDirectory: true)
            }
#endif
            return Locations(
                producer: producer,
                engine: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Xode/Engines", isDirectory: true)
                    .appendingPathComponent(CalimochoRelease.engineID, isDirectory: true),
                appLicense: resources?.appendingPathComponent("LICENSE.txt"),
                python: resources?.appendingPathComponent("XodusPython/lib/python3.14/LICENSE.txt"),
                antiCheatReference: CompatibilityResources.antiCheatReferenceLicenseURL(),
                engineNotice: resources?.appendingPathComponent("EngineNotices/NOTICE.txt"),
                appNotice: resources?.appendingPathComponent("NOTICE.txt"),
                appTrademarks: resources?.appendingPathComponent("TRADEMARKS.md"))
        }
    }

    static func load(_ locations: Locations = .current) -> Self {
        var inventory = Self()
        inventory.loadApp(locations)
        if let producer = locations.producer { inventory.loadProducer(producer) }
        else { inventory.issues.append("The game service's notice list isn't included in this build.") }
        inventory.loadEngine(locations.engine, bundledNotice: locations.engineNotice)
        return inventory
    }

    private mutating func loadApp(_ locations: Locations) {
        func existing(_ url: URL?, _ title: String) -> [OpenSourceComponent.Notice] {
            guard let url, FileManager.default.isReadableFile(atPath: url.path) else { return [] }
            return [.init(title: title, url: url, sha256: nil)]
        }
        components.append(.init(origin: .app, name: AppBrand.displayName, version: AppBrand.current.version,
                                 license: "GPL-3.0-only",
                                 notices: existing(locations.appLicense, "LICENSE") + existing(locations.appNotice, "NOTICE")
                                    + existing(locations.appTrademarks, "TRADEMARKS")))
        let python = existing(locations.python, "LICENSE")
        if !python.isEmpty {
            components.append(.init(origin: .app, name: "CPython", version: nil, license: "PSF-2.0", notices: python))
        }
        let awacy = existing(locations.antiCheatReference, "AWACY-LICENSE")
        if !awacy.isEmpty {
            components.append(.init(origin: .app, name: "AreWeAntiCheatYet (data)", version: nil,
                                     license: "MIT", notices: awacy))
        }
    }

    private struct ProducerInventory: Decodable {
        struct Package: Decodable {
            struct Notice: Decodable { let originalPath: String; let path: String; let sha256: String }
            let name: String
            let version: String
            let declaredLicense: String?
            let notices: [Notice]
        }
        let version: Int
        let packages: [Package]
        let unresolved: [String]?
    }

    private mutating func loadProducer(_ directory: URL) {
        let file = directory.appendingPathComponent("inventory.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= 8_000_000,
              let decoded = try? JSONDecoder().decode(ProducerInventory.self, from: data), decoded.version == 1 else {
            issues.append("The game service's notice list couldn't be read.")
            return
        }
        for package in decoded.packages {
            let notices = package.notices.compactMap { notice -> OpenSourceComponent.Notice? in
                // Content-addressed texts only: texts/<sha256>.txt, matching the recorded hash.
                guard notice.path == "texts/\(notice.sha256).txt",
                      notice.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
                let title = notice.originalPath.split(separator: "/").last.map(String.init) ?? "Notice"
                return .init(title: title, url: directory.appendingPathComponent(notice.path), sha256: notice.sha256)
            }
            components.append(.init(origin: .gameService, name: package.name, version: package.version,
                                     license: package.declaredLicense ?? "No package-level licence declared",
                                     notices: notices))
            markers.insert("producer:\(package.name)")
        }
        unresolved = decoded.unresolved ?? []
    }

    private mutating func loadEngine(_ root: URL?, bundledNotice: URL?) {
        let fileManager = FileManager.default
        guard let root, fileManager.fileExists(atPath: root.appendingPathComponent("calimocho-engine.json").path) else {
            // Not installed: show the bundled text NOTICE when packaging includes it.
            if let bundledNotice, fileManager.isReadableFile(atPath: bundledNotice.path) {
                components.append(.init(origin: .engine, name: "Calimocho",
                                         version: EngineDisplayName.releaseVersion(CalimochoRelease.engineID)?.version,
                                         license: "LGPL-2.1-or-later",
                                         notices: [.init(title: "NOTICE", url: bundledNotice, sha256: nil)]))
                markers.insert("engine")
            }
            issues.append(Self.engineDownloadNote)
            return
        }
        markers.insert("engine")
        let version = (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let topLevel = ["NOTICE", "LICENSE", "COPYING.LIB", "TRADEMARKS.md"].compactMap { name -> OpenSourceComponent.Notice? in
            let url = root.appendingPathComponent(name)
            return fileManager.isReadableFile(atPath: url.path) ? .init(title: name, url: url, sha256: nil) : nil
        }
        components.append(.init(origin: .engine, name: "Calimocho",
                                 version: EngineDisplayName.releaseVersion(version ?? CalimochoRelease.engineID)?.version ?? version,
                                 license: "LGPL-2.1-or-later", notices: topLevel))
        let licenses = root.appendingPathComponent("licenses", isDirectory: true)
        let directories = ((try? fileManager.contentsOfDirectory(at: licenses, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in directories.prefix(64) {
            var notices: [OpenSourceComponent.Notice] = []
            if let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in walker where notices.count < 64 {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let relative = url.path.dropFirst(directory.path.count + 1)
                    notices.append(.init(title: String(relative), url: url, sha256: nil))
                }
            }
            let name = directory.lastPathComponent
            markers.insert("engine:\(name)")
            if name == "wine" {
                let libs = directory.appendingPathComponent("libs", isDirectory: true)
                for lib in (try? fileManager.contentsOfDirectory(atPath: libs.path)) ?? [] {
                    markers.insert("engine-lib:\(lib)")
                }
            }
            let proprietary = name == "apple-gptk"
            components.append(.init(origin: .engine, name: proprietary ? "Apple D3DMetal (Game Porting Toolkit)" : name,
                                     version: nil,
                                     license: proprietary ? "Apple proprietary, non-commercial — not open source"
                                                          : "See notice",
                                     notices: notices.sorted { $0.title < $1.title }))
        }
    }

    // MARK: Notice text

    static let checksumMismatch = "This notice doesn't match its recorded checksum, so it isn't shown."

    /// Reads one notice, verifying its hash when one is recorded. RTF is shown as plain text.
    static func text(of notice: OpenSourceComponent.Notice) -> String {
        guard let data = try? Data(contentsOf: notice.url, options: .mappedIfSafe), data.count <= 4_000_000 else {
            return "This notice couldn't be read."
        }
        if let expected = notice.sha256,
           SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expected {
            return checksumMismatch
        }
        if notice.url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil) {
            return attributed.string
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Credits for the top of the window. Descriptions are curated, but each project appears only when
/// its marker is present in what actually ships (see `AcknowledgmentsInventory.markers`).
enum KeyOpenSourceProjects {
    struct Project: Hashable { let name: String; let role: String; let license: String }

    static let header = "Built on open source"
    static var summary: String {
        "\(AppBrand.displayName) exists because of these projects and the people who build them. Every component that ships with \(AppBrand.displayName) is listed below with its licence and notices."
    }
    static let catalog: [(marker: String, project: Project)] = [
        ("producer:xodus", .init(name: "Xodus", role: "Game management service (fork of xodus-gaming/xodus)", license: "GPL-3.0")),
        ("engine", .init(name: "Calimocho", role: "\(AppBrand.displayName)'s Wine-based game engine", license: "LGPL-2.1-or-later")),
        ("engine:wine", .init(name: "Wine, with CodeWeavers' Wine patches", role: "Runs Windows games on macOS", license: "LGPL-2.1-or-later")),
        ("engine-lib:vkd3d", .init(name: "vkd3d", role: "Direct3D 12 on Vulkan", license: "LGPL-2.1-or-later")),
        ("engine:moltenvk", .init(name: "MoltenVK", role: "Vulkan on Metal", license: "Apache-2.0")),
        ("engine:freetype", .init(name: "FreeType", role: "Font rendering", license: "FreeType License or GPL-2.0")),
        ("engine:gnutls", .init(name: "GnuTLS", role: "Secure connections", license: "LGPL-2.1-or-later")),
        ("engine:nettle", .init(name: "Nettle", role: "Cryptography for GnuTLS", license: "LGPL-3.0-or-later or GPL-2.0-or-later")),
        ("engine:gmp", .init(name: "GMP", role: "Arithmetic for Nettle", license: "LGPL-3.0-or-later or GPL-2.0-or-later")),
        ("engine:libtasn1", .init(name: "libtasn1", role: "Certificate parsing for GnuTLS", license: "LGPL-2.1-or-later")),
        ("engine:xxhash", .init(name: "xxHash", role: "Fast hashing", license: "BSD-2-Clause")),
        ("engine:highball-tsshim", .init(name: "Highball timestamp shim", role: "DirectX 12 timestamp queries on D3DMetal", license: "GPL-3.0"))
    ]
    static let separatelyLicensed: (marker: String, project: Project) = ("engine:apple-gptk",
        .init(name: "Apple D3DMetal", role: "Direct3D on Metal, from Apple's Game Porting Toolkit",
              license: "Apple proprietary, non-commercial — not open source"))

    static func projects(shipping markers: Set<String>) -> [Project] {
        catalog.filter { markers.contains($0.marker) }.map(\.project)
    }

    static func separate(shipping markers: Set<String>) -> Project? {
        markers.contains(separatelyLicensed.marker) ? separatelyLicensed.project : nil
    }

    static let appSwiftPackages = "The \(AppBrand.displayName) app itself uses only Apple's system frameworks; it has no third-party Swift packages."
}

struct AppAcknowledgmentsView: View {
    static let windowID = "acknowledgments"
    private enum Selection: Hashable { case overview, component(String) }

    @State private var inventory: AcknowledgmentsInventory?
    @State private var query = ""
    @State private var selection: Selection? = .overview
    private let locations: AcknowledgmentsInventory.Locations?

    /// Pass an inventory to render without reading files (checks and previews).
    init(inventory: AcknowledgmentsInventory? = nil, locations: AcknowledgmentsInventory.Locations? = nil) {
        _inventory = State(initialValue: inventory)
        self.locations = locations
    }

    private var visible: [OpenSourceComponent] { inventory?.filtered(query) ?? [] }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(KeyOpenSourceProjects.header, systemImage: "heart.text.square")
                    .tag(Selection.overview)
                    .accessibilityIdentifier("xodus.acknowledgments.overview")
                if inventory == nil {
                    ProgressView("Loading notices…").controlSize(.small)
                }
                ForEach(OpenSourceComponent.Origin.allCases, id: \.self) { origin in
                    let items = visible.filter { $0.origin == origin }
                    if !items.isEmpty {
                        Section("\(origin.rawValue) (\(items.count))") {
                            ForEach(items) { component in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(component.name).lineLimit(1)
                                    Text([component.version, component.license].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .tag(Selection.component(component.id))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                if inventory != nil, visible.isEmpty, !query.isEmpty {
                    Text("No components match “\(query)”.").foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .accessibilityIdentifier("xodus.acknowledgments.list")
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search components and licences")
        .navigationTitle("Acknowledgments")
        .frame(minWidth: 680, minHeight: 460)
        .task {
            guard inventory == nil else { return }
            let locations = locations ?? .current
            inventory = await Task.detached(priority: .utility) { AcknowledgmentsInventory.load(locations) }.value
        }
        .accessibilityIdentifier("xodus.acknowledgments")
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .component(let id):
            if let component = inventory?.components.first(where: { $0.id == id }) {
                ComponentNoticeView(component: component)
            } else {
                overview
            }
        default:
            overview
        }
    }

    private var overview: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(KeyOpenSourceProjects.header).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(KeyOpenSourceProjects.summary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Key projects") {
                if let inventory {
                    ForEach(KeyOpenSourceProjects.projects(shipping: inventory.markers), id: \.self) { projectRow($0) }
                } else {
                    ProgressView("Loading notices…").controlSize(.small)
                }
            }
            if let inventory, let apple = KeyOpenSourceProjects.separate(shipping: inventory.markers) {
                Section("Separately licensed") {
                    projectRow(apple)
                    Text("Calimocho bundles D3DMetal and is downloaded separately; D3DMetal isn't included in the \(AppBrand.displayName) app.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Everything else") {
                if let inventory {
                    LabeledContent("Components listed", value: "\(inventory.components.count)")
                    Text(KeyOpenSourceProjects.appSwiftPackages).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(inventory.issues, id: \.self) { issue in
                        Label(issue, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    if !inventory.unresolved.isEmpty {
                        DisclosureGroup("Notices still being located (\(inventory.unresolved.count))") {
                            ForEach(inventory.unresolved, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                } else {
                    ProgressView("Loading notices…").controlSize(.small)
                }
                Link("\(AppBrand.displayName) source code", destination: AppLegalCopy.source)
            }
            Section("Trademarks") {
                Text("CrossOver is a trademark of CodeWeavers, Inc. Microsoft, Xbox, Xbox Live and PC Game Pass are trademarks of the Microsoft group of companies. Game names and artwork belong to their publishers.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func projectRow(_ project: KeyOpenSourceProjects.Project) -> some View {
        LabeledContent {
            Text(project.license).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: {
            Text(project.name)
            Text(project.role)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ComponentNoticeView: View {
    let component: OpenSourceComponent
    @State private var texts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text([component.version, component.license, component.origin.rawValue].compactMap { $0 }
                        .joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if component.notices.isEmpty {
                    Text("No notice file was found for this component.").foregroundStyle(.secondary)
                }
                ForEach(component.notices, id: \.self) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.title).font(.headline)
                        Text(texts[notice.url.path] ?? "Loading…")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: component.id) {
            let notices = component.notices
            let loaded = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: notices.map { ($0.url.path, AcknowledgmentsInventory.text(of: $0)) })
            }.value
            texts = loaded
        }
    }
}
