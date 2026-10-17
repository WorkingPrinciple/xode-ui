// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct AppxManifestFacts: Equatable, Sendable {
    public let targetDeviceFamilies: [String]
    public let fullTrust: Bool
    public let uwpApplication: Bool

    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw AppxManifestError.invalid }
        let reader = AppxManifestReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.root == "Package", reader.applications > 0 else {
            throw AppxManifestError.invalid
        }
        return Self(targetDeviceFamilies: reader.families, fullTrust: reader.fullTrust,
                    uwpApplication: reader.uwpApplication && !reader.classicApplication)
    }
}

public enum AppxManifestError: Error { case invalid }

private final class AppxManifestReader: NSObject, XMLParserDelegate {
    var root: String?
    var families: [String] = []
    var fullTrust = false
    var uwpApplication = false
    var classicApplication = false
    var applications = 0
    var invalid = false
    private var path: [String] = []
    private var namespaces: [String?] = []
    private var prefixBindings: [String: [String]] = [:]
    private let foundation = "http://schemas.microsoft.com/appx/manifest/foundation/windows10"
    private let uap10 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
    private let restricted = "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        prefixBindings[prefix, default: []].append(uri)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixBindings[prefix]?.removeLast()
    }

    private func isFoundation(_ uri: String?) -> Bool {
        uri == nil || uri == "" || uri == foundation
            || uri == "http://schemas.microsoft.com/appx/2010/manifest"
    }

    private var foundationPath: Bool { namespaces.allSatisfy(isFoundation) }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        namespaces.append(namespaceURI)
        if path.count == 1 {
            guard isFoundation(namespaceURI) else { invalid = true; parser.abortParsing(); return }
            root = name
        }
        guard path.count <= 64, families.count < 64, applications < 256 else {
            invalid = true; parser.abortParsing(); return
        }
        if foundationPath, path == ["Package", "Dependencies", "TargetDeviceFamily"],
           let family = attributes["Name"], !family.isEmpty, family.utf8.count <= 256 {
            families.append(family)
        }
        if foundationPath, path == ["Package", "Applications", "Application"] {
            applications += 1
            let entryPoint = attributes["EntryPoint"]
            let behavior = attribute("RuntimeBehavior", in: attributes, parser: parser)
            let trust = attribute("TrustLevel", in: attributes, parser: parser)
            guard !invalid else { return }
            if let behavior, !["windowsApp", "win32App", "packagedClassicApp"].contains(behavior) {
                invalid = true; parser.abortParsing(); return
            }
            if let trust, !["appContainer", "mediumIL"].contains(trust) {
                invalid = true; parser.abortParsing(); return
            }
            if behavior == "windowsApp" && trust == "mediumIL"
                || behavior == "win32App" && trust == "appContainer" {
                invalid = true; parser.abortParsing(); return
            }
            let legacyClassic = ["windows.fulltrustapplication", "windows.partialtrustapplication"]
                .contains(entryPoint?.lowercased() ?? "")
            if legacyClassic || behavior == "win32App" || behavior == "packagedClassicApp" {
                classicApplication = true
            }
            if entryPoint?.lowercased() == "windows.fulltrustapplication" || trust == "mediumIL" {
                fullTrust = true
            } else if !legacyClassic && behavior != "win32App" && behavior != "packagedClassicApp"
                && (behavior == "windowsApp" || trust == "appContainer"
                    || (behavior == nil && trust == nil && entryPoint?.isEmpty == false)) {
                uwpApplication = true
            }
        }
        if path == ["Package", "Capabilities", "Capability"],
           namespaces.dropLast().allSatisfy(isFoundation),
           namespaceURI == restricted, attributes["Name"] == "runFullTrust" {
            fullTrust = true
        }
        if path == ["Package", "Applications", "Application", "Extensions", "Extension"],
           namespaces.prefix(3).allSatisfy(isFoundation),
           isFoundation(namespaces[3]),
           namespaceURI == "http://schemas.microsoft.com/appx/manifest/desktop/windows10",
           attributes["Category"] == "windows.fullTrustProcess" { fullTrust = true }
    }

    private func attribute(_ name: String, in values: [String: String], parser: XMLParser) -> String? {
        let matches = values.filter {
            let parts = $0.key.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1] == name
                && prefixBindings[String(parts[0])]?.last == uap10
        }
        guard matches.count <= 1 else { invalid = true; parser.abortParsing(); return nil }
        return matches.first?.value
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        path.removeLast()
        namespaces.removeLast()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        invalid = true; parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        invalid = true; parser.abortParsing()
    }
}
