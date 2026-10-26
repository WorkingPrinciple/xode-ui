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
    static let pinnedProducerInventorySHA256 = "6852cb5688f400b7bb6e3312bed2758101bdda2d8b76b205099dc72e637ffceb"

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
                engine: installedReleaseEngine(),
                appLicense: resources?.appendingPathComponent("LICENSE.txt"),
                python: resources?.appendingPathComponent("XodusPython/lib/python3.14/LICENSE.txt"),
                antiCheatReference: CompatibilityResources.antiCheatReferenceLicenseURL(),
                engineNotice: resources?.appendingPathComponent("EngineNotices/NOTICE.txt"),
                appNotice: resources?.appendingPathComponent("NOTICE.txt"),
                appTrademarks: resources?.appendingPathComponent("TRADEMARKS.md"))
        }
    }

    /// The pinned release engine that's installed, preferring the active pin; nil when none is installed.
    static func installedReleaseEngine(root: URL = CalimochoReleaseEngines.defaultEnginesRoot) -> URL? {
        let installed = CalimochoReleaseEngines.installedNames(root: root)
        let name = installed.contains(CalimochoRelease.engineID) ? CalimochoRelease.engineID
            : CalimochoReleasePin.all.filter { installed.contains($0.engineName) }
                .max { ($0.releaseVersion?.revision ?? 0) < ($1.releaseVersion?.revision ?? 0) }?.engineName
        return name.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    static let noticeLimit = 4_000_000

    /// A regular, non-symlink file of at most `limit` bytes (no pipes, devices or links).
    static func isRegularNotice(_ url: URL, limit: Int = noticeLimit) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 && info.st_size <= limit
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
            guard let url, AcknowledgmentsInventory.isRegularNotice(url) else { return [] }
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
            if let bundledNotice, Self.isRegularNotice(bundledNotice) {
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
        let version = (try? InstalledGameFiles.readRegular(root.appendingPathComponent("VERSION"), maximumBytes: 256))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? root.lastPathComponent
        let topLevel = ["NOTICE", "LICENSE", "COPYING.LIB", "TRADEMARKS.md"].compactMap { name -> OpenSourceComponent.Notice? in
            let url = root.appendingPathComponent(name)
            return Self.isRegularNotice(url) ? .init(title: name, url: url, sha256: nil) : nil
        }
        components.append(.init(origin: .engine, name: "Calimocho",
                                 version: EngineDisplayName.releaseVersion(version)?.version ?? version,
                                 license: "LGPL-2.1-or-later", notices: topLevel))
        let licenses = root.appendingPathComponent("licenses", isDirectory: true)
        let directories = ((try? fileManager.contentsOfDirectory(at: licenses, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in directories.prefix(64) {
            var notices: [OpenSourceComponent.Notice] = []
            if let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in walker where notices.count < 64 {
                    guard Self.isRegularNotice(url) else { continue }
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
        guard let data = try? InstalledGameFiles.readRegular(notice.url, maximumBytes: noticeLimit) else {
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
/// REQ-122: the one source for the Wine and Xodus credits shown in Acknowledgments, About, the sign-in
/// window, the menus and README.
enum FeaturedCredits {
    struct Credit: Hashable {
        let name: String
        let organisation: String
        let url: URL
        let linkText: String
        let role: String
        let license: String
        let thanks: String
    }

    static let sectionTitle = "Built on Wine and Xodus"
    static let wine = Credit(
        name: "Wine", organisation: "WineHQ", url: URL(string: "https://www.winehq.org")!, linkText: "winehq.org",
        role: "Runs Windows games on your Mac", license: "LGPL-2.1-or-later",
        thanks: "Thank you to the Wine authors and to CodeWeavers. Their decades of work are why Windows games can play on a Mac at all.")
    static var xodus: Credit {
        Credit(name: "Xodus", organisation: "xodus-gaming", url: URL(string: "https://github.com/xodus-gaming/xodus")!,
               linkText: "github.com/xodus-gaming/xodus",
               role: "The Xbox library and install engine \(AppBrand.displayName)'s backend builds on", license: "GPL-3.0",
               thanks: "Thank you to the Xodus contributors for the open Xbox library and install work \(AppBrand.displayName) grows from.")
    }
    static var all: [Credit] { [wine, xodus] }

    /// One line for About X Ode.
    static let aboutLine = "Runs Windows games with Wine and is built on Xodus. Thank you to both projects."
    /// The sign-in window's two short lines: Wine first, then where the credits are.
    static var signInLine: String { "\(AppBrand.displayName) runs Windows games with Wine and is built on Xodus." }
    static var menuPath: String { "\(AppBrand.displayName) menu › Acknowledgments" }
    /// The link title and the words after it read as one line: "Acknowledgments and licences are also
    /// in the X Ode menu."
    static let creditsLinkTitle = "Acknowledgments and licences"
    static var whereToFind: String { "are also in the \(AppBrand.displayName) menu." }
    static let acknowledgmentsMenu = "Acknowledgments…"
    static let licencesMenu = "Open-Source Licences…"
    static let helpMenu = "Acknowledgments and Licences"
    /// README.md's credit line, kept identical by a check.
    static var readmeLine: String {
        "\(AppBrand.displayName) runs Windows games with [Wine](\(wine.url.absoluteString)) (\(wine.license); thank you to the Wine authors and CodeWeavers) and is built on [Xodus](\(xodus.url.absoluteString)) (\(xodus.license); thank you to its contributors)."
    }
}

/// Which part of Acknowledgments a menu item asked for; the window applies and clears it.
@MainActor
final class AcknowledgmentsNavigation: ObservableObject {
    enum Focus: Equatable { case overview, licences }
    static let shared = AcknowledgmentsNavigation()
    static let licencesAnchor = "xodus.acknowledgments.licences"
    @Published var request: Focus?

    struct MenuItem: Equatable {
        let title: String
        let focus: Focus
    }
    static let appMenu = [MenuItem(title: FeaturedCredits.acknowledgmentsMenu, focus: .overview),
                          MenuItem(title: FeaturedCredits.licencesMenu, focus: .licences)]
    static let helpMenu = [MenuItem(title: FeaturedCredits.helpMenu, focus: .overview)]

    /// Opens the Acknowledgments window at the requested place.
    func open(_ focus: Focus, openWindow: (String) -> Void) {
        request = focus
        openWindow(AppAcknowledgmentsView.windowID)
    }
}

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
    enum Selection: Hashable { case overview, licences, component(String) }
    static let licencesTitle = "All components and licences"

    /// Where a menu request lands: Open-Source Licences opens its own page, so it never depends on
    /// scrolling a Form that isn't laid out yet.
    static func selection(for focus: AcknowledgmentsNavigation.Focus) -> Selection {
        focus == .licences ? .licences : .overview
    }

    @State private var inventory: AcknowledgmentsInventory?
    @State private var query = ""
    @State private var selection: Selection? = .overview
    @ObservedObject private var navigation: AcknowledgmentsNavigation
    private let locations: AcknowledgmentsInventory.Locations?

    /// Pass an inventory to render without reading files (checks and previews).
    init(inventory: AcknowledgmentsInventory? = nil, locations: AcknowledgmentsInventory.Locations? = nil,
         navigation: AcknowledgmentsNavigation = .shared) {
        _inventory = State(initialValue: inventory)
        self.locations = locations
        _navigation = ObservedObject(wrappedValue: navigation)
        _selection = State(initialValue: navigation.request.map(Self.selection(for:)) ?? .overview)
    }

    private var visible: [OpenSourceComponent] { inventory?.filtered(query) ?? [] }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(KeyOpenSourceProjects.header, systemImage: "heart.text.square")
                    .tag(Selection.overview)
                    .accessibilityIdentifier("xodus.acknowledgments.overview")
                Label(Self.licencesTitle, systemImage: "doc.text")
                    .tag(Selection.licences)
                    .accessibilityIdentifier("xodus.acknowledgments.licencesPage")
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
        .onChange(of: navigation.request, initial: true) { _, request in
            guard let request else { return }
            selection = Self.selection(for: request)
            navigation.request = nil
        }
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
        case .licences:
            licencesPage
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
            Section(FeaturedCredits.sectionTitle) {
                ForEach(FeaturedCredits.all, id: \.self) { featuredRow($0) }
            }
            .accessibilityIdentifier("xodus.acknowledgments.featured")
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
            Section(Self.licencesTitle) {
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
                Text("Choose any component in the sidebar to read its full licence and notices.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("\(AppBrand.displayName) source code", destination: AppLegalCopy.source)
            }
            .accessibilityIdentifier(AcknowledgmentsNavigation.licencesAnchor)
            Section("Trademarks") {
                Text("CrossOver is a trademark of CodeWeavers, Inc. Microsoft, Xbox, Xbox Live and PC Game Pass are trademarks of the Microsoft group of companies. Game names and artwork belong to their publishers.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Every shipped component with its licence; choosing one opens its full notice texts.
    private var licencesPage: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.licencesTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Every component that ships with \(AppBrand.displayName), with its licence. Choose one to read its full licence and notices.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let inventory {
                ForEach(OpenSourceComponent.Origin.allCases, id: \.self) { origin in
                    let items = inventory.components.filter { $0.origin == origin }
                    if !items.isEmpty {
                        Section("\(origin.rawValue) (\(items.count))") {
                            ForEach(items) { component in
                                Button {
                                    selection = .component(component.id)
                                } label: {
                                    LabeledContent(component.name, value: component.license ?? "Licence in notices")
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the full licence and notices")
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading notices…").controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier(AcknowledgmentsNavigation.licencesAnchor + ".page")
    }

    private func featuredRow(_ credit: FeaturedCredits.Credit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(credit.name).font(.headline)
                Text(credit.organisation).foregroundStyle(.secondary)
                Spacer()
                Text(credit.license).foregroundStyle(.secondary)
            }
            Text(credit.role)
            Text(credit.thanks).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Opens the browser; the credit itself shows signed out and offline.
            Link(credit.linkText, destination: credit.url)
                .accessibilityLabel("\(credit.name) website, \(credit.linkText)")
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("xodus.acknowledgments.featured.\(credit.name.lowercased())")
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
